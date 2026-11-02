import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../domain/models/quote.dart';
import '../bloc/trip_history_cubit.dart';
import '../formatters.dart';
import 'trip_history_detail_screen.dart';
import '../widgets/customer_premium_widgets.dart';

String historyDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

String historyPoint(Coordinates point) =>
    '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';

String historyMoney(String amount, String currency) =>
    currency == 'VND' ? vnd(amount) : '$amount $currency';

String historyPaymentLabel(String? status) => switch (status) {
      'PAID' => 'Đã thanh toán',
      'PENDING' => 'Chờ thanh toán',
      _ => 'Chưa xác minh thanh toán',
    };

class TripHistoryScreen extends StatefulWidget {
  final String customerPublicId;
  const TripHistoryScreen({super.key, required this.customerPublicId});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen>
    with WidgetsBindingObserver {
  late final TripHistoryCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = sl<TripHistoryCubit>(param1: widget.customerPublicId)..load();
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

  bool get _sameAccount {
    final auth = context.read<AuthBloc>().state;
    return auth is AuthenticatedState &&
        auth.user.publicId == widget.customerPublicId;
  }

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
            appBar: AppBar(title: const Text('Lịch sử chuyến đi')),
            body: BlocBuilder<TripHistoryCubit, TripHistoryState>(
              builder: (context, state) {
                if (state.sessionEnded) {
                  return const Center(
                      child: Text('Phiên đăng nhập đã thay đổi.'));
                }
                if (state.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (state.error != null && state.items.isEmpty) {
                  return Center(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(state.error!, textAlign: TextAlign.center),
                      TextButton(
                          onPressed: _cubit.load, child: const Text('Thử lại')),
                    ],
                  ));
                }
                return RefreshIndicator(
                  onRefresh: _cubit.load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: state.items.isEmpty ? 1 : state.items.length + 1,
                    itemBuilder: (context, index) {
                      if (state.items.isEmpty) {
                        return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 80),
                            child: Center(
                                child: Text('Chưa có chuyến hoàn thành.')));
                      }
                      if (index == state.items.length) {
                        if (!state.hasNext && state.error == null) {
                          return const SizedBox(height: 24);
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: state.loadingMore
                                ? const CircularProgressIndicator()
                                : TextButton(
                                    onPressed: _cubit.more,
                                    child: Text(state.error == null
                                        ? 'Tải thêm chuyến'
                                        : 'Tải lại trang tiếp theo')),
                          ),
                        );
                      }
                      final item = state.items[index];
                      final pickup = state
                          .addresses[TripHistoryCubit.pointKey(item.pickup)];
                      final dropoff = state
                          .addresses[TripHistoryCubit.pointKey(item.dropoff)];
                      return Card(
                        key: ValueKey('history-${item.bookingPublicId}'),
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: 2,
                        shadowColor: const Color(0x160E285A),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22)),
                        child: InkWell(
                          onTap: !_sameAccount
                              ? null
                              : () => Navigator.of(context).push(AppMotion
                                  .immediateRoute<void>(TripHistoryDetailScreen(
                                      customerPublicId: widget.customerPublicId,
                                      bookingPublicId: item.bookingPublicId))),
                          borderRadius: BorderRadius.circular(22),
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.check_circle_rounded,
                                      color: AppColors.success),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(
                                          historyDate(item.tripCompletedAt),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium)),
                                ]),
                                const SizedBox(height: 14),
                                CustomerJourneyTimeline(
                                  pickup: pickup?.label ??
                                      historyPoint(item.pickup),
                                  dropoff: dropoff?.label ??
                                      historyPoint(item.dropoff),
                                ),
                                const Divider(height: 24),
                                Row(children: [
                                  Expanded(
                                      child: Text(item.vehicleType.label,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall)),
                                  Flexible(
                                      child: Text(
                                          historyMoney(
                                              item.finalFare, item.currency),
                                          textAlign: TextAlign.end,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                  color: AppColors.primary))),
                                ]),
                                const SizedBox(height: 6),
                                Text(historyPaymentLabel(item.paymentStatus),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium),
                                if (pickup != null || dropoff != null)
                                  Text(
                                      pickup?.attribution ??
                                          dropoff?.attribution ??
                                          '© OpenStreetMap contributors',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          );
        }),
      );
}
