import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/premium_panel.dart';

enum AdminTone { neutral, info, success, warning, danger }

Color _toneColor(AdminTone tone) => switch (tone) {
      AdminTone.neutral => AppColors.textSecondary,
      AdminTone.info => AppColors.primary,
      AdminTone.success => AppColors.success,
      AdminTone.warning => AppColors.warning,
      AdminTone.danger => AppColors.error,
    };

Color _toneBackground(AdminTone tone) => switch (tone) {
      AdminTone.neutral => AppColors.background,
      AdminTone.info => AppColors.paleBlue,
      AdminTone.success => const Color(0xFFE8F6EF),
      AdminTone.warning => const Color(0xFFFFF4DD),
      AdminTone.danger => const Color(0xFFFDECEB),
    };

class AdminStatusBadge extends StatelessWidget {
  final String label;
  final AdminTone tone;

  const AdminStatusBadge(this.label,
      {super.key, this.tone = AdminTone.neutral});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: _toneBackground(tone),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: _toneColor(tone), fontWeight: FontWeight.w700)),
        ),
      );
}

class AdminMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final AdminTone tone;
  final String? description;

  const AdminMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = AdminTone.info,
    this.description,
  });

  @override
  Widget build(BuildContext context) => PremiumPanel(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: _toneColor(tone), size: 22),
          const SizedBox(height: 10),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          if (description != null) ...[
            const SizedBox(height: 3),
            Text(description!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary)),
          ],
        ]),
      );
}

class AdminMetricGrid extends StatelessWidget {
  final List<Widget> children;

  const AdminMetricGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          const gap = 10.0;
          final columns = constraints.maxWidth < 430
              ? 1
              : constraints.maxWidth < 700
                  ? 2
                  : 3;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final child in children) SizedBox(width: width, child: child)
            ],
          );
        },
      );
}

class AdminInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const AdminInfoRow(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ]),
      );
}

class AdminEmptyPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  const AdminEmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) => PremiumPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: AppColors.primary, size: 28),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ]),
      );
}
