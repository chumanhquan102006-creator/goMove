import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/theme/app_motion.dart';
import 'rating_cubit.dart';

/// Completed trips only. The Cubit binds every read/write to the originating
/// authenticated session; this widget never treats a Booking UUID as access.
class RatingPanel extends StatefulWidget {
  final String bookingPublicId;
  final String customerPublicId;
  final bool autoPrompt;

  const RatingPanel(
      {super.key,
      required this.bookingPublicId,
      required this.customerPublicId,
      this.autoPrompt = false});

  @override
  State<RatingPanel> createState() => _RatingPanelState();
}

class _RatingPanelState extends State<RatingPanel> with WidgetsBindingObserver {
  late final RatingCubit _cubit;
  bool _offered = false;
  bool _foreground = true;
  BuildContext? _sheetContext;

  @override
  void initState() {
    super.initState();
    _cubit = sl<RatingCubit>(
        param1: widget.bookingPublicId, param2: widget.customerPublicId)
      ..load();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _cubit.load();
    } else {
      _foreground = false;
      _cubit.hideForBackground();
      final sheet = _sheetContext;
      if (sheet != null &&
          sheet.mounted &&
          ModalRoute.of(sheet)?.isCurrent == true) {
        Navigator.of(sheet).pop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cubit.close();
    super.dispose();
  }

  void _offer(RatingState state) {
    if (!widget.autoPrompt ||
        _offered ||
        !_foreground ||
        state.loading ||
        state.submitting ||
        state.sessionEnded ||
        state.rating != null ||
        state.error != null ||
        state.uncertain ||
        state.skipped) {
      return;
    }
    _offered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _foreground &&
          !_cubit.state.sessionEnded &&
          _cubit.state.rating == null) {
        _openSheet();
      }
    });
  }

  Future<void> _openSheet() async {
    if (!_foreground ||
        _sheetContext != null ||
        _cubit.state.sessionEnded ||
        _cubit.state.rating != null ||
        _cubit.state.loading) {
      return;
    }
    var comment = '';
    var stars = 0;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheet) {
          _sheetContext = sheet;
          return BlocProvider.value(
            value: _cubit,
            child: StatefulBuilder(
                builder: (sheet, setSheetState) =>
                    BlocConsumer<RatingCubit, RatingState>(
                      listener: (sheet, state) {
                        if (state.rating != null || state.sessionEnded) {
                          Navigator.of(sheet).pop();
                        }
                      },
                      builder: (sheet, state) => SafeArea(
                        top: false,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(24, 8, 24,
                              MediaQuery.viewInsetsOf(sheet).bottom + 24),
                          child: SingleChildScrollView(
                              child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('Chuyến đi của bạn thế nào?',
                                  style:
                                      Theme.of(sheet).textTheme.headlineSmall),
                              const SizedBox(height: 6),
                              const Text(
                                  'Đánh giá tài xế là tùy chọn và giúp nâng cao chất lượng chuyến đi.'),
                              const SizedBox(height: 16),
                              Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(5, (index) {
                                    final selected = index < stars;
                                    return IconButton(
                                      key: ValueKey('rating-star-${index + 1}'),
                                      tooltip: '${index + 1} sao',
                                      onPressed: state.submitting
                                          ? null
                                          : () => setSheetState(
                                              () => stars = index + 1),
                                      icon: AnimatedScale(
                                        duration: AppMotion.duration(
                                            sheet, AppMotion.feedback),
                                        scale: selected ? 1.12 : 1,
                                        child: Icon(
                                            selected
                                                ? Icons.star_rounded
                                                : Icons.star_outline_rounded,
                                            color: selected
                                                ? Colors.amber.shade700
                                                : Theme.of(sheet)
                                                    .colorScheme
                                                    .outline,
                                            size: 34),
                                      ),
                                    );
                                  })),
                              const SizedBox(height: 12),
                              TextField(
                                key: const ValueKey('rating-comment'),
                                onChanged: (value) => comment = value,
                                maxLength: 500,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                    labelText: 'Chia sẻ thêm (không bắt buộc)',
                                    border: OutlineInputBorder()),
                              ),
                              if (state.error != null)
                                Text(state.error!,
                                    style: TextStyle(
                                        color:
                                            Theme.of(sheet).colorScheme.error)),
                              if (state.uncertain)
                                OutlinedButton.icon(
                                    onPressed:
                                        state.loading ? null : _cubit.load,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Kiểm tra kết quả gửi')),
                              FilledButton(
                                  key: const ValueKey('rating-submit'),
                                  onPressed: stars == 0 ||
                                          state.submitting ||
                                          state.uncertain ||
                                          state.loading
                                      ? null
                                      : () => _cubit.submit(stars, comment),
                                  child: Text(state.submitting
                                      ? 'Đang gửi…'
                                      : 'Gửi đánh giá')),
                              TextButton(
                                  key: const ValueKey('rating-skip'),
                                  onPressed: state.submitting
                                      ? null
                                      : () {
                                          _cubit.skip();
                                          Navigator.of(sheet).pop();
                                        },
                                  child: const Text('Để sau')),
                            ],
                          )),
                        ),
                      ),
                    )),
          );
        },
      );
    } finally {
      _sheetContext = null;
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
        value: _cubit,
        child: BlocConsumer<RatingCubit, RatingState>(
          listener: (context, state) => _offer(state),
          builder: (context, state) {
            if (state.sessionEnded) return const SizedBox.shrink();
            final rating = state.rating;
            return Card(
              key: const ValueKey('trip-rating-card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      AnimatedSwitcher(
                        duration:
                            AppMotion.duration(context, AppMotion.feedback),
                        child: Icon(
                            rating == null
                                ? Icons.star_border_rounded
                                : Icons.check_circle_rounded,
                            key: ValueKey(rating == null
                                ? 'rating-open'
                                : 'rating-saved'),
                            color: Theme.of(context).colorScheme.primary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                          child: AnimatedSwitcher(
                        duration:
                            AppMotion.duration(context, AppMotion.feedback),
                        child: Text(
                            rating == null
                                ? 'Đánh giá chuyến đi'
                                : 'Cảm ơn bạn đã đánh giá',
                            key: ValueKey(rating == null
                                ? 'rating-prompt'
                                : 'rating-thanks'),
                            style: Theme.of(context).textTheme.titleMedium),
                      )),
                    ]),
                    const SizedBox(height: 8),
                    if (rating != null)
                      Text(
                          '${rating.stars}/5 sao${rating.comment == null ? '' : ' · ${rating.comment}'}')
                    else if (state.loading)
                      const LinearProgressIndicator()
                    else ...[
                      const Text(
                          'Bạn có thể đánh giá tài xế ngay hoặc để sau.'),
                      if (state.error != null) Text(state.error!),
                      if (state.uncertain)
                        OutlinedButton(
                            onPressed: _cubit.load,
                            child: const Text('Kiểm tra kết quả gửi'))
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (state.error != null)
                              TextButton(
                                  onPressed: _cubit.load,
                                  child: const Text('Tải lại đánh giá')),
                            TextButton.icon(
                                onPressed: _openSheet,
                                icon: const Icon(Icons.rate_review_outlined),
                                label: const Text('Đánh giá tài xế')),
                          ],
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );
}
