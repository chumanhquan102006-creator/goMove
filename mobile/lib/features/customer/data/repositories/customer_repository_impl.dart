import 'package:dio/dio.dart';
import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/customer_repository.dart';
import '../models/customer_models.dart';

class CustomerRepositoryImpl implements CustomerRepository {
  final ApiClient _client;
  CustomerRepositoryImpl(this._client);

  @override
  Future<Quote> requestQuote(QuoteRequest request) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.quotes,
        data: request.toJson());
    return CustomerModels.quote(CustomerModels.payload(response.data));
  }

  @override
  Future<Quote> getQuote(String publicId) async {
    final response =
        await _client.get<Map<String, dynamic>>(ApiEndpoints.quote(publicId));
    return CustomerModels.quote(CustomerModels.payload(response.data));
  }

  @override
  Future<Booking> createBooking(
      String quotePublicId, String idempotencyKey) async {
    final response = await _client.post<Map<String, dynamic>>(
      ApiEndpoints.bookings,
      data: {'quotePublicId': quotePublicId},
      options: Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    return CustomerModels.booking(CustomerModels.payload(response.data));
  }

  @override
  Future<Booking> getBooking(String publicId) async {
    final response =
        await _client.get<Map<String, dynamic>>(ApiEndpoints.booking(publicId));
    return CustomerModels.booking(CustomerModels.payload(response.data));
  }
}
