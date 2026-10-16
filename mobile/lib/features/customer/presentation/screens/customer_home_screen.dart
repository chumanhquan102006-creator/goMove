import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../driver/presentation/screens/driver_onboarding_screen.dart';
import '../../domain/models/quote.dart';
import '../bloc/booking_cubit.dart';
import '../bloc/quote_cubit.dart';
import 'booking_status_screen.dart';
import 'quote_review_screen.dart';

class CustomerHomeScreen extends StatelessWidget {
  final User user;
  const CustomerHomeScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => sl<QuoteCubit>()),
          BlocProvider(
              create: (_) => sl<BookingCubit>(param1: user.publicId)..restore()),
        ],
        child: _CustomerHomeContent(user: user),
      );
}

class _CustomerHomeContent extends StatefulWidget {
  final User user;
  const _CustomerHomeContent({required this.user});
  @override
  State<_CustomerHomeContent> createState() => _CustomerHomeContentState();
}

class _CustomerHomeContentState extends State<_CustomerHomeContent> {
  final _form = GlobalKey<FormState>();
  final _pickupLat = TextEditingController(text: '21.0287');
  final _pickupLon = TextEditingController(text: '105.8524');
  final _dropoffLat = TextEditingController(text: '21.0245');
  final _dropoffLon = TextEditingController(text: '105.8576');
  VehicleType _vehicle = VehicleType.motorbike;

  @override
  void dispose() {
    for (final controller in [
      _pickupLat,
      _pickupLon,
      _dropoffLat,
      _dropoffLon
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _coordinate(String label, TextEditingController controller, double min,
          double max) =>
      TextFormField(
        controller: controller,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
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

  void _request() {
    if (!(_form.currentState?.validate() ?? false)) return;
    context.read<QuoteCubit>().request(QuoteRequest(
          pickup: Coordinates(
              double.parse(_pickupLat.text), double.parse(_pickupLon.text)),
          dropoff: Coordinates(
              double.parse(_dropoffLat.text), double.parse(_dropoffLon.text)),
          vehicleType: _vehicle,
        ));
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(
        listeners: [
          BlocListener<QuoteCubit, QuoteState>(listener: (context, state) {
            if (state.quote != null) {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => BlocProvider.value(
                        value: context.read<BookingCubit>(),
                        child: QuoteReviewScreen(
                            quote: state.quote!),
                      )));
            }
          }),
          BlocListener<BookingCubit, BookingState>(listener: (context, state) {
            if (state.booking != null &&
                ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      BookingStatusScreen(booking: state.booking!)));
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
          body: ListView(padding: const EdgeInsets.all(20), children: [
            Text('Xin chào, ${widget.user.fullName}',
                style: Theme.of(context).textTheme.titleLarge),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const DriverOnboardingScreen())),
              icon: const Icon(Icons.directions_bike),
              label: const Text('Đăng ký làm tài xế'),
            ),
            const SizedBox(height: 12),
            if (AppConfig.instance.isMock)
              const Card(
                  child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    'Mock Auth đang bật. Chạy MOCK_ENABLED=false để dùng Quote/Booking thật.'),
              )),
            BlocBuilder<BookingCubit, BookingState>(builder: (context, state) {
              final pending = state.pending;
              if (pending == null) return const SizedBox.shrink();
              return Card(
                  color: Colors.amber.shade50,
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Booking đang chờ xác minh kết quả',
                                style: TextStyle(fontWeight: FontWeight.bold)),
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
                                          final confirmed =
                                              await showDialog<bool>(
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
                                                                      ctx,
                                                                      false),
                                                              child: const Text(
                                                                  'Giữ lại')),
                                                          TextButton(
                                                              onPressed: () =>
                                                                  Navigator.pop(
                                                                      ctx,
                                                                      true),
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
            const SizedBox(height: 8),
            const Text(
                'Tọa độ mẫu Hà Nội — có thể sửa trực tiếp; chưa có tìm địa chỉ.'),
            const SizedBox(height: 16),
            Form(
                key: _form,
                child: Column(children: [
                  _coordinate('Điểm đón · vĩ độ', _pickupLat, -90, 90),
                  const SizedBox(height: 10),
                  _coordinate('Điểm đón · kinh độ', _pickupLon, -180, 180),
                  const SizedBox(height: 18),
                  _coordinate('Điểm đến · vĩ độ', _dropoffLat, -90, 90),
                  const SizedBox(height: 10),
                  _coordinate('Điểm đến · kinh độ', _dropoffLon, -180, 180),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<VehicleType>(
                      initialValue: _vehicle,
                      decoration: const InputDecoration(
                          labelText: 'Loại xe', border: OutlineInputBorder()),
                      items: VehicleType.values
                          .map((value) => DropdownMenuItem(
                              value: value, child: Text(value.label)))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _vehicle = value ?? _vehicle)),
                ])),
            const SizedBox(height: 20),
            BlocBuilder<QuoteCubit, QuoteState>(
                builder: (context, state) => Column(children: [
                      SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed:
                                state.loading || AppConfig.instance.isMock
                                    ? null
                                    : _request,
                            child: state.loading
                                ? const CircularProgressIndicator()
                                : const Text('Lấy báo giá từ máy chủ'),
                          )),
                      if (state.error != null)
                        Text(state.error!,
                            style: const TextStyle(color: Colors.red)),
                    ])),
          ]),
        ),
      );
}
