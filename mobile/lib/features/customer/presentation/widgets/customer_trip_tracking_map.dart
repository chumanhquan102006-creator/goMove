import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Factory, visibleForTesting;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
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
    this.route,
    this.pickup,
    this.dropoff,
    this.fullBleed = false,
    this.bookingPublicId,
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
    _mapReady = _configureMapRequests();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduceMotion(context);
    if (reduced && !_reducedMotion) _motion.snap();
    _reducedMotion = reduced;
    _refreshRadar();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _paused = false;
      _refreshFreshness();
      _queueMarkerSync();
      _refreshRadar();
    } else {
      _paused = true;
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
      _freshnessTimer?.cancel();
      _freshnessRevision++;
      _motion.dispose();
      _radarTimer?.cancel();
      _radarTimer = null;
      _mapVersion++;
      return;
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
      if (_hasDisplayLocation) {
        _firstCenter ??= _point(_shownLocation!);
        _motion.accept(_shownLocation!,
            animate: widget.enableMarkerInterpolation &&
                !_paused &&
                !_reducedMotion &&
                _styleLoaded);
      }
    }
  }

  @override
  void dispose() {
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
    final controller = _controller;
    if (controller == null || !_styleLoaded || !_hasDisplayLocation) {
      return;
    }
    try {
      // newLatLng changes the target, not the user's current zoom level.
      await controller.animateCamera(
        CameraUpdate.newLatLng(_point(_shownLocation!)),
        duration:
            AppMotion.duration(context, const Duration(milliseconds: 300)),
      );
    } catch (_) {
      if (mounted) setState(() => _mapUnavailable = true);
    }
  }

  Future<void> _fitRoute() async {
    final controller = _controller;
    final route = widget.route;
    if (!_styleLoaded || controller == null || route?.available != true) return;
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
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
              southwest: LatLng(south, west), northeast: LatLng(north, east)),
          left: 40,
          right: 40,
          top: 56,
          bottom:
              widget.fullBleed ? MediaQuery.sizeOf(context).height * .38 : 48,
        ),
        duration:
            AppMotion.duration(context, const Duration(milliseconds: 300)),
      );
    } catch (_) {
      // Camera controls are optional; never replace confirmed route/GPS data.
    }
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
          return Stack(fit: StackFit.expand, children: [
            // In full-bleed mode only the sheet intercepts gestures. The map
            // remains directly interactive in all uncovered areas.
            IgnorePointer(
              ignoring: !widget.fullBleed && !_mapInteractive,
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
              ),
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
                right: 140,
                child: Material(
                  color: Theme.of(context).colorScheme.surface.withAlpha(240),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      CustomerMapSource.visibleAttribution,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
            if (widget.route?.available == true)
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
            if (_hasDisplayLocation)
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
            if (_gpsRemovalPending)
              const Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(color: Color(0xFFF8F9FA)),
                ),
              ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    if (_scopeChanged) {
      return const Text('Phiên theo dõi đã thay đổi. Hãy mở lại chuyến.');
    }
    if (_firstCenter == null) {
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
