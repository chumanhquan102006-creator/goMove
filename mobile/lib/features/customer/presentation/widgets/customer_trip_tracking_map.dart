import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Factory, visibleForTesting;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

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
          CustomerLiveLocation? current, CustomerLiveLocation candidate) =>
      isRenderable(candidate) &&
      (current == null ||
          !isRenderable(current) ||
          candidate.updatedAt.isAfter(current.updatedAt));

  @override
  State<CustomerTripTrackingMap> createState() =>
      _CustomerTripTrackingMapState();
}

/// Presentation-only motion between two accepted GPS samples. It never
/// publishes a location or moves the camera. Three 100 ms steps cap native
/// annotation writes at 10/s, with no timer while idle.
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
  CustomerLiveLocation? _accepted;
  Timer? _timer;

  CustomerMarkerMotion(
      {required this.onPosition, this.onBearing, DateTime Function()? now})
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
        !CustomerTripTrackingMap.shouldAcceptNewFix(first, second)) {
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

  static LatLng _at(CustomerLiveLocation first, CustomerLiveLocation second,
      double progress) {
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
    if (!CustomerTripTrackingMap.isRenderable(sample) ||
        (_accepted != null &&
            !CustomerTripTrackingMap.shouldAcceptNewFix(_accepted, sample))) {
      return;
    }
    final prior = _accepted;
    final interrupted = _timer != null;
    _timer?.cancel();
    _timer = null;
    _accepted = sample;
    if (!interrupted &&
        prior != null &&
        prior.latitude == sample.latitude &&
        prior.longitude == sample.longitude) {
      // A fresh timestamp for a stationary driver needs no native write.
      onBearing?.call(bearingAt(prior.bearing, sample.bearing, 1));
      return;
    }
    if (!animate ||
        interrupted ||
        prior == null ||
        !canInterpolate(prior, sample, now())) {
      onBearing?.call(bearingAt(prior?.bearing, sample.bearing, 1));
      onPosition(LatLng(sample.latitude, sample.longitude));
      return;
    }
    var step = 0;
    _timer = Timer.periodic(tick, (timer) {
      step++;
      if (step == 3) {
        timer.cancel();
        _timer = null;
        onBearing?.call(bearingAt(prior.bearing, sample.bearing, 1));
        onPosition(LatLng(sample.latitude, sample.longitude));
      } else {
        onBearing?.call(bearingAt(prior.bearing, sample.bearing, step / 3));
        onPosition(_at(prior, sample, step / 3));
      }
    });
  }

  void snap() {
    _timer?.cancel();
    _timer = null;
    final accepted = _accepted;
    if (accepted != null) {
      onBearing?.call(bearingAt(null, accepted.bearing, 1));
      onPosition(LatLng(accepted.latitude, accepted.longitude));
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
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
  Future<void> _markerSync = Future<void>.value();
  Future<void> _routeSync = Future<void>.value();
  int? _pendingMarkerVersion;
  int _mapVersion = 0;
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _setupFailed = false;
  bool _mapInteractive = false;
  bool _reducedMotion = false;
  bool _paused = false;
  bool _scopeChanged = false;
  bool _gpsRemovalPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shownLocation = widget.location;
    _visualPoint = _shownLocation == null ? null : _point(_shownLocation!);
    _visualBearing = _shownLocation?.bearing;
    _motion = CustomerMarkerMotion(
        now: widget.motionNow,
        onBearing: _updateVisualBearing,
        onPosition: (point) {
          _visualPoint = point;
          widget.onVisualPosition?.call(point);
          _queueMarkerSync();
        });
    if (_shownLocation != null) {
      _motion.accept(_shownLocation!, animate: false);
    }
    if (CustomerTripTrackingMap.isRenderable(_shownLocation)) {
      _firstCenter = _point(_shownLocation!);
    } else if (widget.route?.available == true) {
      final first = widget.route!.points.first;
      _firstCenter = LatLng(first.latitude, first.longitude);
    } else if (widget.pickup?.isValid == true) {
      _firstCenter = LatLng(widget.pickup!.latitude, widget.pickup!.longitude);
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
      _queueMarkerSync();
      _refreshRadar();
    } else {
      _paused = true;
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
      _motion = CustomerMarkerMotion(
          now: widget.motionNow,
          onBearing: _updateVisualBearing,
          onPosition: (point) {
            _visualPoint = point;
            widget.onVisualPosition?.call(point);
            _queueMarkerSync();
          });
      _shownLocation = null;
      _visualPoint = null;
      _visualBearing = null;
      _queueMarkerSync();
    } else if (widget.location != null &&
        CustomerTripTrackingMap.shouldAcceptNewFix(
            _shownLocation, widget.location!)) {
      _shownLocation = widget.location;
      _firstCenter ??= _point(_shownLocation!);
      _motion.accept(_shownLocation!,
          animate: widget.enableMarkerInterpolation &&
              !_paused &&
              !_reducedMotion &&
              _styleLoaded);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapVersion++;
    _styleTimeout?.cancel();
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
    if (_visualBearing == bearing) return;
    _visualBearing = bearing;
    _queueMarkerSync();
  }

  void _onMapCreated(MapLibreMapController controller) {
    _motion.snap();
    _controller = controller;
    _driverCircle = null;
    _driverDirection = null;
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
    _motion.snap();
    _styleTimeout?.cancel();
    _mapVersion++;
    _driverCircle = null; // A style reload loses its annotation layer.
    _driverDirection = null;
    _radarCircles.clear();
    setState(() {
      _styleLoaded = true;
      _mapUnavailable = false;
    });
    _queueRouteSync();
    _queueStaticMarkerSync();
    _refreshRadar();
  }

  void _queueStaticMarkerSync() {
    final version = _mapVersion;
    _markerSync = _markerSync.then((_) async {
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
    }).then((_) {
      if (!mounted || version != _mapVersion || _scopeChanged) return;
      _queueMarkerSync();
      _queueRadarSync();
    }).catchError((Object _) {
      // Trip details and CASH stay available if native annotations fail.
    });
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
    // Native annotation writes are capped near ten per second in total.
    _radarTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      _radarTick = (_radarTick + 1) % 10;
      _queueRadarSync();
    });
  }

  void _queueRadarSync() {
    final version = _mapVersion;
    _markerSync = _markerSync.then((_) async {
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
        }
        _radarCircles.clear();
        return;
      }
      final pickup = widget.pickup!;
      final point = LatLng(pickup.latitude, pickup.longitude);
      for (var index = 0; index < 3; index++) {
        final phase = ((_radarTick + index * 3) % 10) / 10;
        final radius = 18.0 + phase * 44;
        if (index >= _radarCircles.length) {
          _radarCircles.add(await controller.addCircle(CircleOptions(
            geometry: point,
            circleRadius: radius,
            circleColor: '#3559D5',
            circleOpacity: .12,
            circleStrokeColor: '#3559D5',
            circleStrokeWidth: 1,
          )));
        } else {
          await controller.updateCircle(_radarCircles[index],
              CircleOptions(geometry: point, circleRadius: radius));
        }
      }
    }).catchError((Object _) {
      // Booking status and native map remain usable if radar rendering fails.
    });
  }

  void _queueRouteSync() {
    final version = _mapVersion;
    _routeSync = _routeSync.then((_) async {
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
    }).catchError((Object _) {
      // The GPS and trip details remain usable if native route drawing fails.
    });
  }

  void _queueMarkerSync() {
    final version = _mapVersion;
    if (_pendingMarkerVersion == version) return;
    _pendingMarkerVersion = version;
    // Serialise platform calls; each queued operation reads the latest fix.
    _markerSync = _markerSync.then((_) async {
      if (_pendingMarkerVersion == version) _pendingMarkerVersion = null;
      final controller = _controller;
      if (!mounted ||
          _scopeChanged ||
          !_styleLoaded ||
          controller == null ||
          version != _mapVersion) {
        return;
      }
      final position = _visualPoint;
      final circle = _driverCircle;
      if (!CustomerTripTrackingMap.isRenderable(_shownLocation) ||
          position == null ||
          _gpsRemovalPending) {
        // Clear every native arrow, including one whose addSymbol completed
        // after tracking was revoked. Keep the privacy cover on failure.
        await controller.clearSymbols();
        if (!mounted || _controller != controller || version != _mapVersion) {
          return;
        }
        _driverDirection = null;
        if (circle != null) {
          await controller.removeCircle(circle);
          if (!mounted || _controller != controller || version != _mapVersion) {
            return;
          }
          _driverCircle = null;
        }
        if (_gpsRemovalPending) {
          setState(() => _gpsRemovalPending = false);
          if (CustomerTripTrackingMap.isRenderable(_shownLocation)) {
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
        }
      } else {
        await controller.updateCircle(
            circle, CircleOptions(geometry: position));
      }
      if (!mounted ||
          _controller != controller ||
          version != _mapVersion ||
          _scopeChanged ||
          _paused ||
          _gpsRemovalPending ||
          !CustomerTripTrackingMap.isRenderable(_shownLocation)) {
        return;
      }
      // Native bearing is from the same validated GPS sample as the position.
      // An optional arrow rotates over a bounded, ordered interpolation only.
      try {
        final bearing = _visualBearing;
        final direction = _driverDirection;
        if (bearing == null) {
          if (direction != null) {
            await controller.removeSymbol(direction);
            if (mounted &&
                _controller == controller &&
                version == _mapVersion) {
              _driverDirection = null;
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
            if (_gpsRemovalPending ||
                !CustomerTripTrackingMap.isRenderable(_shownLocation)) {
              // addSymbol may finish after a terminal update. Remove that
              // result immediately; the queued privacy cleanup clears any
              // remaining annotation before uncovering the map.
              await controller.removeSymbol(created);
              if (mounted &&
                  _controller == controller &&
                  version == _mapVersion) {
                _driverDirection = null;
              }
            }
          } else if (mounted && _controller == controller && _styleLoaded) {
            // A style reload can finish while addSymbol is in flight.
            // The new style's queued sync also clears any remaining symbols.
            await controller.removeSymbol(created);
          }
        } else {
          await controller.updateSymbol(direction,
              SymbolOptions(geometry: position, textRotate: bearing));
        }
      } catch (_) {
        // Some native styles lack the arrow glyph; keep the circle visible.
      }
    }).catchError((Object _) {
      if (mounted && version == _mapVersion) {
        setState(() => _mapUnavailable = true);
      }
    });
  }

  Future<void> _recenter() async {
    final controller = _controller;
    if (controller == null ||
        !_styleLoaded ||
        !CustomerTripTrackingMap.isRenderable(_shownLocation)) {
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
            if (CustomerTripTrackingMap.isRenderable(_shownLocation))
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
    if (!CustomerTripTrackingMap.isRenderable(_shownLocation) &&
        widget.route?.available != true &&
        widget.pickup?.isValid != true &&
        widget.dropoff?.isValid != true) {
      return const Text('Chưa có tọa độ GPS hợp lệ để hiển thị trên bản đồ.');
    }
    if (widget.fullBleed) {
      return Stack(fit: StackFit.expand, children: [
        _mapView(),
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
      if (CustomerTripTrackingMap.isRenderable(_shownLocation))
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
      if (CustomerTripTrackingMap.isRenderable(_shownLocation))
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
