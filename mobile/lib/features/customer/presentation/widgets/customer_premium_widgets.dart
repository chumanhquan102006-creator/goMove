import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_motion.dart';

/// Presentation-only surfaces. They never own route, fare or tracking data.
class CustomerPremiumSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlighted;
  final Key? surfaceKey;

  const CustomerPremiumSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.highlighted = false,
    this.surfaceKey,
  });

  @override
  Widget build(BuildContext context) => Container(
        key: surfaceKey,
        padding: padding,
        decoration: BoxDecoration(
          gradient: highlighted
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.paleBlue, AppColors.paleViolet],
                )
              : null,
          color: highlighted ? null : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: highlighted ? const Color(0xFFCFD8F7) : AppColors.border,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x100E285A),
              blurRadius: 22,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: child,
      );
}

class CustomerSectionHeading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const CustomerSectionHeading(
      {super.key, required this.icon, required this.title, this.subtitle});

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
                if (subtitle != null)
                  Text(subtitle!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      );
}

/// A compact route overview using labels supplied by the calling screen.
class CustomerJourneyTimeline extends StatelessWidget {
  final String pickup;
  final String dropoff;
  final int? pickupMaxLines;
  final int? dropoffMaxLines;

  const CustomerJourneyTimeline(
      {super.key,
      required this.pickup,
      required this.dropoff,
      this.pickupMaxLines = 2,
      this.dropoffMaxLines = 2});

  @override
  Widget build(BuildContext context) {
    Widget stop(String title, String address, IconData icon, Color color,
            int? maxLines) =>
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 3),
                  Text(address,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        );
    return Column(children: [
      stop('Điểm đón', pickup, Icons.trip_origin, AppColors.primary,
          pickupMaxLines),
      Padding(
        padding: const EdgeInsets.only(left: 9),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(width: 2, height: 18, color: AppColors.border),
        ),
      ),
      stop('Điểm đến', dropoff, Icons.location_on_rounded, AppColors.violet,
          dropoffMaxLines),
    ]);
  }
}

/// An entry point to the editable search field in the booking sheet.
class CustomerFloatingPlaceField extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const CustomerFloatingPlaceField({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.selected,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '$label, $value',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.feedback),
              curve: AppMotion.standardCurve,
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12, vertical: compact ? 7 : 9),
              decoration: BoxDecoration(
                color: selected ? AppColors.paleBlue : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: selected ? AppColors.primary : AppColors.border,
                    width: selected ? 1.5 : 1),
              ),
              child: Row(children: [
                Icon(icon,
                    color: selected ? AppColors.primary : AppColors.violet,
                    size: 20),
                SizedBox(width: compact ? 7 : 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: AppColors.textSecondary)),
                      Text(value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                if (!compact)
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textSecondary),
              ]),
            ),
          ),
        ),
      );
}

class CustomerPressableAction extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const CustomerPressableAction(
      {super.key, required this.onPressed, required this.child});

  @override
  State<CustomerPressableAction> createState() =>
      _CustomerPressableActionState();
}

class _CustomerPressableActionState extends State<CustomerPressableAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown:
            widget.onPressed == null ? null : (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? .98 : 1,
          duration: AppMotion.duration(context, AppMotion.touch),
          curve: AppMotion.standardCurve,
          child: FilledButton(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: widget.onPressed,
            child: widget.child,
          ),
        ),
      );
}
