import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import 'driver_reputation_cubit.dart';

class DriverReputationScreen extends StatefulWidget {
  final String driverPublicId;
  const DriverReputationScreen({super.key, required this.driverPublicId});

  @override
  State<DriverReputationScreen> createState() => _DriverReputationScreenState();
}

class _DriverReputationScreenState extends State<DriverReputationScreen>
    with WidgetsBindingObserver {
  late final DriverReputationCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = sl<DriverReputationCubit>(param1: widget.driverPublicId)..load();
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

  Future<void> _dispute(String publicId) async {
    var input = '';
    final reason = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Yêu cầu rà soát'),
              content: TextField(
                  onChanged: (value) => input = value,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Lý do cần xem xét lại')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Đóng')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, input),
                    child: const Text('Gửi yêu cầu')),
              ],
            ));
    if (mounted && reason != null && reason.trim().isNotEmpty) {
      await _cubit.dispute(publicId, reason);
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<AuthBloc, AuthState>(listener: (context, auth) {
        if (auth is! AuthenticatedState ||
            auth.user.role != UserRole.driver ||
            auth.user.publicId != widget.driverPublicId) {
          _cubit.invalidateSession();
        }
      }, builder: (context, auth) {
        if (auth is! AuthenticatedState ||
            auth.user.role != UserRole.driver ||
            auth.user.publicId != widget.driverPublicId) {
          return const Scaffold(
              body: Center(child: Text('Phiên đăng nhập đã thay đổi.')));
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Đánh giá và GoPoints')),
          body: BlocBuilder<DriverReputationCubit, DriverReputationState>(
            builder: (context, state) {
              if (state.sessionEnded) {
                return const Center(
                    child: Text('Phiên đăng nhập đã thay đổi.'));
              }
              if (state.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              return RefreshIndicator(
                onRefresh: _cubit.load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (state.error != null)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(state.error!))),
                    if (state.reputation case final reputation?) ...[
                      Card(
                          child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Đánh giá từ khách hàng',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            Text(
                                reputation.ratingCount == 0 ||
                                        reputation.average == null
                                    ? 'Chưa có đánh giá'
                                    : '${reputation.average!.toStringAsFixed(2)} ★ · '
                                        '${reputation.ratingCount} chuyến được đánh giá',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 12),
                            Text('${reputation.availablePoints} GoPoints',
                                style:
                                    Theme.of(context).textTheme.headlineMedium),
                            Text('Đã cộng ${reputation.earnedPoints} · '
                                'Đã trừ ${reputation.deductedPoints}'),
                            const SizedBox(height: 4),
                            const Text(
                                'GoPoints là điểm ghi nhận nội bộ, không phải tiền mặt.'),
                            if (reputation.badges.isNotEmpty)
                              Wrap(spacing: 6, children: [
                                for (final badge in reputation.badges)
                                  Chip(
                                      label: Text(switch (badge) {
                                    'FAVORITE_DRIVER' =>
                                      'Tài xế được yêu thích',
                                    _ => badge,
                                  })),
                              ]),
                          ],
                        ),
                      )),
                    ],
                    const SizedBox(height: 16),
                    Text('Lịch sử GoPoints',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (state.rewards.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Chưa có lần cộng hoặc trừ điểm.')),
                    for (final event in state.rewards)
                      Card(
                          child: ListTile(
                        leading: Icon(event.pointsDelta >= 0
                            ? Icons.add_circle_outline
                            : Icons.remove_circle_outline),
                        title: Text('${event.stars} sao · '
                            '${event.pointsDelta >= 0 ? '+' : ''}${event.pointsDelta} GoPoints'),
                        subtitle: Text(
                            '${event.createdAt.day}/${event.createdAt.month}/'
                            '${event.createdAt.year}'),
                      )),
                    if (state.hasMoreRewards)
                      OutlinedButton.icon(
                        onPressed: state.loadingMoreRewards
                            ? null
                            : _cubit.loadMoreRewards,
                        icon: const Icon(Icons.expand_more),
                        label: Text(state.loadingMoreRewards
                            ? 'Đang tải…'
                            : 'Xem thêm lịch sử GoPoints'),
                      ),
                    const SizedBox(height: 16),
                    Text('Rà soát chất lượng',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (state.cases.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Chưa có hồ sơ cần rà soát.')),
                    for (final item in state.cases)
                      Card(
                          child: ListTile(
                        title: Text(switch (item.status) {
                          'OPEN' => 'Đang chờ rà soát',
                          'WARNED' => 'Đã được nhắc nhở',
                          'SUSPENDED' => 'Tạm ngừng nhận chuyến',
                          'DISPUTED' => 'Đang xem xét phản hồi',
                          'DISMISSED' => 'Đã đóng hồ sơ',
                          _ => 'Đang rà soát',
                        }),
                        subtitle: Text(item.reason),
                        trailing: const {'OPEN', 'WARNED', 'SUSPENDED'}
                                    .contains(item.status) &&
                                !state.working
                            ? TextButton(
                                onPressed: () => _dispute(item.publicId),
                                child: const Text('Phản hồi'))
                            : null,
                      )),
                    if (state.hasMoreCases)
                      OutlinedButton.icon(
                        onPressed: state.loadingMoreCases
                            ? null
                            : _cubit.loadMoreCases,
                        icon: const Icon(Icons.expand_more),
                        label: Text(state.loadingMoreCases
                            ? 'Đang tải…'
                            : 'Xem thêm hồ sơ'),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      }));
}
