import 'dart:async';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/theme/app_motion.dart';
import '../../../trip/domain/models/road_route.dart';
import '../../../trip/presentation/widgets/road_route_line.dart';
import '../../domain/models/quote.dart';
import '../widgets/customer_map_source.dart';

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
  final bool fullScreen;
  final RoadRoute? route;

  const CustomerMapCanvas({
    super.key,
    required this.pickup,
    required this.dropoff,
    required this.onTap,
    this.fullScreen = false,
    this.route,
  });

  @override
  State<CustomerMapCanvas> createState() => _CustomerMapCanvasState();
}

class _CustomerMapCanvasState extends State<CustomerMapCanvas> {
  static const _hanoi = LatLng(21.0287, 105.8524);
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  MapLibreMapController? _controller;
  Timer? _styleTimeout;
  Timer? _markerDebounce;
  late final Future<bool> _mapReady;
  Future<void> _markerSync = Future<void>.value();
  Future<void> _routeSync = Future<void>.value();
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _setupFailed = false;
  bool _markerUpdateFailed = false;
  bool _cameraUpdateFailed = false;
  bool _routeUpdateFailed = false;

  @override
  void initState() {
    super.initState();
    _mapReady = _configureMapRequests();
  }

  Future<bool> _configureMapRequests() async {
    try {
      // Identify native tile requests before creating the map. Never send
      // JWTs, account IDs or Booking IDs to an external tile provider.
      await CustomerMapSource.configureRequests();
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
    if (!identical(widget.route, oldWidget.route) ||
        !_samePoint(widget.pickup, oldWidget.pickup) ||
        !_samePoint(widget.dropoff, oldWidget.dropoff)) {
      _queueRouteSync();
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
      _markerUpdateFailed = false;
      _cameraUpdateFailed = false;
      _routeUpdateFailed = false;
    });
    _markerDebounce?.cancel();
    _queueMarkerSync();
    _queueRouteSync();
  }

  void _queueRouteSync() {
    _routeSync = _routeSync.then((_) async {
      final controller = _controller;
      if (!mounted || !_styleLoaded || controller == null) return;
      await controller.clearLines();
      if (!mounted) return;
      final pickup = widget.pickup;
      final dropoff = widget.dropoff;
      final route = widget.route;
      if (pickup != null &&
          dropoff != null &&
          route != null &&
          route.matchesEndpoints(pickup, dropoff)) {
        final line = RoadRouteLine.options(route);
        if (line != null) await controller.addLine(line);
      }
      if (mounted && _routeUpdateFailed) {
        setState(() => _routeUpdateFailed = false);
      }
    }).catchError((Object _) {
      if (mounted) setState(() => _routeUpdateFailed = true);
    });
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
          // An outlined ring distinguishes pickup from the filled destination.
          circleRadius: 12,
          circleColor: '#FFFFFF',
          circleStrokeColor: '#0066FF',
          circleStrokeWidth: 4,
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
      if (mounted && _markerUpdateFailed) {
        setState(() => _markerUpdateFailed = false);
      }
    }).catchError((Object _) {
      // A failed annotation update does not mean the basemap is unavailable.
      if (mounted) setState(() => _markerUpdateFailed = true);
    });
  }

  Future<void> _fitPoints() async {
    final controller = _controller;
    if (!_styleLoaded || controller == null) return;
    final pickup = widget.pickup;
    final dropoff = widget.dropoff;
    final renderObject = context.findRenderObject();
    final mapHeight = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.size.height
        : MediaQuery.sizeOf(context).height;
    final maxBottomInset = mapHeight > 160 ? mapHeight - 160 : 0.0;
    final bottomInset = widget.fullScreen
        ? (mapHeight * .46).clamp(0.0, maxBottomInset).toDouble()
        : 48.0;
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
            bottom: bottomInset,
          ),
          duration:
              AppMotion.duration(context, const Duration(milliseconds: 350)),
        );
      } else {
        final point = pickup ?? dropoff;
        if (point == null) return;
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(point.latitude, point.longitude),
            15,
          ),
          duration:
              AppMotion.duration(context, const Duration(milliseconds: 350)),
        );
      }
      if (mounted && _cameraUpdateFailed) {
        setState(() => _cameraUpdateFailed = false);
      }
    } catch (_) {
      // Keep a working basemap usable when only the camera command fails.
      if (mounted) setState(() => _cameraUpdateFailed = true);
    }
  }

  Widget _mapSurface() => FutureBuilder<bool>(
        future: _mapReady,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data != true) {
            return const Center(
                child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Không thể khởi tạo bản đồ trên thiết bị này.',
                  textAlign: TextAlign.center),
            ));
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              MapLibreMap(
                initialCameraPosition:
                    const CameraPosition(target: _hanoi, zoom: 14),
                styleString: CustomerMapSource.styleUrl,
                myLocationEnabled: false,
                logoEnabled: true,
                annotationOrder: const [
                  AnnotationType.line,
                  AnnotationType.circle
                ],
                gestureRecognizers: _mapGestures,
                onMapCreated: (controller) => _controller = controller,
                onStyleLoadedCallback: _onStyleLoaded,
                onMapClick: (_, position) {
                  if (!_styleLoaded || _mapUnavailable) return;
                  widget.onTap(
                    Coordinates(position.latitude, position.longitude),
                  );
                },
              ),
              if (_mapUnavailable)
                const AbsorbPointer(
                  child: ColoredBox(
                    color: Color(0xDDF8F9FA),
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Nền bản đồ tạm thời không tải được.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    if (widget.fullScreen) {
      final scheme = Theme.of(context).colorScheme;
      return Stack(fit: StackFit.expand, children: [
        _mapSurface(),
        Positioned(
          top: 12,
          right: 12,
          child: FloatingActionButton.small(
            heroTag: 'customer-fit-points',
            tooltip: 'Xem 2 điểm',
            onPressed: _styleLoaded && !_mapUnavailable ? _fitPoints : null,
            backgroundColor: scheme.surface,
            foregroundColor: scheme.primary,
            child: const Icon(Icons.zoom_out_map),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 76,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withAlpha(238),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                CustomerMapSource.visibleAttribution,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ),
        if (_mapUnavailable ||
            _setupFailed ||
            _markerUpdateFailed ||
            _routeUpdateFailed ||
            _cameraUpdateFailed)
          Positioned(
            top: 76,
            left: 12,
            right: 12,
            child: Material(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  _mapUnavailable || _setupFailed
                      ? 'Không tải được bản đồ. Bạn vẫn có thể nhập tọa độ thủ công trong bảng đặt xe.'
                      : _markerUpdateFailed
                          ? 'Không thể cập nhật điểm trên bản đồ. Hãy kiểm tra tọa độ trong bảng đặt xe.'
                          : _routeUpdateFailed
                              ? 'Không thể vẽ tuyến đường; bạn vẫn có thể xem hai điểm và báo giá.'
                              : 'Không thể điều chỉnh góc nhìn bản đồ. Có thể chọn điểm hoặc nhập tọa độ thủ công.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ),
          ),
      ]);
    }
    final media = MediaQuery.of(context);
    // Scaffold removes viewInsets from its body MediaQuery; read the view's
    // original inset so the map still contracts when the keyboard appears.
    final keyboardInset =
        View.of(context).viewInsets.bottom / View.of(context).devicePixelRatio;
    final keyboardOpen = keyboardInset > 0;
    final height = keyboardOpen
        ? ((media.size.height - keyboardInset) * .36).clamp(170.0, 220.0)
        : (media.size.height * .40).clamp(240.0, 360.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: height,
          child: _mapSurface(),
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
      if (_markerUpdateFailed || _routeUpdateFailed || _cameraUpdateFailed)
        Text(
          _markerUpdateFailed
              ? 'Không thể cập nhật điểm trên bản đồ. Hãy thử lại hoặc nhập tọa độ thủ công.'
              : _routeUpdateFailed
                  ? 'Không thể vẽ tuyến đường; hai điểm và báo giá vẫn dùng được.'
                  : 'Không thể điều chỉnh góc nhìn bản đồ. Bạn vẫn có thể chạm bản đồ hoặc nhập tọa độ thủ công.',
          style: const TextStyle(color: Colors.deepOrange),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _styleLoaded && !_mapUnavailable ? _fitPoints : null,
          icon: const Icon(Icons.zoom_out_map),
          label: const Text('Xem 2 điểm'),
        ),
      ),
      Text(CustomerMapSource.visibleAttribution,
          style: Theme.of(context).textTheme.bodySmall),
      Text(
        'Vuốt ngoài bản đồ để cuộn trang. Nếu nền bản đồ trống hoặc tải chậm, dùng tọa độ thủ công; không cần bản đồ để lấy báo giá.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}
