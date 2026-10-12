import '../models/booking.dart';
import '../models/quote.dart';

abstract class CustomerRepository {
  Future<Quote> requestQuote(QuoteRequest request);
  Future<Quote> getQuote(String publicId);
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey);
  Future<Booking> getBooking(String publicId);
}
