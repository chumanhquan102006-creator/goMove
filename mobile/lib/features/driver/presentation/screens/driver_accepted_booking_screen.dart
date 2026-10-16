import 'package:flutter/material.dart';
import '../../../customer/presentation/formatters.dart';
import '../../domain/models/driver_models.dart';

/// Read-only M2 handoff. Trip transitions are deliberately absent.
class DriverAcceptedBookingScreen extends StatelessWidget {
  final DriverOffer offer;
  const DriverAcceptedBookingScreen({super.key, required this.offer});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Chuyến đã nhận')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Máy chủ đã xác nhận phân công chuyến. Tài xế đang BUSY.',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ))),
          const SizedBox(height: 12),
          Text('Booking UUID: ${offer.bookingPublicId}'),
          Text('Điểm đón: ${offer.pickupLatitude}, ${offer.pickupLongitude}'),
          Text('Điểm đến: ${offer.dropoffLatitude}, ${offer.dropoffLongitude}'),
          Text('Loại xe: ${offer.vehicleType}'),
          Text('Giá đã chấp nhận: ${vnd(offer.finalFare)}'),
          const SizedBox(height: 16),
          const Text('Đến/đón khách, bắt đầu/kết thúc chuyến thuộc M3.'),
        ]),
      );
}
