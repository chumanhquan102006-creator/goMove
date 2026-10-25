import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../driver/presentation/screens/driver_onboarding_screen.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../bloc/booking_cubit.dart';
import '../bloc/customer_active_booking_cubit.dart';
import '../bloc/quote_cubit.dart';
import 'booking_status_screen.dart';
import 'customer_map_canvas.dart';
import 'quote_review_screen.dart';

class CustomerHomeScreen extends StatelessWidget {
  final User user;
  final CustomerMapBuilder? mapBuilder;
  const CustomerHomeScreen({super.key, required this.user, this.mapBuilder});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
        key: ValueKey(user.publicId),
        providers: [
          BlocProvider(create: (_) => sl<QuoteCubit>()),
          BlocProvider(
              create: (_) =>
                  sl<BookingCubit>(param1: user.publicId)..restore()),
          BlocProvider(
              create: (_) =>
                  sl<CustomerActiveBookingCubit>(param1: user.publicId)
                    ..restore()),
        ],
        child: _CustomerHomeContent(user: user, mapBuilder: mapBuilder),
      );
}

class _CustomerHomeContent extends StatefulWidget {
  final User user;
  final CustomerMapBuilder? mapBuilder;
  const _CustomerHomeContent({required this.user, this.mapBuilder});
  @override
  State<_CustomerHomeContent> createState() => _CustomerHomeContentState();
}

enum _MapTarget { pickup, dropoff }

class _CustomerHomeContentState extends State<_CustomerHomeContent>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _pickupLat = TextEditingController(text: '21.0287');
  final _pickupLon = TextEditingController(text: '105.8524');
  final _dropoffLat = TextEditingController(text: '21.0245');
  final _dropoffLon = TextEditingController(text: '105.8576');
  _MapTarget _mapTarget = _MapTarget.pickup;
  VehicleType _vehicle = VehicleType.motorbike;
  String? _coordinateError;

  bool get _isCurrentAccount {
    final auth = context.read<AuthBloc>().state;
    return auth is AuthenticatedState &&
        auth.user.publicId == widget.user.publicId;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final controller in [
      _pickupLat,
      _pickupLon,
      _dropoffLat,
      _dropoffLon,
    ]) {
      controller.addListener(_onCoordinateEdited);
    }
  }

  void _onCoordinateEdited() {
    if (mounted) setState(() => _coordinateError = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isCurrentAccount) {
      context.read<CustomerActiveBookingCubit>().restore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [
      _pickupLat,
      _pickupLon,
      _dropoffLat,
      _dropoffLon
    ]) {
      controller.removeListener(_onCoordinateEdited);
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _openBooking(Booking booking) async {
    if (!_isCurrentAccount) return;
    final recovery = context.read<CustomerActiveBookingCubit>();
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BookingStatusScreen(booking: booking)));
    if (mounted && _isCurrentAccount) await recovery.refresh();
  }

  Future<void> _recoverExistingBooking() async {
    final form = GlobalKey<FormState>();
    var input = '';
    final publicId = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Khôi phục Booking bằng UUID'),
              content: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'Chỉ Booking thuộc tài khoản đang đăng nhập mới được khôi phục. Máy chủ sẽ kiểm tra quyền truy cập trước khi hiển thị.'),
                    const SizedBox(height: 12),
                    TextFormField(
                      onChanged: (value) => input = value,
                      maxLength: 36,
                      decoration: const InputDecoration(
                          labelText: 'Booking public UUID',
                          border: OutlineInputBorder()),
                      validator: (value) =>
                          RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
                                  .hasMatch((value ?? '').trim())
                              ? null
                              : 'Nhập đúng UUID của Booking',
                    ),
                  ]),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Hủy')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState?.validate() ?? false) {
                        Navigator.pop(dialog, input.trim());
                      }
                    },
                    child: const Text('Kiểm tra Booking')),
              ],
            ));
    if (publicId != null && mounted && _isCurrentAccount) {
      await context
          .read<CustomerActiveBookingCubit>()
          .recoverByPublicId(publicId);
    }
  }

  Widget _coordinate(String label, TextEditingController controller, double min,
          double max) =>
      TextFormField(
        controller: controller,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.next,
        scrollPadding: const EdgeInsets.only(bottom: 96),
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        validator: (value) {
          final number = double.tryParse((value ?? '').trim());
          return number == null ||
                  !number.isFinite ||
                  number < min ||
                  number > max
              ? 'Nhập tọa độ từ $min đến $max'
              : null;
        },
      );

  Coordinates? _point(
      TextEditingController latitude, TextEditingController longitude) {
    final lat = double.tryParse(latitude.text.trim());
    final lon = double.tryParse(longitude.text.trim());
    if (lat == null || lon == null) return null;
    final point = Coordinates(lat, lon);
    return point.isValid ? point : null;
  }

  void _selectMapPoint(Coordinates point) {
    if (!_isCurrentAccount || !point.isValid) return;
    FocusScope.of(context).unfocus();
    final latitude = point.latitude.toStringAsFixed(6);
    final longitude = point.longitude.toStringAsFixed(6);
    if (_mapTarget == _MapTarget.pickup) {
      _pickupLat.text = latitude;
      _pickupLon.text = longitude;
    } else {
      _dropoffLat.text = latitude;
      _dropoffLon.text = longitude;
    }
  }

  Widget _pointSummary(
      String label, Coordinates? point, Color color, _MapTarget target) {
    final selected = _mapTarget == target;
    final coordinateLabel = point == null
        ? 'Chưa có tọa độ hợp lệ'
        : 'Vĩ độ ${point.latitude.toStringAsFixed(6)} · Kinh độ ${point.longitude.toStringAsFixed(6)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        key: ValueKey('$target-point-summary-motion'),
        duration: AppMotion.duration(context, AppMotion.touch),
        curve: AppMotion.enterCurve,
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(20) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _mapTarget = target),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(
                  target == _MapTarget.pickup
                      ? Icons.trip_origin
                      : Icons.location_on,
                  color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: AppMotion.duration(context, AppMotion.feedback),
                      switchInCurve: AppMotion.enterCurve,
                      switchOutCurve: AppMotion.exitCurve,
                      child: Text(coordinateLabel,
                          key: ValueKey(coordinateLabel),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle,
                    size: 20, color: Theme.of(context).colorScheme.primary),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _coordinatePair(
      String firstLabel,
      TextEditingController first,
      double firstMin,
      double firstMax,
      String secondLabel,
      TextEditingController second,
      double secondMin,
      double secondMax) {
    return LayoutBuilder(builder: (context, constraints) {
      final firstField = _coordinate(firstLabel, first, firstMin, firstMax);
      final secondField =
          _coordinate(secondLabel, second, secondMin, secondMax);
      if (constraints.maxWidth < 350) {
        return Column(children: [
          firstField,
          const SizedBox(height: 10),
          secondField,
        ]);
      }
      return Row(children: [
        Expanded(child: firstField),
        const SizedBox(width: 8),
        Expanded(child: secondField),
      ]);
    });
  }

  void _request() {
    if (!_isCurrentAccount || context.read<QuoteCubit>().state.loading) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final request = QuoteRequest(
      pickup: Coordinates(double.parse(_pickupLat.text.trim()),
          double.parse(_pickupLon.text.trim())),
      dropoff: Coordinates(double.parse(_dropoffLat.text.trim()),
          double.parse(_dropoffLon.text.trim())),
      vehicleType: _vehicle,
    );
    try {
      request.validate();
    } on FormatException catch (error) {
      setState(() => _coordinateError = error.message);
      return;
    }
    context.read<QuoteCubit>().request(request);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthenticatedState ||
        auth.user.publicId != widget.user.publicId) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pickup = _point(_pickupLat, _pickupLon);
    final dropoff = _point(_dropoffLat, _dropoffLon);
    return MultiBlocListener(
      listeners: [
        BlocListener<QuoteCubit, QuoteState>(listener: (context, state) async {
          if (state.quote != null && _isCurrentAccount) {
            await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => BlocProvider.value(
                      value: context.read<BookingCubit>(),
                      child: QuoteReviewScreen(quote: state.quote!),
                    )));
            if (context.mounted && _isCurrentAccount) {
              await context.read<CustomerActiveBookingCubit>().restore();
            }
          }
        }),
        BlocListener<BookingCubit, BookingState>(
            listener: (context, state) async {
          if (state.booking != null &&
              _isCurrentAccount &&
              ModalRoute.of(context)?.isCurrent == true) {
            await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => BookingStatusScreen(booking: state.booking!)));
            if (context.mounted && _isCurrentAccount) {
              await context.read<CustomerActiveBookingCubit>().restore();
            }
          }
        }),
      ],
      child: Scaffold(
        appBar: AppBar(title: const Text('Đặt xe GoMove'), actions: [
          IconButton(
            tooltip: 'Đăng xuất',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthLogoutRequested()),
          )
        ]),
        body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text('Xin chào, ${widget.user.fullName}',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Chọn hành trình và nhận báo giá trước khi đặt xe.',
                  style: Theme.of(context).textTheme.bodyMedium),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const DriverOnboardingScreen())),
                  icon: const Icon(Icons.directions_bike),
                  label: const Text('Đăng ký làm tài xế'),
                ),
              ),
              BlocBuilder<CustomerActiveBookingCubit,
                  CustomerActiveBookingState>(builder: (context, state) {
                final booking = state.booking;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.loading)
                        const LinearProgressIndicator(
                            semanticsLabel: 'Đang xác minh Booking'),
                      if (!state.loading && state.isActive && booking != null)
                        AppMotion.entrance(
                            context,
                            Card(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(Icons.directions_car,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onPrimaryContainer),
                                          const SizedBox(height: 8),
                                          Text(
                                              customerTripStatusLabel(
                                                  booking.status),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          Text(
                                              'Booking UUID: ${booking.publicId}'),
                                          if (booking.status == 'COMPLETED')
                                            Text(state.payment == null
                                                ? 'Chưa xác minh được thanh toán tiền mặt.'
                                                : 'Thanh toán tiền mặt chưa xác nhận (PENDING).'),
                                          const SizedBox(height: 8),
                                          FilledButton.icon(
                                              onPressed: state.loading
                                                  ? null
                                                  : () => _openBooking(booking),
                                              icon: const Icon(
                                                  Icons.directions_car),
                                              label: const Text(
                                                  'Tiếp tục chuyến đang diễn ra')),
                                        ])))),
                      if (!state.loading &&
                          !state.isActive &&
                          booking != null &&
                          booking.status == 'COMPLETED' &&
                          state.payment?.isPaid == true)
                        AppMotion.entrance(
                            context,
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                              'Chuyến đã hoàn thành · Đã thanh toán (PAID)'),
                                          Text(
                                              'Booking UUID: ${booking.publicId}'),
                                          TextButton(
                                              onPressed: state.loading
                                                  ? null
                                                  : () => _openBooking(booking),
                                              child:
                                                  const Text('Xem lại chuyến')),
                                        ])))),
                      if (state.error != null)
                        Card(
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(state.error!))),
                      if (state.sessionEnded)
                        const Text(
                            'Phiên đăng nhập đã thay đổi. Hãy đăng nhập lại để khôi phục chuyến.'),
                      TextButton.icon(
                          onPressed: state.loading || state.sessionEnded
                              ? null
                              : _recoverExistingBooking,
                          icon: const Icon(Icons.manage_search),
                          label: const Text('Khôi phục Booking bằng UUID')),
                    ]);
              }),
              const SizedBox(height: 12),
              if (AppConfig.instance.isMock)
                const Card(
                    child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                      'Mock Auth đang bật. Chạy MOCK_ENABLED=false để dùng Quote/Booking thật.'),
                )),
              BlocBuilder<BookingCubit, BookingState>(
                  builder: (context, state) {
                final pending = state.pending;
                if (pending == null) return const SizedBox.shrink();
                return Card(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Booking đang chờ xác minh kết quả',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              Text('Quote: ${pending.quotePublicId}'),
                              const Text(
                                  'Nếu mạng bị ngắt, thử lại sẽ dùng cùng Idempotency-Key.'),
                              Wrap(spacing: 8, children: [
                                FilledButton(
                                    onPressed: state.loading
                                        ? null
                                        : () => context
                                            .read<BookingCubit>()
                                            .submit(pending.quotePublicId),
                                    child: const Text('Thử lại yêu cầu cũ')),
                                TextButton(
                                    onPressed: state.loading
                                        ? null
                                        : () async {
                                            final confirmed = await showDialog<
                                                    bool>(
                                                context: context,
                                                builder: (ctx) => AlertDialog(
                                                      title: const Text(
                                                          'Bỏ yêu cầu đang chờ?'),
                                                      content: const Text(
                                                          'Kết quả cũ có thể đã tạo Booking. Chỉ bỏ khi bạn đã tự xác minh kết quả hoặc chấp nhận rủi ro đó.'),
                                                      actions: [
                                                        TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                    ctx, false),
                                                            child: const Text(
                                                                'Giữ lại')),
                                                        TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                    ctx, true),
                                                            child: const Text(
                                                                'Bỏ yêu cầu'))
                                                      ],
                                                    ));
                                            if (confirmed == true &&
                                                context.mounted) {
                                              await context
                                                  .read<BookingCubit>()
                                                  .abandon();
                                            }
                                          },
                                    child: const Text('Bỏ yêu cầu')),
                              ]),
                              if (state.error != null)
                                Text(state.error!,
                                    style: const TextStyle(color: Colors.red)),
                            ])));
              }),
              const SizedBox(height: 12),
              Text('Chọn điểm trên bản đồ',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                  'Chọn chế độ rồi chạm bản đồ. Chấm xanh viền là điểm đón, chấm cam là điểm đến.',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                AnimatedScale(
                  key: const ValueKey('pickup-selection-motion'),
                  scale: _mapTarget == _MapTarget.pickup ? 1 : .98,
                  duration: AppMotion.duration(context, AppMotion.touch),
                  curve: AppMotion.enterCurve,
                  child: ChoiceChip(
                    label: const Text('Chọn điểm đón'),
                    avatar: Icon(Icons.trip_origin,
                        color: Theme.of(context).colorScheme.primary),
                    selected: _mapTarget == _MapTarget.pickup,
                    onSelected: (_) =>
                        setState(() => _mapTarget = _MapTarget.pickup),
                  ),
                ),
                AnimatedScale(
                  key: const ValueKey('dropoff-selection-motion'),
                  scale: _mapTarget == _MapTarget.dropoff ? 1 : .98,
                  duration: AppMotion.duration(context, AppMotion.touch),
                  curve: AppMotion.enterCurve,
                  child: ChoiceChip(
                    label: const Text('Chọn điểm đến'),
                    avatar:
                        const Icon(Icons.location_on, color: Color(0xFFE87521)),
                    selected: _mapTarget == _MapTarget.dropoff,
                    onSelected: (_) =>
                        setState(() => _mapTarget = _MapTarget.dropoff),
                  ),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'Đang chọn: ${_mapTarget == _MapTarget.pickup ? 'Điểm đón' : 'Điểm đến'}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              widget.mapBuilder
                      ?.call(context, pickup, dropoff, _selectMapPoint) ??
                  CustomerMapCanvas(
                    pickup: pickup,
                    dropoff: dropoff,
                    onTap: _selectMapPoint,
                  ),
              const SizedBox(height: 10),
              _pointSummary('Điểm đón', pickup,
                  Theme.of(context).colorScheme.primary, _MapTarget.pickup),
              _pointSummary('Điểm đến', dropoff, const Color(0xFFE87521),
                  _MapTarget.dropoff),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Tọa độ và loại xe',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                          'Nhập tọa độ thủ công khi bản đồ không tải. Chưa có tìm địa chỉ; đây là tọa độ mẫu Hà Nội.',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 14),
                      Form(
                          key: _form,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('Điểm đón',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const SizedBox(height: 8),
                                _coordinatePair(
                                    'Điểm đón · vĩ độ',
                                    _pickupLat,
                                    -90,
                                    90,
                                    'Điểm đón · kinh độ',
                                    _pickupLon,
                                    -180,
                                    180),
                                const SizedBox(height: 14),
                                Text('Điểm đến',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const SizedBox(height: 8),
                                _coordinatePair(
                                    'Điểm đến · vĩ độ',
                                    _dropoffLat,
                                    -90,
                                    90,
                                    'Điểm đến · kinh độ',
                                    _dropoffLon,
                                    -180,
                                    180),
                                const SizedBox(height: 16),
                                DropdownButtonFormField<VehicleType>(
                                    initialValue: _vehicle,
                                    decoration: const InputDecoration(
                                        labelText: 'Loại xe',
                                        border: OutlineInputBorder()),
                                    items: VehicleType.values
                                        .map((value) => DropdownMenuItem(
                                            value: value,
                                            child: Text(value.label)))
                                        .toList(),
                                    onChanged: (value) => setState(
                                        () => _vehicle = value ?? _vehicle)),
                              ])),
                    ],
                  ),
                ),
              ),
              if (_coordinateError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_coordinateError!,
                      style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 12),
              BlocBuilder<QuoteCubit, QuoteState>(
                  builder: (context, state) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                                width: double.infinity,
                                height: 52,
                                child: FilledButton(
                                  onPressed:
                                      state.loading || AppConfig.instance.isMock
                                          ? null
                                          : _request,
                                  child: AnimatedSwitcher(
                                    duration: AppMotion.duration(
                                        context, AppMotion.feedback),
                                    child: state.loading
                                        ? const SizedBox(
                                            key: ValueKey('quote-loading'),
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Text('Lấy báo giá từ máy chủ',
                                            key: ValueKey('quote-action')),
                                  ),
                                )),
                            if (state.error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(state.error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error)),
                              ),
                          ])),
            ]),
      ),
    );
  }
}
