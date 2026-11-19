import 'dart:math' show min, max;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_motion.dart';
import '../bloc/location_picker_cubit.dart';

/// Flutter-only panel. Its measured height includes SafeArea and outer spacing;
/// the map uses that exact occlusion to position its fixed pin.
class CustomerLocationPickerOverlay extends StatefulWidget {
  final LocationPickerCubit picker;
  final ValueChanged<double> onPanelHeight;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const CustomerLocationPickerOverlay(
      {super.key,
      required this.picker,
      required this.onPanelHeight,
      required this.onConfirm,
      required this.onCancel});

  @override
  State<CustomerLocationPickerOverlay> createState() => _PickerOverlayState();
}

class _PickerOverlayState extends State<CustomerLocationPickerOverlay> {
  final _panel = GlobalKey();
  bool _measurementPending = false;
  double? _lastHeight;

  void _measure() {
    if (_measurementPending) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      if (!mounted) return;
      final box = _panel.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      if (_lastHeight == box.size.height) return;
      _lastHeight = box.size.height;
      widget.onPanelHeight(box.size.height);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        _measure();
        // Stable panel geometry prevents a reverse result changing the viewport
        // and starting another lookup. Larger text scrolls inside this panel.
        final height = min(
            MediaQuery.textScalerOf(context).scale(272),
            max(0.0,
                size.maxHeight - MediaQuery.paddingOf(context).bottom - 160));
        return Align(
          alignment: Alignment.bottomCenter,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _measure();
              return false;
            },
            child: SizeChangedLayoutNotifier(
              child: SizedBox(
                key: _panel,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: 560, minHeight: height, maxHeight: height),
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        elevation: 2,
                        borderRadius: BorderRadius.circular(24),
                        clipBehavior: Clip.antiAlias,
                        child: BlocBuilder<LocationPickerCubit,
                            LocationPickerState>(
                          bloc: widget.picker,
                          builder: (context, state) {
                            _measure();
                            final pickup =
                                state.target == LocationPickerTarget.pickup;
                            final title = pickup
                                ? 'Điểm đón của bạn'
                                : 'Điểm đến của bạn';
                            final pending = state.phase ==
                                    LocationPickerPhase.authorizing ||
                                state.phase == LocationPickerPhase.locating ||
                                state.phase == LocationPickerPhase.confirming;
                            final status = switch (state.phase) {
                              LocationPickerPhase.authorizing =>
                                'Đang xác minh phiên đăng nhập…',
                              LocationPickerPhase.locating =>
                                'Đang định vị ghim trên bản đồ…',
                              LocationPickerPhase.moving =>
                                'Kéo bản đồ đến vị trí mong muốn',
                              LocationPickerPhase.suspended =>
                                'Chờ ứng dụng hoạt động trở lại',
                              LocationPickerPhase.confirming =>
                                'Đang xác nhận vị trí…',
                              _ => state.lookingUp
                                  ? 'Đang tìm địa chỉ…'
                                  : state.message ??
                                      'Vị trí nằm tại đầu ghim trên bản đồ',
                            };
                            if (height < 180) {
                              return SingleChildScrollView(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(state.address?.label ?? title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                      FilledButton(
                                          key: const ValueKey('picker-confirm'),
                                          onPressed: state.canConfirm
                                              ? widget.onConfirm
                                              : null,
                                          child: Text(pickup
                                              ? 'Xác nhận điểm đón'
                                              : 'Xác nhận điểm đến')),
                                      TextButton(
                                          key: const ValueKey('picker-cancel'),
                                          onPressed: widget.onCancel,
                                          child: const Text('Hủy chọn vị trí')),
                                    ]),
                              );
                            }
                            return Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 16, 20, 12),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Expanded(
                                        child: SingleChildScrollView(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(title,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelLarge),
                                            const SizedBox(height: 8),
                                            Text(
                                                state.address?.label ??
                                                    'Vị trí đang chọn',
                                                key: const ValueKey(
                                                    'picker-preview-address'),
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium),
                                            if (state.point != null) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                  '${state.point!.latitude.toStringAsFixed(6)}, ${state.point!.longitude.toStringAsFixed(6)}',
                                                  key: const ValueKey(
                                                      'picker-preview-coordinate'),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall),
                                            ],
                                            const SizedBox(height: 8),
                                            Semantics(
                                                liveRegion: state.phase !=
                                                    LocationPickerPhase.moving,
                                                child: Text(status,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall)),
                                            if (state.address?.attribution !=
                                                null)
                                              Text(state.address!.attribution!,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .labelSmall),
                                          ]),
                                    )),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                        width: double.infinity,
                                        child: FilledButton(
                                          key: const ValueKey('picker-confirm'),
                                          onPressed: state.canConfirm
                                              ? widget.onConfirm
                                              : null,
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 12),
                                              child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    if (pending) ...[
                                                      const SizedBox(
                                                          width: 16,
                                                          height: 16,
                                                          child:
                                                              CircularProgressIndicator(
                                                                  strokeWidth:
                                                                      2)),
                                                      const SizedBox(width: 8),
                                                    ],
                                                    Flexible(
                                                        child: Text(
                                                            pickup
                                                                ? 'Xác nhận điểm đón'
                                                                : 'Xác nhận điểm đến',
                                                            textAlign: TextAlign
                                                                .center)),
                                                  ])),
                                        )),
                                    TextButton(
                                        key: const ValueKey('picker-cancel'),
                                        onPressed: widget.onCancel,
                                        child: const Text('Hủy chọn vị trí')),
                                  ]),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      });
}

class CustomerLocationPin extends StatelessWidget {
  final bool pickup;
  final bool moving;
  const CustomerLocationPin(
      {super.key, required this.pickup, required this.moving});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Semantics(
            image: true,
            label: pickup ? 'Ghim điểm đón' : 'Ghim điểm đến',
            child: AnimatedSlide(
              offset: moving && !AppMotion.reduceMotion(context)
                  ? const Offset(0, -.10)
                  : Offset.zero,
              duration: AppMotion.duration(context, AppMotion.touch),
              curve: AppMotion.standardCurve,
              child: SizedBox(
                  width: 40,
                  height: 48,
                  child: CustomPaint(
                      painter:
                          _PinPainter(Theme.of(context).colorScheme.primary))),
            )),
      );
}

class _PinPainter extends CustomPainter {
  final Color color;
  const _PinPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    // The visible tip is exactly (20, 48), the map's projected sample point.
    final shape = Path()
      ..moveTo(20, 48)
      ..cubicTo(14, 34, 2, 29, 2, 19)
      ..arcToPoint(const Offset(38, 19), radius: const Radius.circular(18))
      ..cubicTo(38, 29, 26, 34, 20, 48)
      ..close();
    canvas.drawPath(shape, Paint()..color = color);
    canvas.drawCircle(const Offset(20, 19), 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PinPainter oldDelegate) => oldDelegate.color != color;
}
