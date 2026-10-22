import 'dart:async';

import 'package:flutter/foundation.dart' show Factory, kIsWeb;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../domain/models/quote.dart';

/// A small seam for widget tests; production always uses [CustomerMapCanvas].
typedef CustomerMapBuilder = Widget Function(
  BuildContext context,
  Coordinates? pickup,
  Coordinates? dropoff,
  ValueChanged<Coordinates> onTap,
);

class CustomerMapCanvas extends StatefulWidget {
  final Coordinates? pickup;
  final Coordinates? dropoff;
  final ValueChanged<Coordinates> onTap;

  const CustomerMapCanvas({
    super.key,
    required this.pickup,
    required this.dropoff,
    required this.onTap,
  });

  @override
  State<CustomerMapCanvas> createState() => _CustomerMapCanvasState();
}

class _CustomerMapCanvasState extends State<CustomerMapCanvas> {
  static const _configuredStyle = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: MapLibreStyles.openfreemapLiberty,
  );
  static const _configuredAttribution =
      String.fromEnvironment('MAP_ATTRIBUTION');
  static const _hanoi = LatLng(21.0287, 105.8524);
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  static String get _visibleAttribution {
    if (_configuredAttribution.trim().isNotEmpty) {
      return _configuredAttribution;
    }
    if (_configuredStyle.trim().isEmpty ||
        _configuredStyle == MapLibreStyles.openfreemapLiberty) {
      return 'Nền bản đồ: OpenFreeMap · © OpenMapTiles · dữ liệu © OpenStreetMap contributors';
    }
    return 'Nguồn bản đồ tùy chỉnh: xem nút ghi công trên bản đồ; đặt MAP_ATTRIBUTION khi build.';
  }

  MapLibreMapController? _controller;
  Timer? _styleTimeout;
  Timer? _markerDebounce;
  late final Future<bool> _mapReady;
  Future<void> _markerSync = Future<void>.value();
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _setupFailed = false;

  @override
  void initState() {
    super.initState();
    _mapReady = _configureMapRequests();
  }

  Future<bool> _configureMapRequests() async {
    try {
      // Identify native tile requests before creating the map. Never send
      // JWTs, account IDs or Booking IDs to an external tile provider.
      if (!kIsWeb) {
        await setHttpHeaders({
          'User-Agent': 'GoMoveAcademicDemo/1.0 (MapLibre Flutter)',
        });
      }
      if (!mounted) return false;
      _styleTimeout = Timer(const Duration(seconds: 12), () {
        if (mounted && !_styleLoaded) {
          setState(() => _mapUnavailable = true);
        }
      });
      return true;
    } catch (_) {
      if (mounted) setState(() => _setupFailed = true);
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant CustomerMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePoint(widget.pickup, oldWidget.pickup) ||
        !_samePoint(widget.dropoff, oldWidget.dropoff)) {
      _markerDebounce?.cancel();
      _markerDebounce =
          Timer(const Duration(milliseconds: 180), _queueMarkerSync);
    }
  }

  static bool _samePoint(Coordinates? a, Coordinates? b) =>
      a?.latitude == b?.latitude && a?.longitude == b?.longitude;

  @override
  void dispose() {
    _styleTimeout?.cancel();
    _markerDebounce?.cancel();
    _controller = null; // MapLibreMap owns and disposes its controller.
    super.dispose();
  }

  void _onStyleLoaded() {
    _styleTimeout?.cancel();
    if (!mounted) return;
    setState(() {
      _styleLoaded = true;
      _mapUnavailable = false;
    });
    _markerDebounce?.cancel();
    _queueMarkerSync();
  }

  void _queueMarkerSync() {
    // Serialise native annotation calls when the user edits coordinates quickly.
    _markerSync = _markerSync.then((_) async {
      final controller = _controller;
      if (!mounted || !_styleLoaded || controller == null) return;
      await controller.clearCircles();
      if (!mounted) return;
      final pickup = widget.pickup;
      if (pickup != null) {
        await controller.addCircle(CircleOptions(
          geometry: LatLng(pickup.latitude, pickup.longitude),
          circleRadius: 11,
          circleColor: '#087F8C',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ));
      }
      if (!mounted) return;
      final dropoff = widget.dropoff;
      if (dropoff != null) {
        await controller.addCircle(CircleOptions(
          geometry: LatLng(dropoff.latitude, dropoff.longitude),
          circleRadius: 11,
          circleColor: '#E87521',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ));
      }
    }).catchError((Object _) {
      if (mounted) setState(() => _mapUnavailable = true);
    });
  }

  Future<void> _fitPoints() async {
    final controller = _controller;
    if (!_styleLoaded || controller == null) return;
    final pickup = widget.pickup;
    final dropoff = widget.dropoff;
    try {
      if (pickup != null && dropoff != null && !_samePoint(pickup, dropoff)) {
        await controller.animateCamera(
          CameraUpdate.newLatLngBounds(
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
            left: 48,
            top: 48,
            right: 48,
            bottom: 48,
          ),
          duration: const Duration(milliseconds: 350),
        );
      } else {
        final point = pickup ?? dropoff;
        if (point == null) return;
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(point.latitude, point.longitude),
            15,
          ),
          duration: const Duration(milliseconds: 350),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _mapUnavailable = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height =
        (MediaQuery.sizeOf(context).height * .42).clamp(300.0, 390.0);
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
                    child:
                        Text('Không thể khởi tạo bản đồ trên thiết bị này.'));
              }
              return MapLibreMap(
                initialCameraPosition:
                    const CameraPosition(target: _hanoi, zoom: 14),
                styleString: _configuredStyle.trim().isEmpty
                    ? MapLibreStyles.openfreemapLiberty
                    : _configuredStyle,
                myLocationEnabled: false,
                logoEnabled: true,
                // The map is inside a ListView; let it handle pan and zoom.
                gestureRecognizers: _mapGestures,
                onMapCreated: (controller) => _controller = controller,
                onStyleLoadedCallback: _onStyleLoaded,
                onMapClick: (_, position) => widget.onTap(
                  Coordinates(position.latitude, position.longitude),
                ),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 4),
      if (!_styleLoaded && !_mapUnavailable && !_setupFailed)
        const LinearProgressIndicator(semanticsLabel: 'Đang tải bản đồ'),
      if (_mapUnavailable || _setupFailed)
        const Text(
          'Không tải được bản đồ. Bạn vẫn có thể nhập tọa độ thủ công bên dưới.',
          style: TextStyle(color: Colors.deepOrange),
        ),
      Row(children: [
        Expanded(
          child: Text(
            _visibleAttribution,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton.icon(
          onPressed: _styleLoaded ? _fitPoints : null,
          icon: const Icon(Icons.zoom_out_map),
          label: const Text('Xem 2 điểm'),
        ),
      ]),
      Text(
        'Vuốt ngoài bản đồ để cuộn trang. Nếu nền bản đồ trống hoặc tải chậm, dùng tọa độ thủ công; không cần bản đồ để lấy báo giá.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}
