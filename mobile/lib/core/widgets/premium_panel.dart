import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A presentation-only surface for the light GoMove dashboard language.
class PremiumPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlighted;
  final Color? tint;

  const PremiumPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.highlighted = false,
    this.tint,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          gradient: highlighted
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.paleBlue, AppColors.paleViolet],
                )
              : null,
          color: highlighted
              ? null
              : tint ?? Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
              color: highlighted ? const Color(0xFFCFD8F7) : AppColors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x100E285A),
              blurRadius: 22,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Material(type: MaterialType.transparency, child: child),
      );
}

class PremiumSectionHeading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const PremiumSectionHeading({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.paleBlue,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, color: AppColors.primary, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          )),
                ],
              ],
            ),
          ),
        ],
      );
}
