import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/premium_panel.dart';
import '../../admin/presentation/widgets/admin_premium_widgets.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../domain/review_models.dart';
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

AdminTone _caseTone(String status) => switch (status) {
      'SUSPENDED' => AdminTone.danger,
      'OPEN' || 'DISPUTED' => AdminTone.warning,
      'WARNED' => AdminTone.info,
      _ => AdminTone.neutral,
    };

String _caseDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

class AdminQualityScreen extends StatefulWidget {
  final String adminPublicId;
  final AdminQualityCubit? cubit;

  const AdminQualityScreen({
    super.key,
    required this.adminPublicId,
    this.cubit,
  });

  @override
  State<AdminQualityScreen> createState() => _AdminQualityScreenState();
}

class _AdminQualityScreenState extends State<AdminQualityScreen>
    with WidgetsBindingObserver {
  late final AdminQualityCubit _cubit;
  BuildContext? _decisionDialog;

  @override
  void initState() {
    super.initState();
    _cubit =
        widget.cubit ?? sl<AdminQualityCubit>(param1: widget.adminPublicId);
    _cubit.load();
    WidgetsBinding.instance.addObserver(this);
  }

  void _dismissDecisionDialog() {
    final dialog = _decisionDialog;
    _decisionDialog = null;
    if (dialog?.mounted == true && ModalRoute.of(dialog!)?.isCurrent == true) {
      Navigator.of(dialog).pop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.load();
    } else {
      _dismissDecisionDialog();
      _cubit.hideForBackground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cubit.close();
    super.dispose();
  }

  bool _authorized(AuthState auth) =>
      auth is AuthenticatedState &&
      auth.user.role == UserRole.admin &&
      auth.user.publicId == widget.adminPublicId;

  Future<void> _confirm(String action) async {
    var note = '';
    final submitted = await showDialog<String>(
      context: context,
      builder: (dialog) {
        _decisionDialog = dialog;
        return StatefulBuilder(builder: (dialog, setDialogState) {
          return AlertDialog(
            title: Text(switch (action) {
              'WARN' => 'Nhắc nhở tài xế?',
              'SUSPEND' => 'Tạm ngừng tài xế?',
              _ => 'Đóng hồ sơ rà soát?',
            }),
            content: TextField(
              onChanged: (value) => setDialogState(() => note = value),
              maxLength: 500,
              maxLines: 3,
              decoration:
                  const InputDecoration(labelText: 'Lý do và ghi chú rà soát'),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Hủy')),
              FilledButton(
                  onPressed: note.trim().isEmpty
                      ? null
                      : () => Navigator.pop(dialog, note.trim()),
                  child: const Text('Xác nhận')),
            ],
          );
        });
      },
    );
    _decisionDialog = null;
    if (mounted && submitted != null && submitted.isNotEmpty) {
      await _cubit.act(action, submitted);
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
        value: _cubit,
        child: BlocConsumer<AuthBloc, AuthState>(
          listener: (context, auth) {
            if (!_authorized(auth)) {
              _dismissDecisionDialog();
              _cubit.invalidateSession();
            }
          },
          builder: (context, auth) {
            if (!_authorized(auth)) {
              return const Scaffold(
                  body: Center(child: Text('Phiên quản trị đã thay đổi.')));
            }
            return Scaffold(
              appBar: AppBar(title: const Text('Chất lượng tài xế')),
              body: BlocBuilder<AdminQualityCubit, AdminQualityState>(
                builder: (context, state) {
                  if (state.sessionEnded) {
                    return const Center(
                        child: Text('Phiên quản trị đã thay đổi.'));
                  }
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: RefreshIndicator(
                        onRefresh: _cubit.load,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: _content(context, state),
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

  List<Widget> _content(BuildContext context, AdminQualityState state) => [
        AppMotion.entrance(
          context,
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Rà soát chất lượng',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 3),
              Text('Đánh giá đã xác minh và quyết định đã ghi nhận',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary)),
            ]),
          ),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('admin-quality-filter-${state.filter}'),
          isExpanded: true,
          initialValue: state.filter ?? '',
          decoration: const InputDecoration(labelText: 'Lọc trạng thái hồ sơ'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Tất cả hồ sơ')),
            for (final status in const [
              'OPEN',
              'WARNED',
              'DISPUTED',
              'SUSPENDED',
              'DISMISSED'
            ])
              DropdownMenuItem(value: status, child: Text(_caseStatus(status))),
          ],
          onChanged: state.working || state.uncertain || state.loading
              ? null
              : (value) => _cubit.setFilter(value == '' ? null : value),
        ),
        const SizedBox(height: 16),
        if (state.loading) const LinearProgressIndicator(),
        if (state.working && state.cases.isEmpty && state.detail == null) ...[
          const PremiumPanel(
              child: Text('Đang xử lý quyết định. '
                  'Hồ sơ sẽ được tải lại sau khi xác minh.')),
          const SizedBox(height: 12),
        ],
        if (state.error != null) ...[
          AdminEmptyPanel(
              icon: Icons.cloud_off_outlined,
              title: state.uncertain
                  ? 'Quyết định cần xác minh'
                  : 'Chưa tải được hồ sơ',
              message: state.error!,
              onRetry: state.uncertain ? null : _cubit.load),
          const SizedBox(height: 12),
        ],
        if (state.uncertain && state.detail != null) ...[
          OutlinedButton.icon(
              onPressed: state.loading
                  ? null
                  : () => _cubit.reconcile(state.detail!.qualityCase.publicId),
              icon: const Icon(Icons.refresh),
              label: const Text('Xác minh quyết định mới nhất')),
          const SizedBox(height: 12),
        ],
        if (state.detail case final detail?) ...[
          _detail(context, state, detail),
          const SizedBox(height: 22),
        ],
        const PremiumSectionHeading(
            icon: Icons.fact_check_outlined,
            title: 'Hồ sơ chất lượng',
            subtitle: 'Chọn hồ sơ để xem bằng chứng và lịch sử xử lý'),
        const SizedBox(height: 10),
        if (!state.loading &&
            !state.working &&
            !state.uncertain &&
            state.cases.isEmpty &&
            state.error == null)
          const AdminEmptyPanel(
              icon: Icons.inbox_outlined,
              title: 'Không có hồ sơ phù hợp',
              message: 'Chọn trạng thái khác hoặc kéo xuống để tải lại.'),
        for (final item in state.cases) ...[
          _caseCard(item, state),
          const SizedBox(height: 10),
        ],
        if (state.hasMoreCases)
          OutlinedButton.icon(
            onPressed: state.loadingMoreCases || state.working || state.uncertain
                ? null
                : _cubit.loadMoreCases,
            icon: const Icon(Icons.expand_more),
            label:
                Text(state.loadingMoreCases ? 'Đang tải…' : 'Xem thêm hồ sơ'),
          ),
      ];

  Widget _caseCard(QualityCase item, AdminQualityState state) => PremiumPanel(
        padding: EdgeInsets.zero,
        child: ListTile(
          key: ValueKey('admin-quality-${item.publicId}'),
          title: Text(item.driverDisplayName ?? 'Tài xế'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 6, children: [
                AdminStatusBadge(_caseStatus(item.status),
                    tone: _caseTone(item.status)),
                AdminStatusBadge('${item.recentAverage.toStringAsFixed(2)} ★ · '
                    '${item.ratingCount} đánh giá'),
              ]),
              const SizedBox(height: 4),
              Text(_caseDate(item.createdAt)),
            ]),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: state.working || state.uncertain
              ? null
              : () => _cubit.open(item.publicId),
        ),
      );

  Widget _detail(BuildContext context, AdminQualityState state,
          QualityDetail detail) =>
      PremiumPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hồ sơ đang xem xét',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(detail.qualityCase.driverDisplayName ?? 'Tài xế'),
          const SizedBox(height: 6),
          AdminStatusBadge(_caseStatus(detail.qualityCase.status),
              tone: _caseTone(detail.qualityCase.status)),
          const Divider(height: 24),
          AdminInfoRow(
              'Điểm gần đây',
              '${detail.qualityCase.recentAverage.toStringAsFixed(2)} ★ '
                  '· ${detail.qualityCase.ratingCount} đánh giá'),
          AdminInfoRow('Lý do tạo hồ sơ', detail.qualityCase.reason),
          AdminInfoRow(
              'Thời điểm tạo', _caseDate(detail.qualityCase.createdAt)),
          const Divider(height: 24),
          Text('Đánh giá đã xác minh',
              style: Theme.of(context).textTheme.titleMedium),
          if (detail.evidence.isEmpty)
            const Text('Chưa có đánh giá liên quan.'),
          for (final evidence in detail.evidence)
            AdminInfoRow(
                '${evidence.stars} sao · ${_caseDate(evidence.createdAt)}',
                evidence.comment ?? 'Không có nhận xét'),
          const Divider(height: 24),
          Text('Lịch sử quyết định và phản hồi',
              style: Theme.of(context).textTheme.titleMedium),
          if (detail.actions.isEmpty)
            const Text('Chưa có quyết định hoặc phản hồi.'),
          for (final action in detail.actions)
            AdminInfoRow(
                '${_caseAction(action.action)} · ${_caseDate(action.createdAt)}',
                action.note ?? 'Không có ghi chú'),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            expansionAnimationStyle: AnimationStyle(
                duration: AppMotion.duration(context, AppMotion.card)),
            title: const Text('Mã tham chiếu hỗ trợ'),
            children: [
              AdminInfoRow('Mã tài xế', detail.qualityCase.driverPublicId),
              AdminInfoRow('Mã hồ sơ', detail.qualityCase.publicId),
            ],
          ),
          if (const {'OPEN', 'WARNED', 'DISPUTED'}
              .contains(detail.qualityCase.status)) ...[
            const Divider(height: 24),
            Text('Quyết định', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final action in const ['WARN', 'SUSPEND', 'DISMISS'])
                if (action == 'WARN')
                  FilledButton(
                    onPressed: state.working || state.uncertain
                        ? null
                        : () => _confirm(action),
                    child: const Text('Nhắc nhở'),
                  )
                else
                  OutlinedButton(
                    onPressed: state.working || state.uncertain
                        ? null
                        : () => _confirm(action),
                    child:
                        Text(action == 'SUSPEND' ? 'Tạm ngừng' : 'Đóng hồ sơ'),
                  ),
            ]),
          ],
        ]),
      );
}
