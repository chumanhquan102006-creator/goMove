import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/foundation.dart'
    show Factory, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show
        EagerGestureRecognizer,
        HorizontalDragGestureRecognizer,
        OneSequenceGestureRecognizer,
        TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/theme/app_motion.dart';
import '../../../trip/domain/models/road_route.dart';
import '../../../trip/presentation/widgets/road_route_line.dart';
import '../../domain/models/quote.dart';
import '../widgets/customer_map_source.dart';
import '../widgets/customer_location_picker_overlay.dart';

/// A camera-only boundary: no controller, account identity or network client
/// escapes the canvas. The epoch is local and is never sent to tile providers.
class CustomerMapPickerBinding {
  final int epoch;
  final Coordinates? initialPoint;
  final bool pickup;
  final bool suspended;
  final double panelHeight;
  final ValueChanged<int> onMoving;
  final void Function(int revision, Coordinates point) onIdle;
  final VoidCallback onUnavailable;
  const CustomerMapPickerBinding(
      {required this.epoch,
      required this.initialPoint,
      required this.pickup,
      required this.suspended,
      required this.panelHeight,
      required this.onMoving,
      required this.onIdle,
      required this.onUnavailable});
}

/// A small seam for widget tests; production always uses [CustomerMapCanvas].
typedef CustomerMapBuilder = Widget Function(
  BuildContext context,
  Coordinates? pickup,
  Coordinates? dropoff,
  ValueChanged<Coordinates> onTap,
  CustomerMapPickerBinding? picker,
);

class CustomerMapCanvas extends StatefulWidget {
  final Coordinates? pickup;
  final Coordinates? dropoff;
  final ValueChanged<Coordinates> onTap;
  final bool fullScreen;
  final RoadRoute? route;
  final double attributionTop;
  final bool scrollablePreview;
  final CustomerMapPickerBinding? picker;

  const CustomerMapCanvas({
    super.key,
    required this.pickup,
    required this.dropoff,
    required this.onTap,
    this.fullScreen = false,
    this.route,
    this.attributionTop = 12,
    this.scrollablePreview = false,
    this.picker,
  });

  @override
  State<CustomerMapCanvas> createState() => _CustomerMapCanvasState();
}

class _CustomerMapCanvasState extends State<CustomerMapCanvas> {
  static const _hanoi = LatLng(21.0287, 105.8524);
  static final _mapGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };
  // In a vertical Quote list, let the list win vertical drags while the map
  // still accepts taps and horizontal panning. Home keeps full map gestures.
  static final _scrollPreviewGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<HorizontalDragGestureRecognizer>(
        HorizontalDragGestureRecognizer.new),
    const Factory<TapGestureRecognizer>(TapGestureRecognizer.new),
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
  final _creditKey = GlobalKey();
  final _moving = ValueNotifier<bool>(false);
  CameraPosition? _cameraBeforePicker;
  Size _mapSize = Size.zero;
  double _creditHeight = 0;
  EdgeInsets _insets = EdgeInsets.zero;
  int _cameraRevision = 0;
  int _commandRevision = 0;
  bool _layoutPending = false;
  bool _configuring = false;
  bool _idleDuringCommand = false;
  bool _positioning = false;
  bool _waitingForIdle = false;
  bool _pickerCameraActive = false;
  int? _positionedEpoch;
  Timer? _cameraTimeout;
  Future<void> _cameraCommands = Future<void>.value();

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
          final picker = widget.picker;
          if (picker != null) _pickerUnavailable(picker.epoch);
        }
      });
      return true;
    } catch (_) {
      if (mounted) setState(() => _setupFailed = true);
      final picker = widget.picker;
      if (mounted && picker != null) _pickerUnavailable(picker.epoch);
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant CustomerMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePoint(widget.pickup, oldWidget.pickup) ||
        !_samePoint(widget.dropoff, oldWidget.dropoff) ||
        (widget.picker == null) != (oldWidget.picker == null) ||
        widget.picker?.pickup != oldWidget.picker?.pickup) {
      _markerDebounce?.cancel();
      _markerDebounce =
          Timer(const Duration(milliseconds: 180), _queueMarkerSync);
    }
    if (!identical(widget.route, oldWidget.route) ||
        !_samePoint(widget.pickup, oldWidget.pickup) ||
        !_samePoint(widget.dropoff, oldWidget.dropoff)) {
      _queueRouteSync();
    }
    if (widget.picker?.epoch != oldWidget.picker?.epoch ||
        widget.picker?.suspended != oldWidget.picker?.suspended ||
        widget.picker?.panelHeight != oldWidget.picker?.panelHeight) {
      _queuePickerCamera();
    }
  }

  double? _deviceScale;
  EdgeInsets? _safeArea;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    if (_deviceScale != media.devicePixelRatio || _safeArea != media.padding) {
      _deviceScale = media.devicePixelRatio;
      _safeArea = media.padding;
      if (widget.picker != null) _queuePickerCamera();
    }
  }

  static bool _samePoint(Coordinates? a, Coordinates? b) =>
      a?.latitude == b?.latitude && a?.longitude == b?.longitude;

  @override
  void dispose() {
    _styleTimeout?.cancel();
    _markerDebounce?.cancel();
    _cameraTimeout?.cancel();
    _commandRevision++;
    _controller?.removeListener(_onCameraStatus);
    _moving.dispose();
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
    _queuePickerCamera();
  }

  bool _pickerCurrent(int epoch, int revision) =>
      mounted &&
      widget.picker?.epoch == epoch &&
      widget.picker?.suspended == false &&
      _styleLoaded &&
      !_mapUnavailable &&
      revision == _cameraRevision;

  void _onMapCreated(MapLibreMapController controller) {
    if (!mounted) return;
    _controller?.removeListener(_onCameraStatus);
    _controller = controller;
    controller.addListener(_onCameraStatus);
  }

  void _onCameraStatus() {
    if (_controller?.isCameraMoving == true) _onCameraMoving();
  }

  void _onCameraMoving() {
    if (!mounted) return;
    final picker = widget.picker;
    if (picker == null ||
        picker.suspended ||
        !_styleLoaded ||
        _mapUnavailable) {
      return;
    }
    if (_moving.value) return;
    _moving.value = true;
    picker.onMoving(++_cameraRevision);
  }

  void _onCameraIdle() {
    if (!mounted) return;
    if (_configuring) {
      _idleDuringCommand = true;
      return;
    }
    final picker = widget.picker;
    if (picker == null || picker.suspended) return;
    if (_positioning && !_waitingForIdle) return;
    _moving.value = false;
    unawaited(_readPinLocation(picker.epoch, _cameraRevision));
  }

  Future<void> _readPinLocation(int epoch, int revision) async {
    final controller = _controller;
    if (controller == null ||
        !_pickerCurrent(epoch, revision) ||
        controller.isCameraMoving ||
        _mapSize.isEmpty) {
      return;
    }
    final pin = _pinOffset;
    if (pin == null) {
      _pickerUnavailable(epoch);
      return;
    }
    try {
      final camera = await controller
          .queryCameraPosition()
          .timeout(const Duration(seconds: 3));
      if (!mounted ||
          !_pickerCurrent(epoch, revision) ||
          controller.isCameraMoving) {
        return;
      }
      if (camera == null ||
          !camera.zoom.isFinite ||
          !camera.bearing.isFinite ||
          !camera.tilt.isFinite ||
          !Coordinates(camera.target.latitude, camera.target.longitude)
              .isValid) {
        _pickerUnavailable(epoch);
        return;
      }
      // 0.27.1 Android passes x/y straight to native Projection (physical px).
      // iOS uses UIKit points; web uses CSS pixels. Padding itself is logical.
      final scale = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? MediaQuery.devicePixelRatioOf(context)
          : 1.0;
      final location = await controller
          .toLatLng(Point<double>(pin.dx * scale, pin.dy * scale))
          .timeout(const Duration(seconds: 3));
      if (!_pickerCurrent(epoch, revision) || controller.isCameraMoving) return;
      final point = Coordinates(location.latitude, location.longitude);
      if (!point.isValid) {
        _pickerUnavailable(epoch);
        return;
      }
      _cameraTimeout?.cancel();
      if (_positioning) setState(() => _positioning = false);
      widget.picker!.onIdle(revision, point);
    } catch (_) {
      if (_pickerCurrent(epoch, revision)) _pickerUnavailable(epoch);
    }
  }

  Offset? get _pinOffset {
    final width = _mapSize.width - _insets.horizontal;
    final height = _mapSize.height - _insets.vertical;
    if (width <= 0 || height < 48) return null;
    return Offset(_insets.left + width / 2, _insets.top + height / 2);
  }

  void _pickerUnavailable(int epoch) {
    if (!mounted || widget.picker?.epoch != epoch || widget.picker!.suspended) {
      return;
    }
    _cameraTimeout?.cancel();
    if (_positioning) setState(() => _positioning = false);
    widget.picker?.onUnavailable();
  }

  void _measureViewport() {
    if (_layoutPending) return;
    _layoutPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutPending = false;
      if (!mounted) return;
      final credit = _creditKey.currentContext?.findRenderObject();
      final height =
          credit is RenderBox && credit.hasSize ? credit.size.height : 0.0;
      if (height != _creditHeight) {
        _creditHeight = height;
        _queuePickerCamera();
      }
    });
  }

  void _queuePickerCamera() {
    final command = ++_commandRevision;
    _cameraRevision++;
    _cameraTimeout?.cancel();
    _waitingForIdle = false;
    final picker = widget.picker;
    if (picker != null && picker.suspended) return;
    if (picker == null && !_pickerCameraActive) return;
    if (!_styleLoaded || _controller == null) {
      if (picker != null && (_setupFailed || _mapUnavailable)) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _pickerUnavailable(picker.epoch));
      }
      return;
    }
    if (picker != null) {
      _pickerCameraActive = true;
      final safe = MediaQuery.paddingOf(context);
      _insets = EdgeInsets.fromLTRB(
          safe.left,
          widget.attributionTop + _creditHeight + 12,
          safe.right,
          picker.panelHeight + 12);
      picker.onMoving(_cameraRevision);
      _cameraTimeout = Timer(
          const Duration(seconds: 5), () => _pickerUnavailable(picker.epoch));
      _positioning = true;
    } else {
      _insets = EdgeInsets.zero;
      _positioning = true;
      _positionedEpoch = null;
    }
    // Run after layout and serialize platform commands. Obsolete queued work
    // cannot move a newer picker or restore a camera after another entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || command != _commandRevision) return;
      setState(() {});
      _cameraCommands = _cameraCommands.then((_) async {
        if (!mounted || command != _commandRevision) return;
        final controller = _controller!;
        _configuring = true;
        _idleDuringCommand = false;
        try {
          if (picker != null && _cameraBeforePicker == null) {
            final before = await controller
                .queryCameraPosition()
                .timeout(const Duration(seconds: 3));
            if (!mounted || command != _commandRevision) return;
            _cameraBeforePicker = before;
          }
          if (!mounted || command != _commandRevision) return;
          await controller
              .setPadding(
                  left: _insets.left,
                  top: _insets.top,
                  right: _insets.right,
                  bottom: _insets.bottom)
              .timeout(const Duration(seconds: 3));
          if (!mounted || command != _commandRevision) return;
          if (picker == null) {
            final before = _cameraBeforePicker;
            _cameraBeforePicker = null;
            if (before != null) {
              await controller
                  .moveCamera(CameraUpdate.newCameraPosition(before))
                  .timeout(const Duration(seconds: 3));
            }
          } else if (_positionedEpoch != picker.epoch) {
            final seed = picker.initialPoint;
            _idleDuringCommand = false;
            if (seed?.isValid == true) {
              final update = CameraUpdate.newLatLngZoom(
                  LatLng(seed!.latitude, seed.longitude), 16);
              if (AppMotion.reduceMotion(context)) {
                await controller.moveCamera(update);
              } else {
                await controller.animateCamera(update,
                    duration: AppMotion.pageEnter);
              }
            } else if (_cameraBeforePicker != null) {
              await controller.moveCamera(
                  CameraUpdate.newCameraPosition(_cameraBeforePicker!));
            }
            _positionedEpoch = picker.epoch;
          }
        } finally {
          _configuring = false;
        }
        if (!mounted || command != _commandRevision) return;
        if (picker == null) {
          _pickerCameraActive = false;
          setState(() => _positioning = false);
        }
        _waitingForIdle = true;
        // A platform idle event, never the animation Future, authorizes sampling.
        if (_idleDuringCommand) _onCameraIdle();
      }).catchError((Object _) {
        _configuring = false;
        if (mounted && command == _commandRevision && picker != null) {
          _pickerUnavailable(picker.epoch);
        } else if (mounted && command == _commandRevision) {
          setState(() => _positioning = false);
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
      if (pickup != null && widget.picker?.pickup != true) {
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
      if (dropoff != null && (widget.picker == null || widget.picker!.pickup)) {
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
          return LayoutBuilder(builder: (context, constraints) {
            final size = constraints.biggest;
            if (_mapSize != size) {
              _mapSize = size;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && widget.picker != null) _queuePickerCamera();
              });
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
                  logoViewMargins: widget.picker == null
                      ? null
                      : Point(12.0, widget.picker!.panelHeight + 12),
                  attributionButtonMargins: widget.picker == null
                      ? null
                      : Point(12.0, widget.picker!.panelHeight + 12),
                  trackCameraPosition: !widget.scrollablePreview,
                  annotationOrder: const [
                    AnnotationType.line,
                    AnnotationType.circle
                  ],
                  gestureRecognizers: widget.scrollablePreview
                      ? _scrollPreviewGestures
                      : _mapGestures,
                  onMapCreated: _onMapCreated,
                  onStyleLoadedCallback: _onStyleLoaded,
                  onCameraMove: (_) => _onCameraMoving(),
                  onCameraIdle: _onCameraIdle,
                  onMapClick: (_, position) {
                    if (!_styleLoaded ||
                        _mapUnavailable ||
                        widget.picker != null) {
                      return;
                    }
                    widget.onTap(
                      Coordinates(position.latitude, position.longitude),
                    );
                  },
                ),
                if (widget.picker != null && _pinOffset != null)
                  Positioned(
                      left: _pinOffset!.dx - 20,
                      top: _pinOffset!.dy - 48,
                      child: ValueListenableBuilder<bool>(
                          valueListenable: _moving,
                          builder: (_, moving, __) => CustomerLocationPin(
                              key: const ValueKey('location-picker-pin'),
                              pickup: widget.picker!.pickup,
                              moving: moving))),
                if (_positioning || widget.picker?.suspended == true)
                  const Positioned.fill(
                      child: AbsorbPointer(child: SizedBox.expand())),
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
          });
        },
      );

  @override
  Widget build(BuildContext context) {
    if (widget.fullScreen) {
      final scheme = Theme.of(context).colorScheme;
      _measureViewport();
      return Stack(fit: StackFit.expand, children: [
        _mapSurface(),
        if (widget.picker == null)
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
          top: widget.attributionTop,
          left: 12,
          right: 76,
          child: DecoratedBox(
            key: _creditKey,
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
