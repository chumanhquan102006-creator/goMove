import 'dart:async';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/theme/app_motion.dart';
import '../../../customer/presentation/widgets/customer_map_source.dart';
import '../../../customer/domain/models/quote.dart';
import '../../../trip/domain/models/road_route.dart';
import '../../../trip/presentation/widgets/road_route_line.dart';
import '../../domain/models/driver_models.dart';

/// Presentation of the two points supplied by an authorized Driver offer.
/// No Customer location or driving route is inferred from these coordinates.
class DriverTripMap extends StatefulWidget {
  final DriverOffer offer;
  final RoadRoute? route;

  const DriverTripMap({super.key, required this.offer, this.route});

  static bool hasValidPoints(DriverOffer offer) =>
      _valid(offer.pickupLatitude, offer.pickupLongitude) &&
      _valid(offer.dropoffLatitude, offer.dropoffLongitude);

  static bool _valid(double latitude, double longitude) =>
      latitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude.isFinite &&
      longitude >= -180 &&
      longitude <= 180;

  /// Point markers come from the authorized offer, never from route endpoints.
  static List<CircleOptions> pointMarkers(DriverOffer offer) => [
        CircleOptions(
          geometry: LatLng(offer.pickupLatitude, offer.pickupLongitude),
          circleRadius: 12,
          circleColor: '#FFFFFF',
          circleStrokeColor: '#0066FF',
          circleStrokeWidth: 4,
        ),
        CircleOptions(
          geometry: LatLng(offer.dropoffLatitude, offer.dropoffLongitude),
          circleRadius: 11,
          circleColor: '#E87521',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      ];

  @override
  State<DriverTripMap> createState() => _DriverTripMapState();
}

class _DriverTripMapState extends State<DriverTripMap> {
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  late final Future<bool> _mapReady;
  MapLibreMapController? _controller;
  Timer? _styleTimeout;
  Future<void> _annotationSync = Future<void>.value();
  int _mapVersion = 0;
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _markerError = false;
  bool _cameraError = false;
  bool _initialFitDone = false;

  LatLng get _pickup =>
      LatLng(widget.offer.pickupLatitude, widget.offer.pickupLongitude);
  LatLng get _dropoff =>
      LatLng(widget.offer.dropoffLatitude, widget.offer.dropoffLongitude);

  @override
  void initState() {
    super.initState();
    _mapReady = _configureRequests();
  }

  Future<bool> _configureRequests() async {
    try {
      // Tile requests carry no JWT, Booking UUID or driver account details.
      await CustomerMapSource.configureRequests();
      return mounted;
    } catch (_) {
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant DriverTripMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offer.bookingPublicId != widget.offer.bookingPublicId ||
        oldWidget.offer.pickupLatitude != widget.offer.pickupLatitude ||
        oldWidget.offer.pickupLongitude != widget.offer.pickupLongitude ||
        oldWidget.offer.dropoffLatitude != widget.offer.dropoffLatitude ||
        oldWidget.offer.dropoffLongitude != widget.offer.dropoffLongitude ||
        !identical(oldWidget.route, widget.route)) {
      // A different authorized offer may change annotations, but not the
      // platform-view identity or the user's camera position.
      _queueAnnotationSync();
    }
  }

  @override
  void dispose() {
    _mapVersion++;
    _styleTimeout?.cancel();
    _controller = null; // MapLibreMap disposes its own native controller.
    super.dispose();
  }

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
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
    _styleTimeout?.cancel();
    _mapVersion++;
    setState(() {
      _styleLoaded = true;
      _mapUnavailable = false;
    });
    _queueAnnotationSync();
    // Initial fit is allowed once. A later style reload must not recenter a
    // map the Driver has already panned or zoomed.
    if (!_initialFitDone) {
      _initialFitDone = true;
      unawaited(_fitPoints());
    }
  }

  void _queueAnnotationSync() {
    final version = _mapVersion;
    _annotationSync = _annotationSync.then((_) async {
      final controller = _controller;
      if (!mounted ||
          !_styleLoaded ||
          controller == null ||
          version != _mapVersion) {
        return;
      }
      await controller.clearLines();
      if (!mounted || version != _mapVersion) return;
      final route = widget.route;
      if (route != null &&
          route.matchesEndpoints(
              Coordinates(
                  widget.offer.pickupLatitude, widget.offer.pickupLongitude),
              Coordinates(widget.offer.dropoffLatitude,
                  widget.offer.dropoffLongitude))) {
        final line = RoadRouteLine.options(route);
        if (line != null) await controller.addLine(line);
      }
      if (!mounted || version != _mapVersion) return;
      await controller.clearCircles();
      if (!mounted || version != _mapVersion) return;
      for (final marker in DriverTripMap.pointMarkers(widget.offer)) {
        if (!mounted || version != _mapVersion) return;
        await controller.addCircle(marker);
      }
      if (mounted && _markerError) {
        setState(() => _markerError = false);
      }
    }).catchError((Object _) {
      if (mounted && version == _mapVersion) {
        setState(() => _markerError = true);
      }
    });
  }

  Future<void> _fitPoints() async {
    final controller = _controller;
    if (!_styleLoaded || controller == null) return;
    final pickup = _pickup;
    final dropoff = _dropoff;
    final samePoint = pickup.latitude == dropoff.latitude &&
        pickup.longitude == dropoff.longitude;
    final update = samePoint
        ? CameraUpdate.newLatLngZoom(pickup, 15)
        : CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(
                pickup.latitude < dropoff.latitude
                    ? pickup.latitude
                    : dropoff.latitude,
                pickup.longitude < dropoff.longitude
                    ? pickup.longitude
                    : dropoff.longitude,
              ),
              northeast: LatLng(
                pickup.latitude > dropoff.latitude
                    ? pickup.latitude
                    : dropoff.latitude,
                pickup.longitude > dropoff.longitude
                    ? pickup.longitude
                    : dropoff.longitude,
              ),
            ),
            left: 40,
            right: 40,
            top: 56,
            bottom: MediaQuery.sizeOf(context).height * .42,
          );
    try {
      await controller.animateCamera(
        update,
        duration:
            AppMotion.duration(context, const Duration(milliseconds: 300)),
      );
      if (mounted && _cameraError) setState(() => _cameraError = false);
    } catch (_) {
      if (mounted) setState(() => _cameraError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DriverTripMap.hasValidPoints(widget.offer)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Không có tọa độ điểm đón và điểm đến hợp lệ cho chuyến này.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return FutureBuilder<bool>(
      future: _mapReady,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.data != true) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Không thể khởi tạo bản đồ. Tọa độ được phép xem trong bảng thông tin.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Stack(fit: StackFit.expand, children: [
          MapLibreMap(
            key: const ValueKey('driver-trip-native-map'),
            initialCameraPosition: CameraPosition(target: _pickup, zoom: 14),
            styleString: CustomerMapSource.styleUrl,
            myLocationEnabled: false,
            logoEnabled: true,
            gestureRecognizers: _mapGestures,
            annotationOrder: const [AnnotationType.line, AnnotationType.circle],
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
          ),
          Positioned(
            top: 8,
            left: 8,
            right: 68,
            child: Material(
              color: Theme.of(context).colorScheme.surface.withAlpha(240),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  CustomerMapSource.visibleAttribution,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
          if (_mapUnavailable)
            const AbsorbPointer(
              child: ColoredBox(
                color: Color(0xDDF8F9FA),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nền bản đồ tạm thời không tải được. Xem tọa độ trong bảng thông tin.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 12,
            right: 12,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 3,
              borderRadius: BorderRadius.circular(12),
              child: IconButton(
                tooltip: 'Xem 2 điểm',
                onPressed: _styleLoaded && !_mapUnavailable ? _fitPoints : null,
                icon: const Icon(Icons.zoom_out_map),
              ),
            ),
          ),
          if (_markerError || _cameraError)
            Positioned(
              top: 68,
              left: 12,
              right: 12,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_markerError
                      ? 'Không cập nhật được dấu điểm trên bản đồ.'
                      : 'Không điều chỉnh được góc nhìn bản đồ.'),
                ),
              ),
            ),
        ]);
      },
    );
  }
}
