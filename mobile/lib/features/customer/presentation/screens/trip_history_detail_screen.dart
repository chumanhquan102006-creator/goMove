import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../review/domain/rating_repository.dart';
import '../../../review/presentation/rating_panel.dart';
import '../../domain/models/quote.dart';
import '../bloc/trip_history_detail_cubit.dart';
import 'trip_history_screen.dart';
import '../widgets/customer_premium_widgets.dart';

class TripHistoryDetailScreen extends StatefulWidget {
  final String customerPublicId;
  final String bookingPublicId;
  const TripHistoryDetailScreen(
      {super.key,
      required this.customerPublicId,
      required this.bookingPublicId});

  @override
  State<TripHistoryDetailScreen> createState() =>
      _TripHistoryDetailScreenState();
}

class _TripHistoryDetailScreenState extends State<TripHistoryDetailScreen>
    with WidgetsBindingObserver {
  late final TripHistoryDetailCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = sl<TripHistoryDetailCubit>(
        param1: widget.bookingPublicId, param2: widget.customerPublicId)
      ..load();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.load();
    } else {
      _cubit.hideForBackground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cubit.close();
    super.dispose();
  }

  Widget _line(String title, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value),
        ]),
      );

  @override
  Widget build(BuildContext context) => BlocProvider.value(
        value: _cubit,
        child: BlocConsumer<AuthBloc, AuthState>(listener: (context, auth) {
          if (auth is! AuthenticatedState ||
              auth.user.publicId != widget.customerPublicId) {
            _cubit.invalidateSession();
          }
        }, builder: (context, auth) {
          if (auth is! AuthenticatedState ||
              auth.user.publicId != widget.customerPublicId) {
            return const Scaffold(
                body: Center(child: Text('Phiên đăng nhập đã thay đổi.')));
          }
          return Scaffold(
            appBar: AppBar(title: const Text('Chi tiết chuyến')),
            body: BlocBuilder<TripHistoryDetailCubit, TripHistoryDetailState>(
              builder: (context, state) {
                if (state.sessionEnded) {
                  return const Center(
                      child: Text('Phiên đăng nhập đã thay đổi.'));
                }
                if (state.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (state.booking == null) {
                  return Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(state.error ?? 'Chưa có chi tiết chuyến.'),
                    TextButton(
                        onPressed: _cubit.load, child: const Text('Thử lại')),
                  ]));
                }
                final booking = state.booking!;
                final pickup = booking.pickup!;
                final dropoff = booking.dropoff!;
                final payment = state.payment;
                return RefreshIndicator(
                  onRefresh: _cubit.load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      CustomerPremiumSurface(
                        highlighted: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.verified_rounded,
                                color: AppColors.success, size: 34),
                            const SizedBox(height: 8),
                            Text('Chuyến đi đã hoàn thành',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text(
                                historyMoney(
                                    booking.finalFare, booking.currency),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(historyDate(booking.tripCompletedAt!),
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                          child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Hành trình',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              _line('Đặt lúc', historyDate(booking.createdAt)),
                              _line('Hoàn thành lúc',
                                  historyDate(booking.tripCompletedAt!)),
                              const SizedBox(height: 12),
                              CustomerJourneyTimeline(
                                pickup: state.pickupAddress?.label ??
                                    historyPoint(pickup),
                                dropoff: state.dropoffAddress?.label ??
                                    historyPoint(dropoff),
                              ),
                              if (state.pickupAddress != null ||
                                  state.dropoffAddress != null)
                                Text(
                                    state.pickupAddress?.attribution ??
                                        state.dropoffAddress?.attribution ??
                                        '© OpenStreetMap contributors',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              _line('Loại xe', booking.vehicleType.label),
                              if (booking.distanceMeters != null)
                                _line('Quãng đường',
                                    '${booking.distanceMeters} m'),
                              if (booking.durationSeconds != null)
                                _line('Thời gian hành trình',
                                    '${booking.durationSeconds} giây'),
                              _line(
                                  'Giá cuối cùng',
                                  historyMoney(
                                      booking.finalFare, booking.currency)),
                              _line('Trạng thái', 'Đã hoàn thành'),
                            ]),
                      )),
                      if (booking.isCompleted &&
                          sl.isRegistered<RatingRepository>())
                        RatingPanel(
                          key: ValueKey('history-rating-${booking.publicId}'),
                          bookingPublicId: booking.publicId,
                          customerPublicId: widget.customerPublicId,
                        ),
                      const SizedBox(height: 12),
                      if (payment?.isPaid == true)
                        Card(
                            child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Biên nhận thanh toán',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                const Text(
                                    'Đây là biên nhận trong ứng dụng, không phải hóa đơn thuế.'),
                                _line('Phương thức', 'Tiền mặt'),
                                _line(
                                    'Số tiền',
                                    historyMoney(
                                        payment!.amount, payment.currency)),
                                _line('Trạng thái', 'Đã thanh toán'),
                                _line('Thanh toán lúc',
                                    historyDate(payment.paidAt!)),
                              ]),
                        ))
                      else if (payment?.status == 'PENDING')
                        Card(
                            child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Chờ xác nhận thanh toán',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                _line('Phương thức', 'Tiền mặt'),
                                _line(
                                    'Số tiền',
                                    historyMoney(
                                        payment!.amount, payment.currency)),
                                const Text(
                                    'Chưa có biên nhận thanh toán hoàn tất.'),
                              ]),
                        ))
                      else
                        Card(
                            child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(children: [
                            Text(state.paymentError ??
                                'Chưa xác minh được thanh toán.'),
                            TextButton(
                                onPressed: _cubit.load,
                                child: const Text('Thử lại')),
                          ]),
                        )),
                      ExpansionTile(
                        title: const Text('Mã tham chiếu hỗ trợ'),
                        children: [
                          _line('Mã chuyến', booking.publicId),
                          if (payment != null)
                            _line('Mã thanh toán', payment.paymentPublicId),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        }),
      );
}
