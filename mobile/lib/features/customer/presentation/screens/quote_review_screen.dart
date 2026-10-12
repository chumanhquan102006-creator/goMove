import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/models/quote.dart';
import '../bloc/booking_cubit.dart';
import '../formatters.dart';
import 'booking_status_screen.dart';

class QuoteReviewScreen extends StatefulWidget {
  final Quote quote;
  const QuoteReviewScreen({super.key, required this.quote});

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

  Widget _line(String label, String amount) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label),
          Text(vnd(amount)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final seconds = quote.expiresAt.difference(DateTime.now()).inSeconds;
    final usable = quote.isUsableAt(DateTime.now());
    return BlocListener<BookingCubit, BookingState>(
      listener: (context, state) {
        if (state.booking != null) {
          Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
              builder: (_) => BookingStatusScreen(booking: state.booking!)));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Xem báo giá')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(quote.vehicleType.label,
              style: Theme.of(context).textTheme.titleLarge),
          Text(
              '${distanceLabel(quote)} · ${durationLabel(quote)} · ${quote.currency}'),
          const SizedBox(height: 18),
          _line('Giá mở cửa', quote.baseFare),
          _line('Quãng đường', quote.distanceFare),
          _line('Thời gian', quote.timeFare),
          _line('Phụ phí', quote.surcharge),
          _line('Giờ cao điểm', quote.surgeAmount),
          _line('Giảm giá', '-${quote.discountAmount}'),
          _line('Điều chỉnh làm tròn', quote.roundingAdjustment),
          const Divider(),
          ListTile(
              title: const Text('Tổng tiền theo máy chủ',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: Text(vnd(quote.finalFare),
                  style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 12),
          Text(
              usable
                  ? 'Còn ${seconds < 0 ? 0 : seconds} giây để xác nhận'
                  : 'Báo giá đã hết hạn.',
              style: TextStyle(
                  color: usable ? Colors.green.shade700 : Colors.red)),
          Text('Hết hạn lúc ${quote.expiresAt.toLocal()}'),
          const SizedBox(height: 16),
          BlocBuilder<BookingCubit, BookingState>(builder: (context, state) {
            final existing = state.pending?.quotePublicId == quote.publicId;
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                      onPressed: state.loading || (!usable && !existing)
                          ? null
                          : () => context
                              .read<BookingCubit>()
                              .submit(quote.publicId),
                      child: state.loading
                          ? const CircularProgressIndicator()
                          : Text(existing
                              ? 'Thử lại Booking với key cũ'
                              : 'Xác nhận đặt xe')),
                  if (state.error != null)
                    Text(state.error!,
                        style: const TextStyle(color: Colors.red)),
                  if (!usable)
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Lấy báo giá mới')),
                ]);
          }),
        ]),
      ),
    );
  }
}
