import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import 'admin_quality_cubit.dart';

String _caseStatus(String status) => switch (status) {
      'OPEN' => 'Đang chờ rà soát',
      'WARNED' => 'Đã nhắc nhở',
      'DISPUTED' => 'Đang xem xét phản hồi',
      'SUSPENDED' => 'Đã tạm ngừng',
      'DISMISSED' => 'Đã đóng hồ sơ',
      _ => 'Đang rà soát',
    };

String _caseAction(String action) => switch (action) {
      'WARN' => 'Nhắc nhở',
      'SUSPEND' => 'Tạm ngừng',
      'DISMISS' => 'Đóng hồ sơ',
      'DISPUTE' => 'Tài xế đề nghị xem xét lại',
      _ => 'Đã cập nhật hồ sơ',
    };

class AdminQualityScreen extends StatefulWidget {
  final String adminPublicId;
  const AdminQualityScreen({super.key, required this.adminPublicId});

  @override
  State<AdminQualityScreen> createState() => _AdminQualityScreenState();
}

class _AdminQualityScreenState extends State<AdminQualityScreen>
    with WidgetsBindingObserver {
  late final AdminQualityCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = sl<AdminQualityCubit>(param1: widget.adminPublicId)..load();
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

  Future<void> _confirm(String action) async {
    var input = '';
    final note = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(switch (action) {
                'WARN' => 'Nhắc nhở tài xế?',
                'SUSPEND' => 'Tạm ngừng tài xế?',
                _ => 'Đóng hồ sơ rà soát?',
              }),
              content: TextField(
                  onChanged: (value) => input = value,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Lý do và ghi chú rà soát')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Hủy')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, input),
                    child: const Text('Xác nhận')),
              ],
            ));
    if (mounted && note != null && note.trim().isNotEmpty) {
      await _cubit.act(action, note);
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<AuthBloc, AuthState>(listener: (context, auth) {
        if (auth is! AuthenticatedState ||
            auth.user.role != UserRole.admin ||
            auth.user.publicId != widget.adminPublicId) {
          _cubit.invalidateSession();
        }
      }, builder: (context, auth) {
        if (auth is! AuthenticatedState ||
            auth.user.role != UserRole.admin ||
            auth.user.publicId != widget.adminPublicId) {
          return const Scaffold(
              body: Center(child: Text('Phiên quản trị đã thay đổi.')));
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Rà soát tài xế')),
          body: BlocBuilder<AdminQualityCubit, AdminQualityState>(
            builder: (context, state) {
              if (state.sessionEnded) {
                return const Center(child: Text('Phiên quản trị đã thay đổi.'));
              }
              return RefreshIndicator(
                onRefresh: _cubit.load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (state.loading) const LinearProgressIndicator(),
                    if (state.error != null)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(state.error!))),
                    if (state.uncertain && state.detail != null)
                      OutlinedButton.icon(
                          onPressed: state.loading
                              ? null
                              : () => _cubit.reconcile(
                                  state.detail!.qualityCase.publicId),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Xác minh quyết định mới nhất')),
                    if (state.detail case final detail?) ...[
                      Card(
                          child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Hồ sơ đang xem xét',
                                style: Theme.of(context).textTheme.titleLarge),
                            Text('Tài xế: '
                                '${detail.qualityCase.driverDisplayName ?? 'Chưa có tên hiển thị'}'),
                            Text('Trạng thái: '
                                '${_caseStatus(detail.qualityCase.status)}'),
                            Text('Điểm gần đây: '
                                '${detail.qualityCase.recentAverage.toStringAsFixed(2)} ★ '
                                '/ ${detail.qualityCase.ratingCount} đánh giá'),
                            Text(detail.qualityCase.reason),
                            const SizedBox(height: 10),
                            Text('Đánh giá liên quan',
                                style: Theme.of(context).textTheme.titleMedium),
                            for (final evidence in detail.evidence)
                              ListTile(
                                  title: Text('${evidence.stars} sao'),
                                  subtitle: evidence.comment == null
                                      ? null
                                      : Text(evidence.comment!)),
                            Text('Quyết định đã ghi nhận',
                                style: Theme.of(context).textTheme.titleMedium),
                            for (final action in detail.actions)
                              ListTile(
                                  title: Text(_caseAction(action.action)),
                                  subtitle: action.note == null
                                      ? null
                                      : Text(action.note!)),
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text('Mã tham chiếu hỗ trợ'),
                              children: [
                                SelectableText(
                                    'Tài xế: ${detail.qualityCase.driverPublicId}'),
                                SelectableText(
                                    'Hồ sơ: ${detail.qualityCase.publicId}'),
                              ],
                            ),
                            if (const {'OPEN', 'WARNED', 'DISPUTED'}
                                .contains(detail.qualityCase.status))
                              Wrap(spacing: 8, children: [
                                for (final action in const [
                                  'WARN',
                                  'SUSPEND',
                                  'DISMISS'
                                ])
                                  OutlinedButton(
                                    onPressed: state.working || state.uncertain
                                        ? null
                                        : () => _confirm(action),
                                    child: Text(switch (action) {
                                      'WARN' => 'Nhắc nhở',
                                      'SUSPEND' => 'Tạm ngừng',
                                      _ => 'Đóng hồ sơ',
                                    }),
                                  ),
                              ]),
                          ],
                        ),
                      )),
                    ],
                    Text('Hồ sơ chất lượng',
                        style: Theme.of(context).textTheme.titleLarge),
                    if (!state.loading && state.cases.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Chưa có hồ sơ cần rà soát.')),
                    for (final item in state.cases)
                      Card(
                          child: ListTile(
                        title: Text(item.driverDisplayName ?? 'Tài xế'),
                        subtitle: Text('${_caseStatus(item.status)} · '
                            '${item.recentAverage.toStringAsFixed(2)} sao · '
                            '${item.ratingCount} đánh giá'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: state.working
                            ? null
                            : () => _cubit.open(item.publicId),
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
