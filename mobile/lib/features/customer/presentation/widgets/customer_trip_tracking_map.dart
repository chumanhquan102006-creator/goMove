import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Factory, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_motion.dart';
import '../../domain/models/quote.dart';
import '../../../trip/domain/models/road_route.dart';
import '../../../trip/presentation/widgets/road_route_line.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../bloc/booking_status_cubit.dart';
import 'customer_map_source.dart';

/// One stable native map for authorized Booking points, stored road route and
/// (only during active tracking) the Driver's latest GPS fix.
class CustomerTripTrackingMap extends StatefulWidget {
  final CustomerLiveLocation? location;
  final RoadRoute? route;
  final Coordinates? pickup;
  final Coordinates? dropoff;
  final TripRealtimeConnectionState connectionState;
  final bool fullBleed;
  final String? bookingPublicId;
  final String trackingStatus;

  /// Settled sheet extent, not every drag frame. Zero for embedded maps.
  final double sheetExtent;
  final bool enableCameraFollow;

  /// Driven only by the authenticated Booking status, never a local timer.
  final bool searchingForDriver;

  /// Trial only until native MapLibre performance is measured on two devices.
  /// This changes marker presentation, never REST/STOMP or persisted GPS.
  final bool enableMarkerInterpolation;
  @visibleForTesting
  final DateTime Function()? motionNow;
  @visibleForTesting
  final ValueChanged<LatLng>? onVisualPosition;
  @visibleForTesting
  final Duration Function()? motionElapsed;
  final ValueChanged<bool>? onGpsStaleChanged;

  const CustomerTripTrackingMap({
    super.key,
    required this.location,
    required this.connectionState,
    required this.trackingStatus,
    this.route,
    this.pickup,
    this.dropoff,
    this.fullBleed = false,
    this.bookingPublicId,
    this.sheetExtent = .30,
    this.enableCameraFollow = const bool.fromEnvironment(
        'GOMOVE_EXPERIMENTAL_CAMERA_FOLLOW',
        defaultValue: false),
    this.searchingForDriver = false,
    this.enableMarkerInterpolation = const bool.fromEnvironment(
        'GOMOVE_EXPERIMENTAL_MARKER_INTERPOLATION',
        defaultValue: false),
    this.motionNow,
    this.onVisualPosition,
    this.motionElapsed,
    this.onGpsStaleChanged,
  });

  /// Defend the native map against malformed REST data as well as STOMP data.
  static bool isRenderable(CustomerLiveLocation? location) =>
      location != null &&
      location.latitude.isFinite &&
      location.latitude >= -90 &&
      location.latitude <= 90 &&
      location.longitude.isFinite &&
      location.longitude >= -180 &&
      location.longitude <= 180 &&
      location.updatedAt.millisecondsSinceEpoch > 0;

  /// A duplicate or older fix must not move the marker backwards.
  static bool shouldAcceptNewFix(
          CustomerLiveLocation? current, CustomerLiveLocation candidate,
          {DateTime? now}) =>
      isRenderable(candidate) &&
      !candidate.updatedAt.isAfter((now ?? DateTime.now())
          .toUtc()
          .add(CustomerLiveLocation.maxFutureSkew)) &&
      (current == null ||
          !isRenderable(current) ||
          candidate.updatedAt.isAfter(current.updatedAt));

  @override
  State<CustomerTripTrackingMap> createState() =>
      _CustomerTripTrackingMapState();
}

enum _CameraAction { automatic, locate, route, privacy }

/// Presentation-only motion between two accepted GPS samples. It never
/// publishes a location or moves the camera. A 100 ms presentation tick is not
/// a native-write budget: a flush can update both a circle and a symbol.
class CustomerMarkerMotion {
  static const tick = Duration(milliseconds: 100);
  static const duration = Duration(milliseconds: 300);
  static const maxSampleGap = Duration(seconds: 20);
  static const maxSampleAge = Duration(seconds: 20);
  static const maxDistanceMeters = 250.0;
  static const maxSpeedMetersPerSecond = 35.0;

  final void Function(LatLng) onPosition;
  final void Function(double?)? onBearing;
  final DateTime Function() now;
  final Duration Function()? elapsed;
  final Stopwatch _watch = Stopwatch()..start();
  CustomerLiveLocation? _accepted;
  Timer? _timer;
  LatLng? _rendered;
  double? _renderedBearing;
  bool _disposed = false;

  CustomerMarkerMotion(
      {required this.onPosition,
      this.onBearing,
      DateTime Function()? now,
      this.elapsed})
      : now = now ?? DateTime.now;

  bool get isAnimating => _timer != null;

  static double _distanceMeters(
      CustomerLiveLocation first, CustomerLiveLocation second) {
    const earthRadiusMeters = 6371000.0;
    final firstLatitude = first.latitude * math.pi / 180;
    final secondLatitude = second.latitude * math.pi / 180;
    final deltaLatitude = (second.latitude - first.latitude) * math.pi / 180;
    final deltaLongitude = (second.longitude - first.longitude) * math.pi / 180;
    final a = math.pow(math.sin(deltaLatitude / 2), 2) +
        math.cos(firstLatitude) *
            math.cos(secondLatitude) *
            math.pow(math.sin(deltaLongitude / 2), 2);
    return 2 * earthRadiusMeters * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static bool canInterpolate(
      CustomerLiveLocation first, CustomerLiveLocation second, DateTime now) {
    if (!CustomerTripTrackingMap.isRenderable(first) ||
        !first.hasInterpolationAccuracy ||
        !second.hasInterpolationAccuracy ||
        !first.isFreshAt(now) ||
        !second.isFreshAt(now) ||
        !CustomerTripTrackingMap.shouldAcceptNewFix(first, second, now: now)) {
      return false;
    }
    final gap = second.updatedAt.difference(first.updatedAt);
    final age = now.toUtc().difference(second.updatedAt.toUtc());
    if (gap < tick ||
        gap > maxSampleGap ||
        age > maxSampleAge ||
        age < const Duration(seconds: -5)) {
      return false;
    }
    final distance = _distanceMeters(first, second);
    return distance > 0 &&
        distance <= maxDistanceMeters &&
        distance / (gap.inMilliseconds / 1000) <= maxSpeedMetersPerSecond;
  }

  static LatLng _at(
      LatLng first, CustomerLiveLocation second, double progress) {
    var longitudeDelta = second.longitude - first.longitude;
    if (longitudeDelta > 180) longitudeDelta -= 360;
    if (longitudeDelta < -180) longitudeDelta += 360;
    var longitude = first.longitude + longitudeDelta * progress;
    if (longitude > 180) longitude -= 360;
    if (longitude < -180) longitude += 360;
    return LatLng(
        first.latitude + (second.latitude - first.latitude) * progress,
        longitude);
  }

  static double? bearingAt(double? first, double? second, double progress) {
    if (second == null || !second.isFinite || second < 0 || second >= 360) {
      return null;
    }
    if (first == null || !first.isFinite || first < 0 || first >= 360) {
      return second;
    }
    final delta = (second - first + 540) % 360 - 180;
    return (first + delta * progress + 360) % 360;
  }

  void accept(CustomerLiveLocation sample, {required bool animate}) {
    if (_disposed ||
        !CustomerTripTrackingMap.isRenderable(sample) ||
        (_accepted != null &&
            !CustomerTripTrackingMap.shouldAcceptNewFix(_accepted, sample,
                now: now())) ||
        sample.updatedAt
            .isAfter(now().toUtc().add(CustomerLiveLocation.maxFutureSkew))) {
      return;
    }
    final prior = _accepted;
    final start = _rendered;
    final startBearing = _renderedBearing;
    _timer?.cancel();
    _timer = null;
    _accepted = sample;
    if (!animate ||
        prior == null ||
        start == null ||
        !canInterpolate(prior, sample, now())) {
      _publish(LatLng(sample.latitude, sample.longitude),
          bearingAt(null, sample.bearing, 1));
      return;
    }
    final began = elapsed?.call() ?? _watch.elapsed;
    _timer = Timer.periodic(tick, (timer) {
      final progress =
          (((elapsed?.call() ?? _watch.elapsed) - began).inMicroseconds /
                  duration.inMicroseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      if (progress >= 1) {
        timer.cancel();
        _timer = null;
      }
      _publish(
          progress >= 1
              ? LatLng(sample.latitude, sample.longitude)
              : _at(start, sample, progress),
          bearingAt(startBearing, sample.bearing, progress));
    });
  }

  void _publish(LatLng point, double? bearing) {
    if (_disposed) return;
    if (_renderedBearing != bearing) {
      _renderedBearing = bearing;
      onBearing?.call(bearing);
    }
    if (_rendered != point) {
      _rendered = point;
      onPosition(point);
    }
  }

  void snap() {
    _timer?.cancel();
    _timer = null;
    final accepted = _accepted;
    if (accepted != null) {
      _publish(LatLng(accepted.latitude, accepted.longitude),
          bearingAt(null, accepted.bearing, 1));
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _disposed = true;
    _watch.stop();
  }
}

class _CustomerTripTrackingMapState extends State<CustomerTripTrackingMap>
    with WidgetsBindingObserver {
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  CustomerLiveLocation? _shownLocation;
  late CustomerMarkerMotion _motion;
  LatLng? _visualPoint;
  LatLng? _firstCenter;
  late final Future<bool> _mapReady;
  MapLibreMapController? _controller;
  Circle? _driverCircle;
  Symbol? _driverDirection;
  double? _visualBearing;
  final List<Circle> _radarCircles = [];
  Timer? _radarTimer;
  int _radarTick = 0;
  Timer? _styleTimeout;
  Timer? _freshnessTimer;
  int _freshnessRevision = 0;
  bool _locationStale = false;
  bool _nativeWorkerRunning = false;
  bool _staticRequested = false;
  bool _driverRequested = false;
  bool _radarRequested = false;
  bool _routeRequested = false;
  LatLng? _drawnCirclePosition;
  LatLng? _drawnSymbolPosition;
  double? _drawnBearing;
  int _mapVersion = 0;
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _setupFailed = false;
  bool _mapInteractive = false;
  bool _reducedMotion = false;
  bool _paused = false;
  bool _scopeChanged = false;
  bool _gpsRemovalPending = false;

  // Camera operations share the controller, not the annotation worker. An
  // Android animation Future can stay pending for its entire native duration.
  final Stopwatch _cameraWatch = Stopwatch()..start();
  final Map<int, Offset> _mapPointers = {};
  Timer? _cameraTimer;
  Timer? _cameraWatchdog;
  _CameraAction? _pendingCamera;
  bool _cameraInFlight = false;
  bool _cameraDispatchScheduled = false;
  bool _cameraBlocked = false;
  bool _cameraPrivacyPending = false;
  bool _privateCameraUsed = false;
  bool _followWanted = false;
  bool _cameraFixUsable = false;
  bool _multiTouch = false;
  int _cameraRevision = 0;
  int _cameraFlight = 0;
  Duration? _lastAutomaticCamera;
  Duration? _lastMapTap;
  Offset? _lastMapTapPosition;
  CustomerLiveLocation? _cameraReference;
  CustomerLiveLocation? _lastCameraFix;
  Size _mapSize = Size.zero;
  EdgeInsets? _appliedCameraPadding;

  bool get _trackingActive => const {
        'DRIVER_ACCEPTED',
        'DRIVER_ARRIVED',
        'PASSENGER_ONBOARD',
        'IN_PROGRESS'
      }.contains(widget.trackingStatus);
  bool get _trackingTerminal => const {
        'COMPLETED',
        'CANCELLED',
        'NO_DRIVER_AVAILABLE'
      }.contains(widget.trackingStatus);
  Duration get _cameraElapsed =>
      widget.motionElapsed?.call() ?? _cameraWatch.elapsed;
  EdgeInsets get _followPadding {
    final attribution = TextPainter(
      text: TextSpan(
          text: CustomerMapSource.visibleAttribution,
          style: Theme.of(context).textTheme.labelSmall),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 3,
      ellipsis: '\u2026',
    )..layout(
        maxWidth: math.max(
            1.0, _mapSize.width - (widget.enableCameraFollow ? 92 : 160)));
    final top =
        widget.fullBleed ? math.max(112.0, attribution.height + 28) : 64.0;
    attribution.dispose();
    return EdgeInsets.only(
        left: 12,
        right: 12,
        top: top,
        bottom: widget.fullBleed
            ? _mapSize.height * widget.sheetExtent.clamp(0.0, 1.0) + 12
            : 12);
  }

  bool get _cameraReady =>
      mounted &&
      !_scopeChanged &&
      !_paused &&
      _controller != null &&
      _styleLoaded &&
      !_mapUnavailable &&
      !_setupFailed;
  bool get _canLocate =>
      _cameraReady &&
      !_cameraBlocked &&
      !_cameraPrivacyPending &&
      _trackingActive &&
      _hasDisplayLocation &&
      _mapSize.height - _followPadding.vertical >= 48;
  bool get _canFollow => _canLocate && _cameraFixUsable;

  // The flag-OFF M4.2A locate action accepts every fresh/renderable fix.
  // Follow (including the flag-ON Follow button) keeps its quality policy.
  bool _cameraQualityAllowed(_CameraAction action) =>
      (action == _CameraAction.locate && !widget.enableCameraFollow) ||
      _cameraFixUsable;
  bool _canTargetCamera(_CameraAction action) =>
      _canLocate && _cameraQualityAllowed(action);
  bool get _cameraCover =>
      _cameraPrivacyPending ||
      (!_trackingActive && _hasDisplayLocation) ||
      (_cameraInFlight && (!_hasDisplayLocation || _paused));
  String get _cameraMode => !_canFollow
      ? 'unavailable'
      : _followWanted
          ? 'follow'
          : 'free';

  void _invalidateCamera({bool forgetPrivate = false}) {
    _cameraRevision++;
    _cameraTimer?.cancel();
    _cameraTimer = null;
    _pendingCamera = null;
    if (forgetPrivate) {
      _cameraReference = null;
      _lastCameraFix = null;
      _lastMapTap = null;
      _lastMapTapPosition = null;
    }
  }

  LatLng? get _publicCameraPoint {
    if (widget.route?.available == true) {
      final p = widget.route!.points.first;
      return LatLng(p.latitude, p.longitude);
    }
    final p = widget.pickup?.isValid == true ? widget.pickup : widget.dropoff;
    return p?.isValid == true ? LatLng(p!.latitude, p.longitude) : null;
  }

  void _enterCameraPrivacy() {
    _invalidateCamera(forgetPrivate: true);
    _followWanted = false;
    _cameraPrivacyPending = true;
    _firstCenter = _publicCameraPoint;
    if (_firstCenter == null) {
      // No authorized public seed: remove the native view rather than expose
      // its retained private viewport. MapLibre owns disposal of that view.
      _mapVersion++;
      _styleLoaded = false;
      _controller = null;
    }
    _queueCamera(_CameraAction.privacy);
  }

  void _acceptCameraFix(CustomerLiveLocation fix) {
    final previous = _cameraReference;
    _cameraFixUsable = fix.hasInterpolationAccuracy;
    if (previous != null && previous.isFreshAt(_now)) {
      final gap = fix.updatedAt.difference(previous.updatedAt);
      if (gap > Duration.zero) {
        final distance = CustomerMarkerMotion._distanceMeters(previous, fix);
        if (distance > CustomerMarkerMotion.maxDistanceMeters ||
            distance / (gap.inMicroseconds / Duration.microsecondsPerSecond) >
                CustomerMarkerMotion.maxSpeedMetersPerSecond) {
          _cameraFixUsable = false;
        }
      }
    }
    _cameraReference = fix;
    if (_trackingActive) _privateCameraUsed = true;
    // A rejected camera target never changes GPS admission or user preference.
    _queueCamera(_CameraAction.automatic);
  }

  void _queueCamera(_CameraAction action) {
    if (!mounted || _scopeChanged) return;
    if (_cameraPrivacyPending) action = _CameraAction.privacy;
    if (action == _CameraAction.automatic &&
        (!_trackingActive ||
            !widget.enableCameraFollow ||
            !_followWanted ||
            (_pendingCamera != null &&
                _pendingCamera != _CameraAction.automatic))) {
      return;
    }
    _pendingCamera = action;
    if (action != _CameraAction.automatic) {
      _cameraTimer?.cancel();
      _cameraTimer = null;
    }
    // Let didUpdateWidget finish accepting GPS/status/insets before capturing
    // a target. One scheduled drain coalesces all intents in the same turn.
    if (!_cameraDispatchScheduled) {
      _cameraDispatchScheduled = true;
      scheduleMicrotask(() {
        _cameraDispatchScheduled = false;
        _scheduleCamera();
      });
    }
  }

  void _scheduleCamera() {
    if (!_cameraReady ||
        _cameraBlocked ||
        _cameraInFlight ||
        _mapPointers.isNotEmpty ||
        _pendingCamera == null) {
      return;
    }
    final action = _pendingCamera!;
    if (action == _CameraAction.privacy) {
      if (_publicCameraPoint == null) return;
    } else if (action != _CameraAction.route &&
        (!_canTargetCamera(action) || _gpsRemovalPending)) {
      return;
    }
    if (action == _CameraAction.automatic) {
      if (!widget.enableCameraFollow || !_followWanted) {
        _pendingCamera = null;
        return;
      }
      final last = _lastCameraFix;
      if (last != null &&
          _appliedCameraPadding == _followPadding &&
          CustomerMarkerMotion._distanceMeters(last, _shownLocation!) < 10) {
        _pendingCamera = null;
        return;
      }
      final since = _lastAutomaticCamera == null
          ? const Duration(seconds: 1)
          : _cameraElapsed - _lastAutomaticCamera!;
      if (since < const Duration(seconds: 1)) {
        _cameraTimer ??= Timer(const Duration(seconds: 1) - since, () {
          _cameraTimer = null;
          _scheduleCamera();
        });
        return;
      }
    }
    _pendingCamera = null;
    _cameraTimer?.cancel();
    _cameraTimer = null;
    unawaited(_runCamera(action));
  }

  Future<void> _runCamera(_CameraAction action) async {
    final controller = _controller!;
    final version = _mapVersion;
    final revision = _cameraRevision;
    final booking = widget.bookingPublicId;
    final flight = ++_cameraFlight;
    final fix =
        action == _CameraAction.automatic || action == _CameraAction.locate
            ? _shownLocation
            : null;
    final update = fix != null
        ? CameraUpdate.newLatLng(_point(fix))
        : action == _CameraAction.route
            ? _routeCameraUpdate()
            : CameraUpdate.newLatLng(_publicCameraPoint!);
    if (update == null) return;
    _cameraInFlight = true;
    if (action == _CameraAction.automatic) {
      _lastAutomaticCamera = _cameraElapsed;
    }
    if (fix != null) _privateCameraUsed = true;
    bool current({bool exactFix = true}) =>
        mounted &&
        !_scopeChanged &&
        !_paused &&
        _controller == controller &&
        version == _mapVersion &&
        revision == _cameraRevision &&
        booking == widget.bookingPublicId &&
        !_cameraBlocked &&
        (action == _CameraAction.privacy
            ? _cameraPrivacyPending && !_trackingActive
            : action == _CameraAction.route ||
                (_trackingActive &&
                    _hasDisplayLocation &&
                    (!exactFix || identical(fix, _shownLocation)) &&
                    fix!.isFreshAt(_now) &&
                    _cameraQualityAllowed(action)));
    _cameraWatchdog = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_cameraInFlight || flight != _cameraFlight) return;
      // A timeout is not native cancellation. Keep this lane occupied until
      // the original Future settles; never launch an overlapping retry.
      setState(() {
        _cameraBlocked = true;
        _invalidateCamera();
      });
    });
    try {
      final padding = fix != null ? _followPadding : EdgeInsets.zero;
      if (_appliedCameraPadding != padding) {
        await controller.setPadding(
            left: padding.left,
            top: padding.top,
            right: padding.right,
            bottom: padding.bottom);
        if (!current()) return;
        _appliedCameraPadding = padding;
      }
      if (!current()) return;
      final moved = action == _CameraAction.privacy || _reducedMotion
          ? await controller.moveCamera(update)
          : await controller.animateCamera(update,
              duration: const Duration(milliseconds: 300));
      if (!current(exactFix: false)) return;
      if (moved != true) {
        setState(() => _cameraBlocked = true);
        return;
      }
      if (action == _CameraAction.privacy) {
        setState(() {
          _cameraPrivacyPending = false;
          _privateCameraUsed = false;
        });
      } else if (fix != null) {
        _lastCameraFix = fix;
      }
    } catch (_) {
      if (current(exactFix: false)) setState(() => _cameraBlocked = true);
    } finally {
      if (flight == _cameraFlight) {
        _cameraWatchdog?.cancel();
        _cameraWatchdog = null;
        _cameraInFlight = false;
        if (mounted) {
          setState(() {});
          _scheduleCamera();
        }
      }
    }
  }

  void _freeExplore() {
    if (!mounted || _cameraPrivacyPending) return;
    setState(() {
      _followWanted = false;
      _invalidateCamera();
    });
  }

  void _mapPointerDown(PointerDownEvent event) {
    _mapPointers[event.pointer] = event.localPosition;
    _cameraTimer?.cancel();
    _cameraTimer = null;
    if (_mapPointers.length > 1) {
      _multiTouch = true;
      _freeExplore();
    } else if (_lastMapTap != null &&
        _cameraElapsed - _lastMapTap! <= kDoubleTapTimeout &&
        (event.localPosition - _lastMapTapPosition!).distance <=
            kDoubleTapSlop) {
      _lastMapTap = null;
      _freeExplore();
    }
  }

  void _mapPointerMove(PointerMoveEvent event) {
    final start = _mapPointers[event.pointer];
    if (start != null && (event.localPosition - start).distance > kTouchSlop) {
      _freeExplore();
    }
  }

  void _mapPointerUp(PointerEvent event) {
    final start = _mapPointers.remove(event.pointer);
    if (event is PointerUpEvent &&
        !_multiTouch &&
        start != null &&
        (event.localPosition - start).distance <= kTouchSlop) {
      _lastMapTap = _cameraElapsed;
      _lastMapTapPosition = event.localPosition;
    }
    if (_mapPointers.isEmpty) {
      _multiTouch = false;
      _scheduleCamera();
    }
  }

  DateTime get _now => (widget.motionNow ?? DateTime.now)().toUtc();
  bool get _hasDisplayLocation =>
      !_scopeChanged &&
      !_locationStale &&
      CustomerTripTrackingMap.isRenderable(_shownLocation) &&
      _shownLocation!.isFreshAt(_now);

  CustomerMarkerMotion _createMotion() => CustomerMarkerMotion(
      now: widget.motionNow,
      elapsed: widget.motionElapsed,
      onBearing: _updateVisualBearing,
      onPosition: (point) {
        if (!mounted || !_hasDisplayLocation) return;
        _visualPoint = point;
        widget.onVisualPosition?.call(point);
        _queueMarkerSync();
      });

  void _refreshFreshness() {
    final revision = ++_freshnessRevision;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _locationStale = CustomerTripTrackingMap.isRenderable(_shownLocation) &&
        !_shownLocation!.isFreshAt(_now);
    if (_locationStale) {
      _invalidateCamera();
      _motion.dispose();
      _motion = _createMotion();
      _visualPoint = null;
      _visualBearing = null;
      _gpsRemovalPending = true;
      _queueMarkerSync();
    } else if (_hasDisplayLocation && _visualPoint == null) {
      _motion.accept(_shownLocation!, animate: false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == _freshnessRevision) {
        widget.onGpsStaleChanged?.call(_locationStale);
      }
    });
    if (!_paused && _hasDisplayLocation) {
      final remaining = _shownLocation!.updatedAt
          .toUtc()
          .add(CustomerLiveLocation.displayTtl)
          .difference(_now);
      _freshnessTimer = Timer(remaining, () {
        if (!mounted || _paused || revision != _freshnessRevision) return;
        setState(_refreshFreshness);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final initial = widget.location;
    _shownLocation = initial != null &&
            CustomerTripTrackingMap.shouldAcceptNewFix(null, initial, now: _now)
        ? initial
        : null;
    _followWanted = widget.enableCameraFollow && !_trackingTerminal;
    _cameraReference = _shownLocation;
    _cameraFixUsable = _shownLocation?.hasInterpolationAccuracy == true;
    _privateCameraUsed = _shownLocation != null && _trackingActive;
    _motion = _createMotion();
    _refreshFreshness();
    if (_hasDisplayLocation) {
      _firstCenter = _point(_shownLocation!);
    } else if (widget.route?.available == true) {
      final first = widget.route!.points.first;
      _firstCenter = LatLng(first.latitude, first.longitude);
    } else if (widget.pickup?.isValid == true) {
      _firstCenter = LatLng(widget.pickup!.latitude, widget.pickup!.longitude);
    } else if (widget.dropoff?.isValid == true) {
      _firstCenter =
          LatLng(widget.dropoff!.latitude, widget.dropoff!.longitude);
    }
    if (!_trackingActive) _firstCenter = _publicCameraPoint;
    _mapReady = _configureMapRequests();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduceMotion(context);
    if (reduced && !_reducedMotion) _motion.snap();
    _reducedMotion = reduced;
    _refreshRadar();
    _queueCamera(_CameraAction.automatic);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _paused = false;
      _refreshFreshness();
      _queueMarkerSync();
      _refreshRadar();
      _queueCamera(_cameraPrivacyPending
          ? _CameraAction.privacy
          : _CameraAction.automatic);
    } else {
      _paused = true;
      _invalidateCamera();
      _mapPointers.clear();
      _lastMapTap = null;
      _freshnessTimer?.cancel();
      _freshnessTimer = null;
      _freshnessRevision++;
      _motion.snap();
      _radarTimer?.cancel();
      _radarTimer = null;
    }
  }

  Future<bool> _configureMapRequests() async {
    try {
      // A fixed User-Agent is the only extra map-request header; never send
      // JWTs, Booking identifiers or Customer data to the tile provider.
      await CustomerMapSource.configureRequests();
      return mounted;
    } catch (_) {
      if (mounted) setState(() => _setupFailed = true);
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant CustomerTripTrackingMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableMarkerInterpolation &&
        !widget.enableMarkerInterpolation) {
      _motion.snap();
    }
    if (widget.bookingPublicId != oldWidget.bookingPublicId) {
      // The caller normally changes the widget key on Booking replacement.
      // If it does not, fail closed instead of retaining another trip's map.
      _scopeChanged = true;
      _invalidateCamera(forgetPrivate: true);
      _followWanted = false;
      _freshnessTimer?.cancel();
      _freshnessRevision++;
      _motion.dispose();
      _radarTimer?.cancel();
      _radarTimer = null;
      _mapVersion++;
      return;
    }
    if (!_trackingActive &&
        !_cameraPrivacyPending &&
        (_privateCameraUsed ||
            (_trackingTerminal &&
                oldWidget.trackingStatus != widget.trackingStatus))) {
      if (_privateCameraUsed) {
        _enterCameraPrivacy();
      } else {
        _invalidateCamera(forgetPrivate: true);
        _followWanted = false;
      }
    }
    if (oldWidget.enableCameraFollow != widget.enableCameraFollow) {
      _invalidateCamera();
      _followWanted = widget.enableCameraFollow && !_trackingTerminal;
    }
    if (oldWidget.sheetExtent != widget.sheetExtent) {
      _invalidateCamera();
      _appliedCameraPadding = null;
      _queueCamera(_CameraAction.automatic);
    }
    if (!identical(widget.route, oldWidget.route)) {
      if (_firstCenter == null && widget.route?.available == true) {
        final first = widget.route!.points.first;
        _firstCenter = LatLng(first.latitude, first.longitude);
      }
      _queueRouteSync();
    }
    if (widget.pickup?.latitude != oldWidget.pickup?.latitude ||
        widget.pickup?.longitude != oldWidget.pickup?.longitude ||
        widget.dropoff?.latitude != oldWidget.dropoff?.latitude ||
        widget.dropoff?.longitude != oldWidget.dropoff?.longitude) {
      if (_firstCenter == null && widget.pickup?.isValid == true) {
        _firstCenter =
            LatLng(widget.pickup!.latitude, widget.pickup!.longitude);
      }
      _queueStaticMarkerSync();
    }
    if (widget.searchingForDriver != oldWidget.searchingForDriver ||
        widget.pickup?.latitude != oldWidget.pickup?.latitude ||
        widget.pickup?.longitude != oldWidget.pickup?.longitude) {
      _refreshRadar();
    }
    if (widget.location == null && _shownLocation != null) {
      // Completion/privacy loss removes the native GPS annotation immediately.
      _gpsRemovalPending = true;
      _motion.dispose();
      _motion = _createMotion();
      _shownLocation = null;
      _visualPoint = null;
      _visualBearing = null;
      _refreshFreshness();
      _queueMarkerSync();
    } else if (widget.location != null &&
        CustomerTripTrackingMap.shouldAcceptNewFix(
            _shownLocation, widget.location!,
            now: _now)) {
      _shownLocation = widget.location;
      _refreshFreshness();
      _acceptCameraFix(_shownLocation!);
      if (_hasDisplayLocation) {
        _firstCenter ??= _point(_shownLocation!);
        _motion.accept(_shownLocation!,
            animate: widget.enableMarkerInterpolation &&
                !_paused &&
                !_reducedMotion &&
                _styleLoaded);
      }
    }
    if (_cameraPrivacyPending) {
      _queueCamera(_CameraAction.privacy);
    } else if (oldWidget.enableCameraFollow != widget.enableCameraFollow ||
        (oldWidget.trackingStatus != widget.trackingStatus &&
            _trackingActive)) {
      _queueCamera(_CameraAction.automatic);
    }
  }

  @override
  void dispose() {
    _invalidateCamera(forgetPrivate: true);
    _cameraWatchdog?.cancel();
    _cameraWatch.stop();
    _mapPointers.clear();
    WidgetsBinding.instance.removeObserver(this);
    _mapVersion++;
    _styleTimeout?.cancel();
    _freshnessTimer?.cancel();
    _freshnessRevision++;
    _motion.dispose();
    _radarTimer?.cancel();
    _controller =
        null; // MapLibreMap disposes its own controller/platform view.
    _driverCircle = null;
    _driverDirection = null;
    _radarCircles.clear();
    super.dispose();
  }

  static LatLng _point(CustomerLiveLocation location) =>
      LatLng(location.latitude, location.longitude);

  void _updateVisualBearing(double? bearing) {
    if (!mounted || !_hasDisplayLocation) return;
    if (_visualBearing == bearing) return;
    _visualBearing = bearing;
    _queueMarkerSync();
  }

  void _onMapCreated(MapLibreMapController controller) {
    if (!mounted) return;
    _invalidateCamera();
    if (_controller != controller) {
      _cameraFlight++;
      _cameraWatchdog?.cancel();
      _cameraInFlight = false;
      _cameraBlocked = false;
    }
    _appliedCameraPadding = null;
    _lastCameraFix = null;
    _refreshFreshness();
    _motion.snap();
    _controller = controller;
    _driverCircle = null;
    _driverDirection = null;
    _resetDrawnDriver();
    _styleLoaded = false;
    _mapVersion++;
    _styleTimeout?.cancel();
    _styleTimeout = Timer(const Duration(seconds: 12), () {
      if (mounted && !_styleLoaded) {
        setState(() => _mapUnavailable = true);
      }
    });
  }

  void _onStyleLoaded() {
    if (!mounted) return;
    _invalidateCamera();
    _appliedCameraPadding = null;
    if (!_cameraInFlight) _cameraBlocked = false;
    _refreshFreshness();
    _motion.snap();
    _styleTimeout?.cancel();
    _mapVersion++;
    _driverCircle = null; // A style reload loses its annotation layer.
    _driverDirection = null;
    _resetDrawnDriver();
    _radarCircles.clear();
    setState(() {
      _styleLoaded = true;
      _mapUnavailable = false;
    });
    _queueRouteSync();
    _queueStaticMarkerSync();
    _refreshRadar();
    _queueCamera(_cameraPrivacyPending
        ? _CameraAction.privacy
        : _CameraAction.automatic);
  }

  void _startNativeWorker() {
    if (_nativeWorkerRunning || !mounted || _scopeChanged) return;
    _nativeWorkerRunning = true;
    unawaited(_drainNative());
  }

  void _resetDrawnDriver() {
    _drawnCirclePosition = null;
    _drawnSymbolPosition = null;
    _drawnBearing = null;
  }

  Future<void> _drainNative() async {
    await Future<void>.value();
    try {
      while (mounted &&
          !_scopeChanged &&
          _styleLoaded &&
          _controller != null &&
          (_staticRequested ||
              _driverRequested ||
              _radarRequested ||
              _routeRequested)) {
        final version = _mapVersion;
        if (_gpsRemovalPending) {
          _driverRequested = false;
          await _syncDriver(version);
          // A style change invalidates the awaited cleanup, but its new
          // requests must still drain before the cover can be released.
          if (_gpsRemovalPending && version == _mapVersion) break;
        } else if (_routeRequested) {
          _routeRequested = false;
          await _syncRoute(version);
        } else if (_staticRequested) {
          _staticRequested = false;
          await _syncStaticMarkers(version);
        } else if (_driverRequested) {
          _driverRequested = false;
          await _syncDriver(version);
        } else {
          _radarRequested = false;
          await _syncRadar(version);
        }
      }
    } catch (_) {
      // Failed deletion keeps the privacy cover. Never spin a native retry loop.
      _staticRequested =
          _driverRequested = _radarRequested = _routeRequested = false;
      if (mounted && !_scopeChanged) setState(() => _mapUnavailable = true);
    } finally {
      _nativeWorkerRunning = false;
    }
  }

  void _queueStaticMarkerSync() {
    _staticRequested = true;
    _startNativeWorker();
  }

  Future<void> _syncStaticMarkers(int version) async {
    final controller = _controller;
    if (!mounted ||
        !_styleLoaded ||
        controller == null ||
        version != _mapVersion) {
      return;
    }
    // This widget owns the style's Symbol annotations. Clearing circles
    // alone leaves the direction arrow at its previous native position.
    await controller.clearSymbols();
    if (!mounted || _controller != controller || version != _mapVersion) {
      return;
    }
    _driverDirection = null;
    await controller.clearCircles();
    if (!mounted || _controller != controller || version != _mapVersion) {
      return;
    }
    _driverCircle = null;
    _resetDrawnDriver();
    _radarCircles.clear();
    final pickup = widget.pickup;
    if (pickup?.isValid == true) {
      await controller.addCircle(CircleOptions(
        geometry: LatLng(pickup!.latitude, pickup.longitude),
        circleRadius: 12,
        circleColor: '#FFFFFF',
        circleStrokeColor: '#0066FF',
        circleStrokeWidth: 4,
      ));
    }
    if (!mounted || version != _mapVersion) {
      return;
    }
    final dropoff = widget.dropoff;
    if (dropoff?.isValid == true) {
      await controller.addCircle(CircleOptions(
        geometry: LatLng(dropoff!.latitude, dropoff.longitude),
        circleRadius: 11,
        circleColor: '#E87521',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ));
    }
    _driverRequested = true;
    _radarRequested = true;
  }

  bool get _radarAllowed =>
      widget.searchingForDriver &&
      widget.pickup?.isValid == true &&
      !_paused &&
      !_reducedMotion &&
      !_scopeChanged &&
      _styleLoaded &&
      _controller != null;

  void _refreshRadar() {
    if (!_radarAllowed) {
      _radarTimer?.cancel();
      _radarTimer = null;
      _queueRadarSync();
      return;
    }
    if (_radarTimer != null) return;
    _queueRadarSync();
    // Each radar flush can write three circles; the worker coalesces ticks
    // while native calls are in flight rather than promising a total budget.
    _radarTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      _radarTick = (_radarTick + 1) % 10;
      _queueRadarSync();
    });
  }

  void _queueRadarSync() {
    _radarRequested = true;
    _startNativeWorker();
  }

  Future<void> _syncRadar(int version) async {
    final controller = _controller;
    if (!mounted ||
        controller == null ||
        !_styleLoaded ||
        version != _mapVersion) {
      return;
    }
    if (!_radarAllowed) {
      for (final circle in _radarCircles) {
        await controller.removeCircle(circle);
        if (!mounted || _controller != controller || version != _mapVersion) {
          return;
        }
      }
      _radarCircles.clear();
      return;
    }
    final pickup = widget.pickup!;
    final point = LatLng(pickup.latitude, pickup.longitude);
    for (var index = 0; index < 3; index++) {
      if (!mounted ||
          _controller != controller ||
          version != _mapVersion ||
          !_radarAllowed) {
        return;
      }
      final phase = ((_radarTick + index * 3) % 10) / 10;
      final radius = 18.0 + phase * 44;
      if (index >= _radarCircles.length) {
        final created = await controller.addCircle(CircleOptions(
          geometry: point,
          circleRadius: radius,
          circleColor: '#3559D5',
          circleOpacity: .12,
          circleStrokeColor: '#3559D5',
          circleStrokeWidth: 1,
        ));
        if (!mounted || _controller != controller || version != _mapVersion) {
          if (mounted && _controller == controller && _styleLoaded) {
            await controller.removeCircle(created);
          }
          return;
        }
        _radarCircles.add(created);
      } else {
        await controller.updateCircle(_radarCircles[index],
            CircleOptions(geometry: point, circleRadius: radius));
      }
    }
  }

  void _queueRouteSync() {
    _routeRequested = true;
    _startNativeWorker();
  }

  Future<void> _syncRoute(int version) async {
    final controller = _controller;
    if (!mounted ||
        !_styleLoaded ||
        controller == null ||
        version != _mapVersion) {
      return;
    }
    await controller.clearLines();
    if (!mounted || version != _mapVersion) {
      return;
    }
    final line = RoadRouteLine.options(widget.route);
    if (line != null) {
      await controller.addLine(line);
    }
  }

  void _queueMarkerSync() {
    _driverRequested = true;
    _startNativeWorker();
  }

  Future<void> _syncDriver(int version) async {
    final controller = _controller;
    if (!mounted ||
        _scopeChanged ||
        !_styleLoaded ||
        controller == null ||
        version != _mapVersion) {
      return;
    }
    final position = _visualPoint;
    final bearing = _visualBearing;
    final circle = _driverCircle;
    if (!_hasDisplayLocation || position == null || _gpsRemovalPending) {
      // Clear every native arrow, including one whose addSymbol completed
      // after tracking was revoked. Keep the privacy cover on failure.
      await controller.clearSymbols();
      if (!mounted || _controller != controller || version != _mapVersion) {
        return;
      }
      _driverDirection = null;
      _drawnSymbolPosition = null;
      _drawnBearing = null;
      if (circle != null) {
        await controller.removeCircle(circle);
        if (!mounted || _controller != controller || version != _mapVersion) {
          return;
        }
        _driverCircle = null;
        _drawnCirclePosition = null;
      }
      if (_gpsRemovalPending) {
        setState(() => _gpsRemovalPending = false);
        _scheduleCamera();
        if (_hasDisplayLocation) {
          _queueMarkerSync();
        }
      }
      return;
    }
    if (_paused) return;
    if (circle == null) {
      final created = await controller.addCircle(CircleOptions(
        geometry: position,
        circleRadius: 13,
        circleColor: '#3559D5',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ));
      if (mounted && _controller == controller && version == _mapVersion) {
        _driverCircle = created;
        _drawnCirclePosition = position;
      }
    } else if (_drawnCirclePosition != position) {
      await controller.updateCircle(circle, CircleOptions(geometry: position));
      if (mounted && _controller == controller && version == _mapVersion) {
        _drawnCirclePosition = position;
      }
    }
    if (!mounted ||
        _controller != controller ||
        version != _mapVersion ||
        _scopeChanged ||
        _paused ||
        _gpsRemovalPending ||
        !_hasDisplayLocation) {
      return;
    }
    // Native bearing is from the same validated GPS sample as the position.
    // An optional arrow rotates over a bounded, ordered interpolation only.
    try {
      final direction = _driverDirection;
      if (bearing == null) {
        if (direction != null) {
          await controller.removeSymbol(direction);
          if (mounted && _controller == controller && version == _mapVersion) {
            _driverDirection = null;
            _drawnSymbolPosition = null;
            _drawnBearing = null;
          }
        }
      } else if (direction == null) {
        final created = await controller.addSymbol(SymbolOptions(
            geometry: position,
            textField: '▲',
            textRotate: bearing,
            textSize: 15,
            textColor: '#FFFFFF'));
        if (mounted && _controller == controller && version == _mapVersion) {
          _driverDirection = created;
          _drawnSymbolPosition = position;
          _drawnBearing = bearing;
          if (_gpsRemovalPending || !_hasDisplayLocation) {
            // addSymbol may finish after a terminal update. Remove that
            // result immediately; the queued privacy cleanup clears any
            // remaining annotation before uncovering the map.
            await controller.removeSymbol(created);
            if (mounted &&
                _controller == controller &&
                version == _mapVersion) {
              _driverDirection = null;
              _drawnSymbolPosition = null;
              _drawnBearing = null;
            }
          }
        } else if (mounted && _controller == controller && _styleLoaded) {
          // A style reload can finish while addSymbol is in flight.
          // The new style's queued sync also clears any remaining symbols.
          await controller.removeSymbol(created);
        }
      } else if (_drawnSymbolPosition != position || _drawnBearing != bearing) {
        await controller.updateSymbol(
            direction, SymbolOptions(geometry: position, textRotate: bearing));
        if (mounted && _controller == controller && version == _mapVersion) {
          _drawnSymbolPosition = position;
          _drawnBearing = bearing;
        }
      }
    } catch (_) {
      // Some native styles lack the arrow glyph; keep the circle visible.
    }
  }

  Future<void> _recenter() async {
    if (!_cameraReady ||
        !_trackingActive ||
        !_hasDisplayLocation ||
        _cameraPrivacyPending) {
      return;
    }
    if (!_cameraInFlight && !_cameraPrivacyPending && _cameraBlocked) {
      setState(() => _cameraBlocked = false);
    }
    if (!_canTargetCamera(_CameraAction.locate)) return;
    setState(() {
      _invalidateCamera();
      _followWanted = widget.enableCameraFollow;
    });
    _queueCamera(_CameraAction.locate);
  }

  Future<void> _fitRoute() async {
    _freeExplore();
    if (_cameraReady && !_cameraBlocked) _queueCamera(_CameraAction.route);
  }

  CameraUpdate? _routeCameraUpdate() {
    final route = widget.route;
    if (route?.available != true) return null;
    var south = route!.points.first.latitude;
    var north = south;
    var west = route.points.first.longitude;
    var east = west;
    for (final point in route.points.skip(1)) {
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }
    return CameraUpdate.newLatLngBounds(
      LatLngBounds(
          southwest: LatLng(south, west), northeast: LatLng(north, east)),
      left: 40,
      right: 40,
      top: 56,
      bottom: widget.fullBleed
          ? _mapSize.height * widget.sheetExtent.clamp(0.0, .86) + 12
          : 48,
    );
  }

  String get _connectionLabel => switch (widget.connectionState) {
        TripRealtimeConnectionState.connecting => 'Đang kết nối realtime',
        TripRealtimeConnectionState.connected => 'Realtime đã kết nối',
        TripRealtimeConnectionState.reconnecting => 'Đang kết nối lại',
        TripRealtimeConnectionState.disconnected => 'Theo dõi qua REST',
        TripRealtimeConnectionState.failed => 'Realtime không khả dụng',
      };

  Widget _mapView() => FutureBuilder<bool>(
        future: _mapReady,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data != true) {
            return const Center(
              child: Text('Không thể khởi tạo bản đồ trên thiết bị này.'),
            );
          }
          return LayoutBuilder(builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            if (size != _mapSize) {
              _mapSize = size;
              _invalidateCamera();
              _appliedCameraPadding = null;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _mapSize == size) {
                  _queueCamera(_cameraPrivacyPending
                      ? _CameraAction.privacy
                      : _CameraAction.automatic);
                }
              });
            }
            return Stack(fit: StackFit.expand, children: [
              // In full-bleed mode only the sheet intercepts gestures. The map
              // remains directly interactive in all uncovered areas.
              IgnorePointer(
                ignoring: !widget.fullBleed && !_mapInteractive,
                child: Listener(
                    key: const ValueKey('customer-native-map-input'),
                    onPointerDown: _mapPointerDown,
                    onPointerMove: _mapPointerMove,
                    onPointerUp: _mapPointerUp,
                    onPointerCancel: _mapPointerUp,
                    onPointerSignal: (_) => _freeExplore(),
                    child: MapLibreMap(
                      initialCameraPosition:
                          CameraPosition(target: _firstCenter!, zoom: 14),
                      styleString: CustomerMapSource.styleUrl,
                      myLocationEnabled: false,
                      logoEnabled: true,
                      gestureRecognizers: _mapGestures,
                      annotationOrder: const [
                        AnnotationType.line,
                        AnnotationType.circle,
                        AnnotationType.symbol,
                      ],
                      annotationConsumeTapEvents: const [AnnotationType.circle],
                      onMapCreated: _onMapCreated,
                      onStyleLoadedCallback: _onStyleLoaded,
                    )),
              ),
              if (!widget.fullBleed)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    elevation: 2,
                    child: IconButton(
                      tooltip: _mapInteractive
                          ? 'Cuộn trang'
                          : 'Kéo và thu phóng bản đồ',
                      onPressed: () =>
                          setState(() => _mapInteractive = !_mapInteractive),
                      icon: Icon(_mapInteractive
                          ? Icons.swipe_vertical
                          : Icons.pan_tool_alt),
                    ),
                  ),
                ),
              if (widget.fullBleed)
                Positioned(
                  top: 8,
                  left: 8,
                  right: widget.enableCameraFollow ? 72 : 140,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface.withAlpha(240),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Text(
                        CustomerMapSource.visibleAttribution,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              if (widget.enableCameraFollow)
                Positioned(
                    top: 8,
                    right: 8,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.route?.available == true) ...[
                          Material(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              child: IconButton(
                                  constraints: const BoxConstraints(
                                      minWidth: 48, minHeight: 48),
                                  tooltip: 'Xem tuyến',
                                  onPressed: _cameraReady &&
                                          !_cameraBlocked &&
                                          !_cameraPrivacyPending
                                      ? _fitRoute
                                      : null,
                                  icon: const Icon(Icons.route))),
                          const SizedBox(height: 8),
                        ],
                        if (_trackingActive)
                          Semantics(
                              key: const ValueKey('customer-camera-mode'),
                              value: _cameraMode,
                              child: Material(
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  child: IconButton(
                                    key: const ValueKey(
                                        'customer-follow-button'),
                                    constraints: const BoxConstraints(
                                        minWidth: 48, minHeight: 48),
                                    tooltip: !_canFollow
                                        ? 'Theo dõi chưa sẵn sàng'
                                        : _followWanted
                                            ? 'Đang theo dõi tài xế'
                                            : 'Theo dõi tài xế',
                                    isSelected: _followWanted && _canFollow,
                                    onPressed: _canFollow ||
                                            (_cameraReady &&
                                                _cameraBlocked &&
                                                !_cameraInFlight &&
                                                !_cameraPrivacyPending &&
                                                _hasDisplayLocation &&
                                                _cameraFixUsable)
                                        ? _recenter
                                        : null,
                                    icon: const Icon(Icons.my_location),
                                  ))),
                      ],
                    )),
              if (!widget.enableCameraFollow && widget.route?.available == true)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    elevation: 2,
                    child: TextButton.icon(
                      onPressed: _styleLoaded ? _fitRoute : null,
                      icon: const Icon(Icons.route),
                      label: const Text('Xem tuyến'),
                    ),
                  ),
                ),
              if (!widget.enableCameraFollow && _hasDisplayLocation)
                Positioned(
                  top: widget.route?.available == true ? 54 : 8,
                  right: 8,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    elevation: 2,
                    child: TextButton.icon(
                      onPressed: _styleLoaded ? _recenter : null,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Tìm tài xế'),
                    ),
                  ),
                ),
              if (_gpsRemovalPending || _cameraCover)
                const Positioned.fill(
                  child: AbsorbPointer(
                    child: ColoredBox(color: Color(0xFFF8F9FA)),
                  ),
                ),
            ]);
          });
        },
      );

  @override
  Widget build(BuildContext context) {
    if (_scopeChanged) {
      return const Text('Phiên theo dõi đã thay đổi. Hãy mở lại chuyến.');
    }
    if (_firstCenter == null) {
      if (_cameraPrivacyPending) return const Text('Vị trí tài xế đã được ẩn.');
      return Text(_locationStale
          ? 'Vị trí tài xế chưa được cập nhật.'
          : 'Chưa có tọa độ GPS hợp lệ để hiển thị trên bản đồ.');
    }
    if (widget.fullBleed) {
      return Stack(fit: StackFit.expand, children: [
        _mapView(),
        if (_locationStale) const Positioned.fill(child: _GpsStaleWarning()),
        if (_hasDisplayLocation && !_shownLocation!.hasInterpolationAccuracy)
          Positioned(
              top: 112,
              left: 12,
              right: 12,
              child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_shownLocation!.accuracy == null
                          ? 'Độ chính xác GPS chưa xác định.'
                          : 'GPS có độ chính xác thấp (±${_shownLocation!.accuracy!.toStringAsFixed(0)} m).')))),
        if (!_styleLoaded && !_mapUnavailable && !_setupFailed)
          const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child:
                  LinearProgressIndicator(semanticsLabel: 'Đang tải bản đồ')),
        if (_mapUnavailable || _setupFailed)
          Positioned(
            top: 64,
            left: 12,
            right: 12,
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    'Không tải được bản đồ. Vị trí GPS bằng chữ vẫn có trong chi tiết chuyến.'),
              ),
            ),
          ),
      ]);
    }
    final height =
        (MediaQuery.sizeOf(context).height * .30).clamp(220.0, 290.0);
    final accuracy = _shownLocation?.accuracy;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: height,
          child: _mapView(),
        ),
      ),
      if (!_styleLoaded && !_mapUnavailable && !_setupFailed)
        const LinearProgressIndicator(semanticsLabel: 'Đang tải bản đồ'),
      if (_mapUnavailable || _setupFailed)
        const Text(
          'Không tải được bản đồ. Vị trí GPS bằng chữ vẫn có ở bên dưới.',
          style: TextStyle(color: Colors.deepOrange),
        ),
      if (_hasDisplayLocation)
        const Row(children: [
          Icon(Icons.circle, color: Color(0xFF3559D5), size: 16),
          SizedBox(width: 4),
          Expanded(child: Text('Vị trí tài xế')),
        ]),
      Text(
        _mapInteractive
            ? 'Đang điều khiển bản đồ. Chạm nút bên trái để cuộn trang.'
            : 'Vuốt để cuộn trang; chạm nút bên trái để kéo/thu phóng bản đồ.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Text(_connectionLabel, style: Theme.of(context).textTheme.bodySmall),
      if (_locationStale) const Text('Vị trí tài xế chưa được cập nhật.'),
      if (_hasDisplayLocation && !_shownLocation!.hasInterpolationAccuracy)
        Text(accuracy == null
            ? 'Độ chính xác GPS chưa xác định.'
            : 'GPS có độ chính xác thấp.'),
      if (_hasDisplayLocation)
        Text(
          'GPS: ${_shownLocation!.updatedAt.toLocal()}'
          '${accuracy != null && accuracy.isFinite && accuracy >= 0 ? ' · ±${accuracy.toStringAsFixed(1)} m' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      Text(CustomerMapSource.visibleAttribution,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

/// Presentation only: freshness and visibility remain owned by the map state.
class _GpsStaleWarning extends StatelessWidget {
  const _GpsStaleWarning();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: LayoutBuilder(builder: (context, constraints) {
          final theme = Theme.of(context);
          final textScaler = MediaQuery.textScalerOf(context);
          final availableWidth = math.max(0.0, constraints.maxWidth - 24);
          final compactWidth = (constraints.maxWidth * .25).clamp(180.0, 320.0);
          final width = math.min(availableWidth,
              compactWidth * math.max(1.0, textScaler.scale(13) / 13));

          // Keep clear of the existing top controls and scaled attribution.
          final attribution = TextPainter(
            text: TextSpan(
                text: CustomerMapSource.visibleAttribution,
                style: theme.textTheme.labelSmall),
            textDirection: Directionality.of(context),
            textScaler: textScaler,
            maxLines: 3,
            ellipsis: '\u2026',
          )..layout(maxWidth: math.max(1.0, constraints.maxWidth - 160));
          final top = math.max(112.0, attribution.height + 28);
          attribution.dispose();

          return Stack(children: [
            Positioned(
              top: top,
              left: 12,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: Semantics(
                  liveRegion: true,
                  child: Material(
                    key: const ValueKey('customer-gps-stale-warning'),
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const ExcludeSemantics(
                              child: Icon(Icons.warning_amber_rounded,
                                  size: 18, color: AppColors.warning),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Vị trí tài xế chưa được cập nhật.',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 13,
                                    height: 1.3,
                                    color: theme.colorScheme.onSurface),
                              ),
                            ),
                          ]),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }),
      );
}
