import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/premium_panel.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../domain/review_models.dart';
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Hồ sơ tài xế',
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 4),
                            Text(
                              'Đánh giá và điểm được máy chủ xác nhận',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            if (state.error != null) ...[
                              PremiumPanel(
                                tint: Theme.of(context)
                                    .colorScheme
                                    .errorContainer,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(state.error!),
                                    TextButton.icon(
                                      onPressed: _cubit.load,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Tải lại'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            if (state.notice != null) ...[
                              PremiumPanel(child: Text(state.notice!)),
                              const SizedBox(height: 14),
                            ],
                            if (state.working) ...[
                              const LinearProgressIndicator(),
                              const SizedBox(height: 12),
                            ],
                            if (state.reputation case final reputation?) ...[
                              _summary(context, reputation),
                              const SizedBox(height: 22),
                              const PremiumSectionHeading(
                                icon: Icons.stars_outlined,
                                title: 'Lịch sử GoPoints',
                                subtitle:
                                    'Điểm cộng và trừ từ đánh giá đã xác minh',
                              ),
                              const SizedBox(height: 12),
                              if (state.rewards.isEmpty)
                                const PremiumPanel(
                                  child:
                                      Text('Chưa có lần cộng hoặc trừ điểm.'),
                                ),
                              for (final event in state.rewards) ...[
                                _reward(context, event),
                                const SizedBox(height: 10),
                              ],
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
                              const SizedBox(height: 24),
                              const PremiumSectionHeading(
                                icon: Icons.fact_check_outlined,
                                title: 'Rà soát chất lượng',
                                subtitle:
                                    'Hồ sơ và phản hồi được lưu trên máy chủ',
                              ),
                              const SizedBox(height: 12),
                              if (state.cases.isEmpty)
                                const PremiumPanel(
                                  child: Text('Chưa có hồ sơ cần rà soát.'),
                                ),
                              for (final item in state.cases) ...[
                                _case(context, item, state.working),
                                const SizedBox(height: 10),
                              ],
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
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }));

  Widget _summary(BuildContext context, DriverReputation reputation) =>
      PremiumPanel(
        highlighted: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PremiumSectionHeading(
            icon: Icons.workspace_premium_outlined,
            title: 'Đánh giá từ khách hàng',
          ),
          const SizedBox(height: 16),
          Text(
            reputation.ratingCount == 0 || reputation.average == null
                ? 'Chưa có đánh giá'
                : '${reputation.average!.toStringAsFixed(2)} ★ · '
                    '${reputation.ratingCount} chuyến được đánh giá',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          Text('${reputation.availablePoints} GoPoints',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  )),
          const SizedBox(height: 4),
          Text('Đã cộng ${reputation.earnedPoints} · '
              'Đã trừ ${reputation.deductedPoints}'),
          const SizedBox(height: 8),
          Text('GoPoints là điểm ghi nhận nội bộ, không phải tiền mặt.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  )),
          if (reputation.badges.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final badge in reputation.badges)
                Chip(
                    label: Text(switch (badge) {
                  'FAVORITE_DRIVER' => 'Tài xế được yêu thích',
                  _ => badge,
                })),
            ]),
          ],
        ]),
      );

  Widget _reward(BuildContext context, RewardEvent event) => PremiumPanel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            event.pointsDelta >= 0
                ? Icons.add_circle_outline
                : Icons.remove_circle_outline,
            color:
                event.pointsDelta >= 0 ? AppColors.success : AppColors.warning,
          ),
          title: Text('${event.stars} sao'),
          subtitle: Text('${event.createdAt.day}/${event.createdAt.month}/'
              '${event.createdAt.year}'),
          trailing: Text(
            '${event.pointsDelta >= 0 ? '+' : ''}${event.pointsDelta} GoPoints',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: event.pointsDelta >= 0
                      ? AppColors.success
                      : AppColors.warning,
                ),
          ),
        ),
      );

  Widget _case(BuildContext context, QualityCase item, bool working) =>
      PremiumPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.assignment_outlined, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_caseStatus(item.status),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
          const SizedBox(height: 10),
          Text(item.reason),
          if (const {'OPEN', 'WARNED', 'SUSPENDED'}.contains(item.status)) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: working ? null : () => _dispute(item.publicId),
              icon: const Icon(Icons.edit_note_outlined),
              label: const Text('Phản hồi'),
            ),
          ],
        ]),
      );
}

String _caseStatus(String status) => switch (status) {
      'OPEN' => 'Đang chờ rà soát',
      'WARNED' => 'Đã được nhắc nhở',
      'SUSPENDED' => 'Tạm ngừng nhận chuyến',
      'DISPUTED' => 'Đang xem xét phản hồi',
      'DISMISSED' => 'Đã đóng hồ sơ',
      _ => 'Đang rà soát',
    };
