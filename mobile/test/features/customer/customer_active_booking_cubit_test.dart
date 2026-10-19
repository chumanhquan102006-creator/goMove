import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/active_booking_store.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/customer_repository.dart';
import 'package:gomove_mobile/features/customer/domain/usecases/customer_usecases.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/customer_active_booking_cubit.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';

const customerA = '550e8400-e29b-41d4-a716-446655440001';
const customerB = '550e8400-e29b-41d4-a716-446655440002';
const bookingA = '550e8400-e29b-41d4-a716-446655440006';
const bookingB = '550e8400-e29b-41d4-a716-446655440003';
const quoteId = '550e8400-e29b-41d4-a716-446655440004';

Booking serverBooking(String id, String status) => Booking(
      publicId: id,
      quotePublicId: quoteId,
      status: status,
      vehicleType: VehicleType.motorbike,
      currency: 'VND',
      finalFare: '16500',
      createdAt: DateTime.utc(2026, 10, 19),
    );

CashPayment cashPayment(String id, String status) => CashPayment(
      paymentPublicId: '550e8400-e29b-41d4-a716-446655440005',
      bookingPublicId: id,
      method: 'CASH',
      status: status,
      amount: '16500',
      currency: 'VND',
      paidAt: status == 'PAID' ? DateTime.utc(2026, 10, 19, 10) : null,
    );

class MemoryActiveBookingStore implements ActiveBookingStore {
  final records = <String, ActiveBookingRecord>{};
  int writes = 0;
  Object? clearError;

  @override
  Future<ActiveBookingRecord?> read(String customerPublicId) async =>
      records[customerPublicId];

  @override
  Future<void> write(
      String customerPublicId, ActiveBookingRecord record) async {
    expect(record.customerPublicId, customerPublicId);
    writes++;
    records[customerPublicId] = record;
  }

  @override
  Future<void> clear(String customerPublicId) async {
    if (clearError case final failure?) {
      throw failure;
    }
    records.remove(customerPublicId);
  }
}

class CustomerServer implements CustomerRepository {
  final bookings = <String, Booking>{};
  final errors = <String, Object>{};
  final held = <String, Completer<Booking>>{};
  final calls = <(String, int?)>[];
  final getStarted = <String, Completer<void>>{};

  @override
  Future<Booking> getBooking(String publicId, {int? sessionGeneration}) async {
    calls.add((publicId, sessionGeneration));
    getStarted[publicId]?.complete();
    if (errors[publicId] case final error?) {
      throw error;
    }
    if (held[publicId] case final pending?) {
      return pending.future;
    }
    return bookings[publicId]!;
  }

  @override
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey,
          {int? sessionGeneration}) =>
      throw UnimplementedError();

  @override
  Future<Quote> getQuote(String publicId) => throw UnimplementedError();

  @override
  Future<Quote> requestQuote(QuoteRequest request) =>
      throw UnimplementedError();
}

class PaymentServer implements TripRepository {
  final payments = <String, CashPayment>{};
  final calls = <(String, int)>[];
  Object? error;

  @override
  Future<CashPayment> payment(String bookingPublicId, int generation) async {
    calls.add((bookingPublicId, generation));
    if (error case final failure?) {
      throw failure;
    }
    return payments[bookingPublicId]!;
  }

  @override
  Future<TrackingSnapshot> tracking(String bookingPublicId, int generation) =>
      throw UnimplementedError();

  @override
  Future<TripTransition> transition(
          String bookingPublicId, TripAction action, int generation) =>
      throw UnimplementedError();

  @override
  Future<CashReceipt> confirmCash(String bookingPublicId, int generation) =>
      throw UnimplementedError();
}

class MutableSession implements SecureStorageService {
  int generation = 7;
  String? userPublicId = customerA;
  String? accessToken = 'A-access';
  String? refreshToken = 'A-refresh';

  void replaceWith(String customerPublicId) {
    generation++;
    userPublicId = customerPublicId;
    accessToken = '$customerPublicId-access';
    refreshToken = '$customerPublicId-refresh';
  }

  @override
  Future<AuthSessionSnapshot> getSession() async =>
      AuthSessionSnapshot(generation, accessToken, refreshToken);

  @override
  Future<bool> isCurrentSession(int value) async => generation == value;

  @override
  Future<String?> getUserPublicId() async => userPublicId;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> saveTokens(
      {required String accessToken,
      required String refreshToken,
      String? userPublicId}) async {
    generation++;
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.userPublicId = userPublicId;
  }

  @override
  Future<void> saveUserPublicId(String publicId) async {
    userPublicId = publicId;
  }

  @override
  Future<bool> saveUserPublicIdIfCurrent(int value, String publicId) async {
    if (generation != value) {
      return false;
    }
    userPublicId = publicId;
    return true;
  }

  @override
  Future<bool> rotateTokensIfCurrent(
      {required int generation,
      required String expectedRefreshToken,
      required String accessToken,
      required String refreshToken}) async {
    if (this.generation != generation ||
        this.refreshToken != expectedRefreshToken) {
      return false;
    }
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    return true;
  }

  @override
  Future<bool> clearIfCurrent(int value) async {
    if (generation != value) {
      return false;
    }
    await clearAll();
    return true;
  }

  @override
  Future<void> clearAll() async {
    generation++;
    userPublicId = null;
    accessToken = null;
    refreshToken = null;
  }
}

void main() {
  late MemoryActiveBookingStore store;
  late CustomerServer customerServer;
  late PaymentServer paymentServer;
  late MutableSession session;

  CustomerActiveBookingCubit newCubit([String customerPublicId = customerA]) =>
      CustomerActiveBookingCubit(GetBookingUseCase(customerServer),
          paymentServer, store, session, customerPublicId);

  setUp(() {
    store = MemoryActiveBookingStore();
    customerServer = CustomerServer()
      ..bookings[bookingA] = serverBooking(bookingA, 'DRIVER_ARRIVED')
      ..bookings[bookingB] = serverBooking(bookingB, 'IN_PROGRESS');
    paymentServer = PaymentServer()
      ..payments[bookingA] = cashPayment(bookingA, 'PENDING')
      ..payments[bookingB] = cashPayment(bookingB, 'PAID');
    session = MutableSession();
  });

  test(
      'Manual UUID recovery verifies owned GET before persisting and opens Arrived',
      () async {
    final cubit = newCubit();
    expect(store.records, isEmpty);
    await cubit.recoverByPublicId('  ${bookingA.toUpperCase()}  ');
    expect(customerServer.calls, [(bookingA, 7)]);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    expect(store.writes, 1);
    expect(cubit.state.booking?.status, 'DRIVER_ARRIVED');
    expect(cubit.state.isActive, isTrue);
    await cubit.close();
  });

  test('Restart restores only after another authorized server GET', () async {
    final first = newCubit();
    await first.recoverByPublicId(bookingA);
    await first.close();

    final afterRestart = newCubit();
    expect(afterRestart.state.booking, isNull);
    await afterRestart.restore();
    expect(customerServer.calls, [(bookingA, 7), (bookingA, 7)]);
    expect(store.writes, 1);
    expect(afterRestart.state.booking?.publicId, bookingA);
    expect(afterRestart.state.booking?.status, 'DRIVER_ARRIVED');
    await afterRestart.close();
  });

  test('Resume revalidates and restores IN_PROGRESS without another write',
      () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    final cubit = newCubit();
    await cubit.restore();
    customerServer.bookings[bookingA] = serverBooking(bookingA, 'IN_PROGRESS');
    await cubit.refresh();
    expect(customerServer.calls, [(bookingA, 7), (bookingA, 7)]);
    expect(store.writes, 0);
    expect(cubit.state.booking?.status, 'IN_PROGRESS');
    expect(cubit.state.isActive, isTrue);
    await cubit.close();
  });

  test('Invalid UUID never queries server or changes durable reference',
      () async {
    final cubit = newCubit();
    await cubit.recoverByPublicId('not-a-booking-uuid');
    expect(customerServer.calls, isEmpty);
    expect(store.records, isEmpty);
    expect(cubit.state.error, contains('UUID'));
    await cubit.close();
  });

  for (final status in [403, 404]) {
    test('Manual recovery HTTP $status is rejected and never persisted',
        () async {
      customerServer.errors[bookingA] =
          ServerException(message: 'denied', statusCode: status);
      final cubit = newCubit();
      await cubit.recoverByPublicId(bookingA);
      expect(customerServer.calls, [(bookingA, 7)]);
      expect(store.records, isEmpty);
      expect(store.writes, 0);
      expect(cubit.state.booking, isNull);
      expect(cubit.state.error, isNotNull);
      await cubit.close();
    });

    test('Saved Booking HTTP $status clears stale recovery reference',
        () async {
      store.records[customerA] = const ActiveBookingRecord(
          customerPublicId: customerA, bookingPublicId: bookingA);
      customerServer.errors[bookingA] =
          ServerException(message: 'no owned Booking', statusCode: status);
      final cubit = newCubit();
      await cubit.restore();
      expect(customerServer.calls, [(bookingA, 7)]);
      expect(store.records[customerA], isNull);
      expect(store.writes, 0);
      expect(cubit.state.booking, isNull);
      expect(cubit.state.error, isNotNull);
      await cubit.close();
    });
  }

  test('Manual recovery HTTP 401 ends old session without persisting',
      () async {
    customerServer.errors[bookingA] =
        const ServerException(message: 'unauthorized', statusCode: 401);
    final cubit = newCubit();
    await cubit.recoverByPublicId(bookingA);
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.booking, isNull);
    expect(store.records, isEmpty);
    await cubit.close();
  });

  test('Server response for a different UUID is rejected before persistence',
      () async {
    customerServer.bookings[bookingA] = serverBooking(bookingB, 'IN_PROGRESS');
    final cubit = newCubit();
    await cubit.recoverByPublicId(bookingA);
    expect(cubit.state.booking, isNull);
    expect(store.records, isEmpty);
    expect(cubit.state.error, isNotNull);
    await cubit.close();
  });

  test('COMPLETED with CASH PENDING remains an active recovery entry',
      () async {
    customerServer.bookings[bookingA] = serverBooking(bookingA, 'COMPLETED');
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    final cubit = newCubit();
    await cubit.restore();
    expect(paymentServer.calls, [(bookingA, 7)]);
    expect(cubit.state.booking?.status, 'COMPLETED');
    expect(cubit.state.payment?.status, 'PENDING');
    expect(cubit.state.isActive, isTrue);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    await cubit.close();
  });

  test('COMPLETED with CASH PAID shows actual result, not an active trip',
      () async {
    customerServer.bookings[bookingA] = serverBooking(bookingA, 'COMPLETED');
    paymentServer.payments[bookingA] = cashPayment(bookingA, 'PAID');
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    final cubit = newCubit();
    await cubit.restore();
    expect(cubit.state.booking?.status, 'COMPLETED');
    expect(cubit.state.payment?.status, 'PAID');
    expect(cubit.state.isActive, isFalse);
    expect(store.writes, 0);
    await cubit.close();
  });

  test('Manual PAID history does not replace an active saved Booking',
      () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    customerServer.bookings[bookingB] = serverBooking(bookingB, 'COMPLETED');
    final cubit = newCubit();

    await cubit.recoverByPublicId(bookingB);
    expect(customerServer.calls, [(bookingB, 7)]);
    expect(paymentServer.calls, [(bookingB, 7)]);
    expect(cubit.state.booking?.publicId, bookingB);
    expect(cubit.state.payment?.status, 'PAID');
    expect(cubit.state.isActive, isFalse);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    expect(store.writes, 0);

    await cubit.restore();
    expect(cubit.state.booking?.publicId, bookingA);
    expect(cubit.state.booking?.status, 'DRIVER_ARRIVED');
    expect(cubit.state.isActive, isTrue);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    await cubit.close();
  });

  test('Failed stale-reference delete ends loading and allows manual recovery',
      () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    store.clearError = StateError('secure storage delete failed');
    customerServer.errors[bookingA] =
        const ServerException(message: 'not found', statusCode: 404);
    final cubit = newCubit();

    await cubit.restore();
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.sessionEnded, isFalse);
    expect(cubit.state.booking, isNull);
    expect(cubit.state.error, contains('nhập UUID khác'));
    expect(store.records[customerA]?.bookingPublicId, bookingA);

    await cubit.recoverByPublicId(bookingB);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.booking?.publicId, bookingB);
    expect(cubit.state.isActive, isTrue);
    expect(store.records[customerA]?.bookingPublicId, bookingB);
    await cubit.close();
  });

  test('Unknown payment cannot silently mark COMPLETED as PAID', () async {
    customerServer.bookings[bookingA] = serverBooking(bookingA, 'COMPLETED');
    paymentServer.error = const NetworkException();
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    final cubit = newCubit();
    await cubit.restore();
    expect(cubit.state.booking?.status, 'COMPLETED');
    expect(cubit.state.payment, isNull);
    expect(cubit.state.isActive, isTrue);
    expect(cubit.state.error, isNotNull);
    await cubit.close();
  });

  test('Account switch cannot show A Booking in B recovery', () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    store.records[customerB] = const ActiveBookingRecord(
        customerPublicId: customerB, bookingPublicId: bookingB);
    final a = newCubit();
    await a.restore();
    expect(a.state.booking?.publicId, bookingA);

    session.replaceWith(customerB);
    await a.refresh();
    expect(a.state.sessionEnded, isTrue);
    expect(a.state.booking, isNull);

    final b = newCubit(customerB);
    await b.restore();
    expect(b.state.booking?.publicId, bookingB);
    expect(b.state.booking?.status, 'IN_PROGRESS');
    expect(customerServer.calls, [(bookingA, 7), (bookingB, 8)]);
    await a.close();
    await b.close();
  });

  test('Logout drops visible A detail before B signs in', () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    store.records[customerB] = const ActiveBookingRecord(
        customerPublicId: customerB, bookingPublicId: bookingB);
    final a = newCubit();
    await a.restore();
    expect(a.state.booking?.publicId, bookingA);

    await session.clearAll();
    await a.refresh();
    expect(a.state.sessionEnded, isTrue);
    expect(a.state.booking, isNull);

    session.replaceWith(customerB);
    final b = newCubit(customerB);
    await b.restore();
    expect(b.state.booking?.publicId, bookingB);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    expect(store.records[customerB]?.bookingPublicId, bookingB);
    await a.close();
    await b.close();
  });

  test('Late A GET after B login cannot repopulate A or overwrite B', () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    store.records[customerB] = const ActiveBookingRecord(
        customerPublicId: customerB, bookingPublicId: bookingB);
    customerServer.held[bookingA] = Completer<Booking>();
    customerServer.getStarted[bookingA] = Completer<void>();
    final a = newCubit();
    final aRestore = a.restore();
    await customerServer.getStarted[bookingA]!.future;

    session.replaceWith(customerB);
    final b = newCubit(customerB);
    await b.restore();
    expect(b.state.booking?.publicId, bookingB);
    customerServer.held[bookingA]!
        .complete(serverBooking(bookingA, 'DRIVER_ARRIVED'));
    await aRestore;
    expect(a.state.sessionEnded, isTrue);
    expect(a.state.booking, isNull);
    expect(b.state.booking?.publicId, bookingB);
    expect(store.records[customerB]?.bookingPublicId, bookingB);
    expect(store.writes, 0);
    await a.close();
    await b.close();
  });

  test('Late A GET denial cannot surface an old error in B session', () async {
    store.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingA);
    store.records[customerB] = const ActiveBookingRecord(
        customerPublicId: customerB, bookingPublicId: bookingB);
    customerServer.held[bookingA] = Completer<Booking>();
    customerServer.getStarted[bookingA] = Completer<void>();
    final a = newCubit();
    final aRestore = a.restore();
    await customerServer.getStarted[bookingA]!.future;

    session.replaceWith(customerB);
    final b = newCubit(customerB);
    await b.restore();
    customerServer.held[bookingA]!.completeError(
        const ServerException(message: 'A denied', statusCode: 403));
    await aRestore;
    expect(a.state.sessionEnded, isTrue);
    expect(a.state.booking, isNull);
    expect(a.state.error, isNot(contains('A denied')));
    expect(b.state.booking?.publicId, bookingB);
    expect(b.state.error, isNull);
    expect(store.records[customerA]?.bookingPublicId, bookingA);
    expect(store.records[customerB]?.bookingPublicId, bookingB);
    await a.close();
    await b.close();
  });
}
