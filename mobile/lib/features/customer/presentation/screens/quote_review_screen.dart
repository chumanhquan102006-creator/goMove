import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/models/quote.dart';
import '../bloc/booking_cubit.dart';
import '../formatters.dart';
import 'booking_status_screen.dart';

class QuoteReviewScreen extends StatefulWidget {
  final Quote quote;
  final DateTime Function()? now;
  const QuoteReviewScreen({super.key, required this.quote, this.now});

  @override
  State<QuoteReviewScreen> createState() => _QuoteReviewScreenState();
}

class _QuoteReviewScreenState extends State<QuoteReviewScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _fareLine(BuildContext context, String label, String amount) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(child: Text(label, style: textTheme.bodyMedium)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(vnd(amount),
              textAlign: TextAlign.end, style: textTheme.bodyMedium),
        ),
      ]),
    );
  }

  String _discount(String amount) {
    if (RegExp(r'^0+(?:\.0+)?$').hasMatch(amount)) return amount;
    return amount.startsWith('-') ? amount : '-$amount';
  }

  int _remainingSeconds(DateTime now) {
    final remaining = widget.quote.expiresAt.difference(now).inMicroseconds;
    if (remaining <= 0) return 0;
    return (remaining + Duration.microsecondsPerSecond - 1) ~/
        Duration.microsecondsPerSecond;
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final now = widget.now?.call() ?? DateTime.now();
    final usable = quote.isUsableAt(now);
    final expired = !now.isBefore(quote.expiresAt);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return BlocListener<BookingCubit, BookingState>(
      listener: (context, state) {
        if (state.booking != null) {
          Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
              builder: (_) => BookingStatusScreen(booking: state.booking!)));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Xác nhận chuyến')),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      CircleAvatar(
                        backgroundColor: colors.primaryContainer,
                        foregroundColor: colors.onPrimaryContainer,
                        child: Icon(quote.vehicleType == VehicleType.motorbike
                            ? Icons.two_wheeler
                            : Icons.directions_car),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(quote.vehicleType.label,
                                style: textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text('Chuyến đi của bạn',
                                style: textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      Chip(
                          avatar: const Icon(Icons.route, size: 18),
                          label: Text(distanceLabel(quote))),
                      Chip(
                          avatar: const Icon(Icons.schedule, size: 18),
                          label: Text(durationLabel(quote))),
                    ]),
                    const Divider(height: 24),
                    Text('Tổng cước được xác nhận',
                        style: textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(vnd(quote.finalFare),
                          style: textTheme.headlineMedium?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 4),
                    Text('Giá cuối cùng do máy chủ trả về.',
                        style: textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: usable ? colors.primaryContainer : colors.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(usable ? Icons.timer_outlined : Icons.timer_off_outlined,
                      color: usable
                          ? colors.onPrimaryContainer
                          : colors.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          usable
                              ? 'Còn ${_remainingSeconds(now)} giây để xác nhận'
                              : expired
                                  ? 'Báo giá đã hết hạn'
                                  : 'Báo giá không còn hiệu lực',
                          style: textTheme.titleSmall?.copyWith(
                              color: usable
                                  ? colors.onPrimaryContainer
                                  : colors.onErrorContainer),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          usable
                              ? 'Giá có hiệu lực đến khi hết thời gian trên.'
                              : 'Quay lại để lấy báo giá mới trước khi đặt xe.',
                          style: textTheme.bodySmall?.copyWith(
                              color: usable
                                  ? colors.onPrimaryContainer
                                  : colors.onErrorContainer),
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ExpansionTile(
                title: const Text('Chi tiết giá'),
                subtitle: const Text('Các khoản do máy chủ tính toán'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _fareLine(context, 'Giá mở cửa', quote.baseFare),
                  _fareLine(context, 'Quãng đường', quote.distanceFare),
                  _fareLine(context, 'Thời gian', quote.timeFare),
                  _fareLine(context, 'Phụ phí', quote.surcharge),
                  _fareLine(context, 'Giờ cao điểm', quote.surgeAmount),
                  _fareLine(
                      context, 'Giảm giá', _discount(quote.discountAmount)),
                  _fareLine(
                      context, 'Điều chỉnh làm tròn', quote.roundingAdjustment),
                ],
              ),
            ),
          ]),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: BlocBuilder<BookingCubit, BookingState>(
              builder: (context, state) {
                final pendingSameQuote =
                    state.pending?.quotePublicId == quote.publicId;
                final pendingOtherQuote =
                    state.pending != null && !pendingSameQuote;
                final canSubmit = !state.loading &&
                    !pendingOtherQuote &&
                    (usable || pendingSameQuote);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pendingOtherQuote)
                      Text(
                          'Có yêu cầu đặt xe khác đang chờ xác minh. Hãy xử lý yêu cầu đó trước.',
                          style: TextStyle(color: colors.error)),
                    if (state.error != null)
                      Text(state.error!, style: TextStyle(color: colors.error)),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      onPressed: canSubmit
                          ? () => context
                              .read<BookingCubit>()
                              .submit(quote.publicId)
                          : null,
                      child: state.loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(pendingSameQuote
                              ? 'Kiểm tra lại yêu cầu đặt xe'
                              : 'Xác nhận đặt xe'),
                    ),
                    if (!usable) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Text('Lấy báo giá mới')),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
