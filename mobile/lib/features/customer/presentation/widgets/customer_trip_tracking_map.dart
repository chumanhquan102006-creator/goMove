import 'dart:async';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../trip/data/trip_realtime_client.dart';
import '../bloc/booking_status_cubit.dart';
import 'customer_map_source.dart';

/// A single, read-only map of the authorized driver's latest GPS fix.
///
/// The caller must remove this widget when the Booking stops allowing live
/// location; that immediately disposes the platform view and its marker.
class CustomerTripTrackingMap extends StatefulWidget {
  final CustomerLiveLocation location;
  final TripRealtimeConnectionState connectionState;

  const CustomerTripTrackingMap({
    super.key,
    required this.location,
    required this.connectionState,
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

class _CustomerTripTrackingMapState extends State<CustomerTripTrackingMap> {
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  late CustomerLiveLocation _shownLocation;
  LatLng? _firstCenter;
  late final Future<bool> _mapReady;
  MapLibreMapController? _controller;
  Circle? _driverCircle;
  Timer? _styleTimeout;
  Future<void> _markerSync = Future<void>.value();
  int _mapVersion = 0;
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _setupFailed = false;
  bool _mapInteractive = false;

  @override
  void initState() {
    super.initState();
    _shownLocation = widget.location;
    if (CustomerTripTrackingMap.isRenderable(_shownLocation)) {
      _firstCenter = _point(_shownLocation);
    }
    _mapReady = _configureMapRequests();
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
    if (CustomerTripTrackingMap.shouldAcceptNewFix(
        _shownLocation, widget.location)) {
      _shownLocation = widget.location;
      _firstCenter ??= _point(_shownLocation);
      _queueMarkerSync();
    }
  }

  @override
  void dispose() {
    _mapVersion++;
    _styleTimeout?.cancel();
    _controller =
        null; // MapLibreMap disposes its own controller/platform view.
    _driverCircle = null;
    super.dispose();
  }

  static LatLng _point(CustomerLiveLocation location) =>
      LatLng(location.latitude, location.longitude);

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    _driverCircle = null;
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
    _driverCircle = null; // A style reload loses its annotation layer.
    setState(() {
      _styleLoaded = true;
      _mapUnavailable = false;
    });
    _queueMarkerSync();
  }

  void _queueMarkerSync() {
    final version = _mapVersion;
    // Serialise platform calls; each queued operation reads the latest fix.
    _markerSync = _markerSync.then((_) async {
      final controller = _controller;
      if (!mounted ||
          !_styleLoaded ||
          controller == null ||
          version != _mapVersion ||
          !CustomerTripTrackingMap.isRenderable(_shownLocation)) {
        return;
      }
      final position = _point(_shownLocation);
      final circle = _driverCircle;
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
        CameraUpdate.newLatLng(_point(_shownLocation)),
        duration: const Duration(milliseconds: 300),
      );
    } catch (_) {
      if (mounted) setState(() => _mapUnavailable = true);
    }
  }

  String get _connectionLabel => switch (widget.connectionState) {
        TripRealtimeConnectionState.connecting => 'Đang kết nối realtime',
        TripRealtimeConnectionState.connected => 'Realtime đã kết nối',
        TripRealtimeConnectionState.reconnecting => 'Đang kết nối lại',
        TripRealtimeConnectionState.disconnected => 'Theo dõi qua REST',
        TripRealtimeConnectionState.failed => 'Realtime không khả dụng',
      };

  @override
  Widget build(BuildContext context) {
    if (!CustomerTripTrackingMap.isRenderable(_shownLocation)) {
      return const Text('Chưa có tọa độ GPS hợp lệ để hiển thị trên bản đồ.');
    }
    final height =
        (MediaQuery.sizeOf(context).height * .30).clamp(220.0, 290.0);
    final accuracy = _shownLocation.accuracy;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: height,
          child: FutureBuilder<bool>(
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
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Scrolling the trip page is the default on a small screen.
                  // Opting in to map gestures does not recreate the native map.
                  IgnorePointer(
                    ignoring: !_mapInteractive,
                    child: MapLibreMap(
                      initialCameraPosition:
                          CameraPosition(target: _firstCenter!, zoom: 15),
                      styleString: CustomerMapSource.styleUrl,
                      myLocationEnabled: false,
                      logoEnabled: true,
                      gestureRecognizers: _mapGestures,
                      annotationOrder: const [AnnotationType.circle],
                      annotationConsumeTapEvents: const [AnnotationType.circle],
                      onMapCreated: _onMapCreated,
                      onStyleLoadedCallback: _onStyleLoaded,
                    ),
                  ),
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
                  Positioned(
                    top: 8,
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
                ],
              );
            },
          ),
        ),
      ),
      if (!_styleLoaded && !_mapUnavailable && !_setupFailed)
        const LinearProgressIndicator(semanticsLabel: 'Đang tải bản đồ'),
      if (_mapUnavailable || _setupFailed)
        const Text(
          'Không tải được bản đồ. Vị trí GPS bằng chữ vẫn có ở bên dưới.',
          style: TextStyle(color: Colors.deepOrange),
        ),
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
      Text(
        'GPS: ${_shownLocation.updatedAt.toLocal()}'
        '${accuracy != null && accuracy.isFinite && accuracy >= 0 ? ' · ±${accuracy.toStringAsFixed(1)} m' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Text(CustomerMapSource.visibleAttribution,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
