import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/di/injection.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/usecases/customer_usecases.dart';
import '../bloc/booking_status_cubit.dart';
import '../formatters.dart';

class BookingStatusScreen extends StatefulWidget {
  final Booking booking;
  const BookingStatusScreen({super.key, required this.booking});

  @override
  State<BookingStatusScreen> createState() => _BookingStatusScreenState();
}

class _BookingStatusScreenState extends State<BookingStatusScreen>
    with WidgetsBindingObserver {
  late final BookingStatusCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = BookingStatusCubit(sl<GetBookingUseCase>(), widget.booking)
      ..start();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.start();
      unawaited(_cubit.refresh());
    } else {
      _cubit.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => _cubit,
        child: Scaffold(
            appBar: AppBar(title: const Text('Trạng thái chuyến')),
            body: BlocBuilder<BookingStatusCubit, BookingStatusState>(
                builder: (context, state) {
              final value = state.booking;
              return ListView(padding: const EdgeInsets.all(20), children: [
                Text(value.status,
                    style: Theme.of(context).textTheme.headlineSmall),
                if (!value.isCompleted)
                  const Text(
                      'Đang kiểm tra trạng thái mỗi 5 giây khi màn hình mở.'),
                if (state.error != null)
                  Text(state.error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 14),
                ListTile(
                    title: const Text('Mã Booking'),
                    subtitle: SelectableText(value.publicId)),
                ListTile(
                    title: const Text('Loại xe'),
                    subtitle: Text(value.vehicleType.label)),
                ListTile(
                    title: const Text('Giá đã chấp nhận'),
                    subtitle: Text(vnd(value.finalFare))),
                ListTile(
                    title: const Text('Tạo lúc'),
                    subtitle: Text(value.createdAt.toLocal().toString())),
                if (value.driverPublicId != null)
                  ListTile(
                      title: const Text('Mã tài xế'),
                      subtitle: SelectableText(value.driverPublicId!)),
                if (value.vehiclePublicId != null)
                  ListTile(
                      title: const Text('Mã xe'),
                      subtitle: SelectableText(value.vehiclePublicId!)),
                OutlinedButton(
                    onPressed: () =>
                        context.read<BookingStatusCubit>().refresh(),
                    child: const Text('Cập nhật ngay')),
              ]);
            })),
      );
}
