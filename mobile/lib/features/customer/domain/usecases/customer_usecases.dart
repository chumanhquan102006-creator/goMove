import 'package:uuid/uuid.dart';
import '../../data/active_booking_store.dart';
import '../../data/booking_intent_store.dart';
import '../models/booking.dart';
import '../models/booking_intent.dart';
import '../models/quote.dart';
import '../repositories/customer_repository.dart';

class RequestQuoteUseCase {
  final CustomerRepository repository;
  const RequestQuoteUseCase(this.repository);
  Future<Quote> call(QuoteRequest request) => repository.requestQuote(request);
}

class GetQuoteUseCase {
  final CustomerRepository repository;
  const GetQuoteUseCase(this.repository);
  Future<Quote> call(String id) => repository.getQuote(id);
}

class GetBookingUseCase {
  final CustomerRepository repository;
  const GetBookingUseCase(this.repository);
  Future<Booking> call(String id, {int? sessionGeneration}) =>
      repository.getBooking(id, sessionGeneration: sessionGeneration);
}

class PendingIntentConflict implements Exception {
  const PendingIntentConflict();
}

class CreateBookingUseCase {
  final CustomerRepository repository;
  final BookingIntentStore store;
  final ActiveBookingStore? confirmedStore;
  final String Function() newKey;
  final Map<String, (String, Future<Booking>)> _submissions = {};

  CreateBookingUseCase(this.repository, this.store,
      {this.confirmedStore, String Function()? newKey})
      : newKey = newKey ?? const Uuid().v4;

  Future<BookingIntent?> pendingFor(String customerPublicId) async {
    return store.read(customerPublicId);
  }

  Future<Booking> call(
      {required String customerPublicId,
      required String quotePublicId,
      int? sessionGeneration}) {
    final active = _submissions[customerPublicId];
    if (active != null) {
      if (active.$1 != quotePublicId) {
        return Future.error(const PendingIntentConflict());
      }
      return active.$2;
    }
    final submission =
        _submit(customerPublicId, quotePublicId, sessionGeneration)
            .whenComplete(() {
      _submissions.remove(customerPublicId);
    });
    _submissions[customerPublicId] = (quotePublicId, submission);
    return submission;
  }

  Future<Booking> _submit(String customerPublicId, String quotePublicId,
      int? sessionGeneration) async {
    var intent = await store.read(customerPublicId);
    if (intent != null && intent.quotePublicId != quotePublicId) {
      throw const PendingIntentConflict();
    }
    intent ??= BookingIntent(
        customerPublicId: customerPublicId,
        quotePublicId: quotePublicId,
        idempotencyKey: newKey());
    // Durable before the HTTP request. A timeout leaves the intent untouched.
    await store.write(intent);
    final booking = await repository.createBooking(
        intent.quotePublicId, intent.idempotencyKey,
        sessionGeneration: sessionGeneration);
    // Retain the idempotent intent until the confirmed Booking UUID has a
    // durable account-scoped navigation reference. A storage failure can be
    // retried with the same key, never by silently creating another Booking.
    if (confirmedStore != null) {
      await confirmedStore!.write(
          customerPublicId,
          ActiveBookingRecord(
              customerPublicId: customerPublicId,
              bookingPublicId: booking.publicId));
    }
    await store.clear(customerPublicId);
    return booking;
  }

  Future<void> abandon(String customerPublicId) async {
    if (_submissions.containsKey(customerPublicId)) {
      throw const PendingIntentConflict();
    }
    await store.clear(customerPublicId);
  }
}
