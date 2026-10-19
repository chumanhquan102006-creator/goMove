import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/active_booking_store.dart';
import 'package:gomove_mobile/features/customer/data/booking_intent_store.dart';
import 'package:gomove_mobile/features/customer/data/models/customer_models.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking_intent.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/customer_repository.dart';
import 'package:gomove_mobile/features/customer/domain/usecases/customer_usecases.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_status_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/formatters.dart';
import 'package:mocktail/mocktail.dart';

const quoteId = '550e8400-e29b-41d4-a716-446655440001';
const otherQuoteId = '550e8400-e29b-41d4-a716-446655440005';
const bookingId = '550e8400-e29b-41d4-a716-446655440002';
const customerId = '550e8400-e29b-41d4-a716-446655440003';
const otherCustomerId = '550e8400-e29b-41d4-a716-446655440004';

Booking booking([String status = 'REQUESTED']) => Booking(
      publicId: bookingId,
      quotePublicId: quoteId,
      status: status,
      vehicleType: VehicleType.motorbike,
      currency: 'VND',
      finalFare: '16500',
      createdAt: DateTime.utc(2026, 10, 11),
    );

class MemoryIntentStore implements BookingIntentStore {
  final values = <String, BookingIntent>{};
  @override
  Future<BookingIntent?> read(String customerPublicId) async =>
      values[customerPublicId];
  @override
  Future<void> write(BookingIntent intent) async {
    values[intent.customerPublicId] = intent;
  }

  @override
  Future<void> clear(String customerPublicId) async {
    values.remove(customerPublicId);
  }
}

class MemoryActiveStore implements ActiveBookingStore {
  final values = <String, ActiveBookingRecord>{};
  bool failWrite = false;
  @override
  Future<ActiveBookingRecord?> read(String customerPublicId) async =>
      values[customerPublicId];
  @override
  Future<void> write(
      String customerPublicId, ActiveBookingRecord record) async {
    if (failWrite) throw StateError('secure store unavailable');
    values[customerPublicId] = record;
  }

  @override
  Future<void> clear(String customerPublicId) async {
    values.remove(customerPublicId);
  }
}

class FakeSession extends Mock implements SecureStorageService {}

class FakeCustomerRepository implements CustomerRepository {
  int createCalls = 0;
  int statusCalls = 0;
  final keys = <String>[];
  Object? createError;
  Completer<Booking>? createCompleter;
  final completionsByKey = <String, Completer<Booking>>{};
  Booking statusValue = booking();
  int? lastCreateGeneration;

  @override
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey,
      {int? sessionGeneration}) async {
    lastCreateGeneration = sessionGeneration;
    createCalls++;
    keys.add(idempotencyKey);
    if (createError != null) throw createError!;
    if (completionsByKey.containsKey(idempotencyKey)) {
      return completionsByKey[idempotencyKey]!.future;
    }
    if (createCompleter != null) return createCompleter!.future;
    return booking();
  }

  @override
  Future<Booking> getBooking(String publicId, {int? sessionGeneration}) async {
    statusCalls++;
    return statusValue;
  }

  @override
  Future<Quote> getQuote(String publicId) => throw UnimplementedError();
  @override
  Future<Quote> requestQuote(QuoteRequest request) =>
      throw UnimplementedError();
}

class UncertainIdempotentRepository extends FakeCustomerRepository {
  final bookingsByKey = <String, Booking>{};
  bool firstResponseLost = true;

  @override
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey,
      {int? sessionGeneration}) async {
    createCalls++;
    keys.add(idempotencyKey);
    final result = bookingsByKey.putIfAbsent(idempotencyKey, booking);
    if (firstResponseLost) {
      firstResponseLost = false;
      throw const NetworkException();
    }
    return result;
  }
}

void main() {
  test('Confirmed Booking UUID persists separately from pending intent',
      () async {
    final repository = FakeCustomerRepository();
    final intents = MemoryIntentStore();
    final active = MemoryActiveStore();
    final useCase = CreateBookingUseCase(repository, intents,
        confirmedStore: active, newKey: () => 'booking-key');

    final result = await useCase(
        customerPublicId: customerId,
        quotePublicId: quoteId,
        sessionGeneration: 7);

    expect(result.publicId, bookingId);
    expect(active.values[customerId]?.bookingPublicId, bookingId);
    expect(intents.values[customerId], isNull);
    expect(repository.lastCreateGeneration, 7);
  });

  test('Confirmed-reference write failure keeps original idempotency key',
      () async {
    final repository = FakeCustomerRepository();
    final intents = MemoryIntentStore();
    final active = MemoryActiveStore()..failWrite = true;
    final useCase = CreateBookingUseCase(repository, intents,
        confirmedStore: active, newKey: () => 'original-key');

    await expectLater(
        useCase(customerPublicId: customerId, quotePublicId: quoteId),
        throwsStateError);
    expect(intents.values[customerId]?.idempotencyKey, 'original-key');
    active.failWrite = false;
    final result =
        await useCase(customerPublicId: customerId, quotePublicId: quoteId);
    expect(result.publicId, bookingId);
    expect(repository.keys, ['original-key', 'original-key']);
    expect(active.values[customerId]?.bookingPublicId, bookingId);
    expect(intents.values[customerId], isNull);
  });

  test('Late A Booking response cannot enter B session UI or B reference',
      () async {
    final repository = FakeCustomerRepository()
      ..createCompleter = Completer<Booking>();
    final intents = MemoryIntentStore();
    final active = MemoryActiveStore();
    final session = FakeSession();
    var generation = 1;
    var owner = customerId;
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    final useCase = CreateBookingUseCase(repository, intents,
        confirmedStore: active, newKey: () => 'original-key');
    final cubit = BookingCubit(useCase, customerId, session: session);

    final pending = cubit.submit(quoteId);
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = otherCustomerId;
    repository.createCompleter!.complete(booking());
    await pending;

    expect(cubit.state.booking, isNull);
    expect(active.values[otherCustomerId], isNull);
    await cubit.close();
  });

  test('Quote serializes coordinates and vehicle; invalid coordinates rejected',
      () {
    const request = QuoteRequest(
        pickup: Coordinates(21.0287, 105.8524),
        dropoff: Coordinates(21.0245, 105.8576),
        vehicleType: VehicleType.motorbike);
    expect(request.toJson(), {
      'pickupLatitude': 21.0287,
      'pickupLongitude': 105.8524,
      'dropoffLatitude': 21.0245,
      'dropoffLongitude': 105.8576,
      'vehicleType': 'MOTORBIKE'
    });
    expect(
        () => const QuoteRequest(
                pickup: Coordinates(100, 0),
                dropoff: Coordinates(1, 1),
                vehicleType: VehicleType.car4Seat)
            .toJson(),
        throwsFormatException);
  });

  test('Quote parses every server fare line and strictly expires at expiresAt',
      () {
    final quote = CustomerModels.quote({
      'quotePublicId': quoteId,
      'pickup': {'latitude': 21.0287, 'longitude': 105.8524},
      'dropoff': {'latitude': 21.0245, 'longitude': 105.8576},
      'vehicleType': 'MOTORBIKE',
      'distanceMeters': 1000.111,
      'durationSeconds': 300,
      'currency': 'VND',
      'baseFare': 12000,
      'distanceFare': 4500.5,
      'timeFare': 0,
      'surcharge': 0,
      'surgeAmount': 0,
      'discountAmount': 0,
      'roundingAdjustment': -0.5,
      'finalFare': 16500,
      'status': 'ISSUED',
      'issuedAt': '2026-10-11T00:00:00Z',
      'expiresAt': '2026-10-11T00:01:00Z',
    });
    expect(quote.roundingAdjustment, '-0.5');
    expect(quote.finalFare, '16500');
    expect(quote.isUsableAt(DateTime.utc(2026, 10, 11, 0, 0, 59)), isTrue);
    expect(quote.isUsableAt(DateTime.utc(2026, 10, 11, 0, 1)), isFalse);
    expect(vnd(quote.finalFare), '16.500 VND');
    expect(vnd(quote.roundingAdjustment), '-0,5 VND');
  });

  test('Double submit shares one in-flight request and one UUID key', () async {
    final repository = FakeCustomerRepository()
      ..createCompleter = Completer<Booking>();
    final store = MemoryIntentStore();
    var generated = 0;
    final useCase = CreateBookingUseCase(repository, store, newKey: () {
      generated++;
      return 'uuid-v4-key';
    });
    final first = useCase(customerPublicId: customerId, quotePublicId: quoteId);
    final second =
        useCase(customerPublicId: customerId, quotePublicId: quoteId);
    await Future<void>.delayed(Duration.zero);
    expect(repository.createCalls, 1);
    expect(generated, 1);
    expect(store.values[customerId]?.idempotencyKey, 'uuid-v4-key');
    repository.createCompleter!.complete(booking());
    expect((await first).publicId, bookingId);
    expect((await second).publicId, bookingId);
    expect(store.values[customerId], isNull);
  });

  test(
      'Network uncertainty survives restart; 503 retries same key; 409 retains intent',
      () async {
    final repository = FakeCustomerRepository()
      ..createError = const NetworkException();
    final store = MemoryIntentStore();
    final first =
        CreateBookingUseCase(repository, store, newKey: () => 'same-key');
    await expectLater(
        first(customerPublicId: customerId, quotePublicId: quoteId),
        throwsA(isA<NetworkException>()));
    expect(store.values[customerId]?.idempotencyKey, 'same-key');

    repository.createError =
        const ServerException(message: 'busy', statusCode: 503);
    final afterRestart =
        CreateBookingUseCase(repository, store, newKey: () => 'wrong-new-key');
    await expectLater(
        afterRestart(customerPublicId: customerId, quotePublicId: quoteId),
        throwsA(isA<ServerException>()));
    expect(repository.keys, ['same-key', 'same-key']);

    repository.createError =
        const ServerException(message: 'conflict', statusCode: 409);
    await expectLater(
        afterRestart(customerPublicId: customerId, quotePublicId: quoteId),
        throwsA(isA<ServerException>()));
    expect(store.values[customerId]?.idempotencyKey, 'same-key');
    await expectLater(
        afterRestart(
            customerPublicId: customerId, quotePublicId: 'another-quote'),
        throwsA(isA<PendingIntentConflict>()));
    await afterRestart.abandon(customerId);
    expect(store.values[customerId], isNull);
  });

  test('Same Quote UUID is isolated by account, including in-flight results',
      () async {
    final repository = FakeCustomerRepository();
    final store = MemoryIntentStore();
    final aCompletion = Completer<Booking>();
    final bCompletion = Completer<Booking>();
    repository.completionsByKey.addAll({
      'key-a': aCompletion,
      'key-b': bCompletion,
    });
    var next = 0;
    final useCase = CreateBookingUseCase(repository, store,
        newKey: () => ['key-a', 'key-b'][next++]);

    final a = useCase(customerPublicId: customerId, quotePublicId: quoteId);
    final b =
        useCase(customerPublicId: otherCustomerId, quotePublicId: quoteId);
    expect(identical(a, b), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(repository.createCalls, 2);
    expect(store.values[customerId]?.idempotencyKey, 'key-a');
    expect(store.values[otherCustomerId]?.idempotencyKey, 'key-b');

    final bBooking = Booking(
        publicId: 'booking-b',
        quotePublicId: quoteId,
        status: 'SEARCHING_DRIVER',
        vehicleType: VehicleType.motorbike,
        currency: 'VND',
        finalFare: '16500',
        createdAt: DateTime.utc(2026, 10, 11));
    bCompletion.complete(bBooking);
    expect((await b).publicId, 'booking-b');
    expect(store.values[otherCustomerId], isNull);
    expect(store.values[customerId]?.idempotencyKey, 'key-a');
    aCompletion.complete(booking());
    expect((await a).publicId, bookingId);
    expect(store.values[customerId], isNull);
  });

  test('Logout and account switch preserve A intent; restart retries A key',
      () async {
    final repository = FakeCustomerRepository()
      ..createError = const NetworkException();
    final store = MemoryIntentStore();
    var next = 0;
    final first = CreateBookingUseCase(repository, store,
        newKey: () => ['key-a', 'key-b'][next++]);
    await expectLater(
        first(customerPublicId: customerId, quotePublicId: quoteId),
        throwsA(isA<NetworkException>()));
    expect(store.values[customerId]?.idempotencyKey, 'key-a');

    // A logs out. Auth storage cleanup does not own or clear Booking intents.
    await expectLater(first.abandon(otherCustomerId), completes);
    repository.createError = null;
    await first(customerPublicId: otherCustomerId, quotePublicId: otherQuoteId);
    expect(repository.keys, ['key-a', 'key-b']);
    expect(store.values[customerId]?.idempotencyKey, 'key-a');

    final afterRestart = CreateBookingUseCase(repository, store,
        newKey: () => throw StateError('A key must be reused'));
    expect(
        (await afterRestart.pendingFor(customerId))?.idempotencyKey, 'key-a');
    await afterRestart(customerPublicId: customerId, quotePublicId: quoteId);
    expect(repository.keys, ['key-a', 'key-b', 'key-a']);
    expect(store.values[customerId], isNull);
  });

  test('Lost response retries original key and yields one backend Booking',
      () async {
    final repository = UncertainIdempotentRepository();
    final store = MemoryIntentStore();
    final first =
        CreateBookingUseCase(repository, store, newKey: () => 'original-key');
    await expectLater(
        first(customerPublicId: customerId, quotePublicId: quoteId),
        throwsA(isA<NetworkException>()));
    expect(store.values[customerId]?.idempotencyKey, 'original-key');

    final afterRestart = CreateBookingUseCase(repository, store,
        newKey: () => throw StateError('Must not generate a new key'));
    final recovered = await afterRestart(
        customerPublicId: customerId, quotePublicId: quoteId);
    expect(recovered.publicId, bookingId);
    expect(repository.keys, ['original-key', 'original-key']);
    expect(repository.bookingsByKey.length, 1);
    expect(store.values[customerId], isNull);
  });

  test('A late result cannot update B account cubit', () async {
    final repository = FakeCustomerRepository();
    final store = MemoryIntentStore();
    final aCompletion = Completer<Booking>();
    final bCompletion = Completer<Booking>();
    repository.completionsByKey.addAll({
      'key-a': aCompletion,
      'key-b': bCompletion,
    });
    var next = 0;
    final useCase = CreateBookingUseCase(repository, store,
        newKey: () => ['key-a', 'key-b'][next++]);
    final aCubit = BookingCubit(useCase, customerId);
    final aSubmit = aCubit.submit(quoteId);
    await Future<void>.delayed(Duration.zero);
    await aCubit.close();

    final bCubit = BookingCubit(useCase, otherCustomerId);
    final bSubmit = bCubit.submit(quoteId);
    await Future<void>.delayed(Duration.zero);
    aCompletion.complete(booking());
    await aSubmit;
    expect(bCubit.state.loading, isTrue);
    expect(bCubit.state.booking, isNull);
    bCompletion.complete(booking('SEARCHING_DRIVER'));
    await bSubmit;
    expect(bCubit.state.booking?.status, 'SEARCHING_DRIVER');
    await bCubit.close();
  });

  testWidgets('Booking status polls only while visible and stops at COMPLETED',
      (tester) async {
    final repository = FakeCustomerRepository();
    final cubit = BookingStatusCubit(GetBookingUseCase(repository), booking());
    cubit.start();
    cubit.start();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(repository.statusCalls, 1);
    repository.statusValue = booking('COMPLETED');
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(cubit.state.booking.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(repository.statusCalls, 2);
    await cubit.close();
  });

  testWidgets('Disposing active status screen cancels polling', (tester) async {
    final repository = FakeCustomerRepository();
    final cubit = BookingStatusCubit(GetBookingUseCase(repository), booking());
    cubit.start();
    await cubit.close();
    await tester.pump(const Duration(seconds: 10));
    expect(repository.statusCalls, 0);
  });
}
