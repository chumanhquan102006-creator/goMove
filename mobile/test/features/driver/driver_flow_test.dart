import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/driver/data/accepted_booking_store.dart';
import 'package:gomove_mobile/features/driver/data/location/driver_location_source.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/driver/domain/repositories/driver_repository.dart';
import 'package:gomove_mobile/features/driver/domain/usecases/driver_usecases.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/onboarding_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_home_screen.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_accepted_booking_screen.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockSession extends Mock implements SecureStorageService {}

class MockTripRepository extends Mock implements TripRepository {}

class MemoryAcceptedStore implements AcceptedBookingStore {
  final values = <String, AcceptedBookingRecord>{};
  @override
  Future<AcceptedBookingRecord?> read(String userPublicId) async =>
      values[userPublicId];
  @override
  Future<void> write(String userPublicId, AcceptedBookingRecord record) async {
    values[userPublicId] = record;
  }

  @override
  Future<void> clear(String userPublicId) async {
    values.remove(userPublicId);
  }
}

class FakeLocation implements DriverLocationSource {
  DriverCoordinates point =
      const DriverCoordinates(21.0287, 105.8524, accuracy: 8, bearing: 0);
  DriverLocationProblem? problem;
  Future<DriverCoordinates> Function()? currentResponse;
  int calls = 0;
  @override
  Future<DriverCoordinates> current() async {
    calls++;
    if (problem != null) throw DriverLocationException(problem!);
    if (currentResponse != null) return await currentResponse!();
    return point;
  }

  @override
  Future<void> openSettings(DriverLocationProblem? problem) async {}
}

class FakeDeviceProvider implements DeviceLocationProvider {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requested = LocationPermission.whileInUse;
  int requestCalls = 0;
  int positionCalls = 0;
  int appSettingsCalls = 0;
  int locationSettingsCalls = 0;
  DriverCoordinates point =
      const DriverCoordinates(21.0287, 105.8524, approximate: true);
  @override
  Future<bool> servicesEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requestCalls++;
    return requested;
  }

  @override
  Future<DriverCoordinates> currentCoordinates() async {
    positionCalls++;
    return point;
  }

  @override
  Future<void> openAppSettings() async {
    appSettingsCalls++;
  }

  @override
  Future<void> openLocationSettings() async {
    locationSettingsCalls++;
  }
}

class FakeDriverRepository implements DriverRepository {
  int onboardCalls = 0;
  int offerCalls = 0;
  int acceptCalls = 0;
  int rejectCalls = 0;
  int gpsCalls = 0;
  int statusCalls = 0;
  int vehicleCalls = 0;
  int addCalls = 0;
  int trackingCalls = 0;
  String? lastStatus;
  DriverCoordinates? lastPoint;
  Object? statusError;
  Object? acceptError;
  Future<DriverProfile> Function()? onboardResponse;
  Future<List<DriverOffer>> Function()? offerResponse;
  Future<OfferDecision> Function()? acceptResponse;
  Future<void> Function()? addDelay;
  BookingTracking trackingValue =
      const BookingTracking('booking-1', 'REQUESTED', null);
  List<DriverOffer> offers = [];
  List<DriverVehicle> vehicleList = [
    const DriverVehicle(
        'vehicle-1', '79A-123.45', 'MOTORBIKE', 'Honda', 'Wave', 'Black', true)
  ];

  @override
  Future<DriverProfile> onboard(String licenseNumber, int session) async {
    onboardCalls++;
    if (onboardResponse != null) return await onboardResponse!();
    return const DriverProfile('driver-1', 'PENDING', 'OFFLINE');
  }

  @override
  Future<DriverProfile> setStatus(String status, int session) async {
    statusCalls++;
    lastStatus = status;
    if (statusError != null) throw statusError!;
    return DriverProfile('driver-1', 'APPROVED', status);
  }

  @override
  Future<List<DriverVehicle>> vehicles(int session) async {
    vehicleCalls++;
    return vehicleList;
  }

  @override
  Future<DriverVehicle> addVehicle(VehicleDraft draft, int session) async {
    addCalls++;
    if (addDelay != null) await addDelay!();
    final vehicle = DriverVehicle('vehicle-2', draft.licensePlate,
        draft.vehicleType, draft.brand, draft.model, draft.color, false);
    vehicleList = [...vehicleList, vehicle];
    return vehicle;
  }

  @override
  Future<DriverVehicle> activateVehicle(String publicId, int session) async {
    vehicleList = [
      for (final vehicle in vehicleList)
        DriverVehicle(
            vehicle.publicId,
            vehicle.licensePlate,
            vehicle.vehicleType,
            vehicle.brand,
            vehicle.model,
            vehicle.color,
            vehicle.publicId == publicId)
    ];
    return vehicleList.firstWhere((vehicle) => vehicle.publicId == publicId);
  }

  @override
  Future<void> uploadLocation(DriverCoordinates location, int session) async {
    gpsCalls++;
    lastPoint = location;
  }

  @override
  Future<List<DriverOffer>> activeOffers(int session) async {
    offerCalls++;
    if (offerResponse != null) return await offerResponse!();
    return offers;
  }

  @override
  Future<OfferDecision> accept(String offerPublicId, int session) async {
    acceptCalls++;
    if (acceptError != null) throw acceptError!;
    if (acceptResponse != null) return await acceptResponse!();
    return OfferDecision(offerPublicId, 'ACCEPTED');
  }

  @override
  Future<OfferDecision> reject(String offerPublicId, int session) async {
    rejectCalls++;
    return OfferDecision(offerPublicId, 'REJECTED');
  }

  @override
  Future<BookingTracking> tracking(String bookingPublicId, int session) async {
    trackingCalls++;
    return trackingValue;
  }
}

class PreviewDriverCubit extends DriverCubit {
  final DriverState preview;
  PreviewDriverCubit(
      this.preview,
      DriverUseCases useCases,
      DriverLocationSource location,
      SecureStorageService session,
      AcceptedBookingStore store)
      : super(
            useCases: useCases,
            location: location,
            session: session,
            acceptedStore: store,
            userPublicId: 'user-A',
            isMock: false);
  @override
  Future<void> initialize() async {
    emit(preview);
  }
}

DriverOffer offer(DateTime expiry) => DriverOffer(
      offerPublicId: 'offer-1',
      bookingPublicId: 'booking-1',
      pickupLatitude: 21.0287,
      pickupLongitude: 105.8524,
      dropoffLatitude: 21.0245,
      dropoffLongitude: 105.8576,
      vehicleType: 'MOTORBIKE',
      currency: 'VND',
      finalFare: '16500',
      expiresAt: expiry,
    );

void main() {
  late FakeDriverRepository repository;
  late FakeLocation location;
  late MockSession session;
  late MemoryAcceptedStore store;
  late DateTime now;
  late int generation;
  late DriverCubit cubit;

  setUp(() {
    repository = FakeDriverRepository();
    location = FakeLocation();
    session = MockSession();
    store = MemoryAcceptedStore();
    now = DateTime.utc(2026, 10, 12, 12);
    generation = 1;
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        userPublicId: 'user-A',
        isMock: false,
        now: () => now,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1));
  });

  tearDown(() async => cubit.close());

  test('GPS validates order, bounds and optional accuracy/bearing', () {
    expect(
        const DriverCoordinates(21.0287, 105.8524, accuracy: 8, bearing: 0)
            .toJson(),
        {
          'latitude': 21.0287,
          'longitude': 105.8524,
          'accuracy': 8.0,
          'bearing': 0.0,
        });
    expect(
        const DriverCoordinates(21, 105, accuracy: double.nan, bearing: 360)
            .toJson()['bearing'],
        isNull);
    expect(
        () => const DriverCoordinates(105, 21).toJson(), throwsFormatException);
  });

  test('Location source follows service, runtime permission and settings flow',
      () async {
    final provider = FakeDeviceProvider();
    final source = GeolocatorDriverLocationSource(provider: provider);
    provider.enabled = false;
    await expectLater(
        source.current(), throwsA(isA<DriverLocationException>()));
    expect(provider.positionCalls, 0);
    await source.openSettings(DriverLocationProblem.disabled);
    expect(provider.locationSettingsCalls, 1);

    provider.enabled = true;
    provider.permission = LocationPermission.denied;
    provider.requested = LocationPermission.denied;
    await expectLater(
        source.current(), throwsA(isA<DriverLocationException>()));
    expect(provider.requestCalls, 1);
    provider.requested = LocationPermission.deniedForever;
    await expectLater(
        source.current(), throwsA(isA<DriverLocationException>()));
    await source.openSettings(DriverLocationProblem.deniedForever);
    expect(provider.appSettingsCalls, 1);
    expect(provider.positionCalls, 0);

    provider.requested = LocationPermission.whileInUse;
    final point = await source.current();
    expect(point.approximate, isTrue);
    expect(provider.positionCalls, 1);
    provider.permission = LocationPermission.unableToDetermine;
    provider.requested = LocationPermission.denied;
    await expectLater(
        source.current(), throwsA(isA<DriverLocationException>()));
    expect(provider.positionCalls, 1);
  });

  test('Onboarding is single-submit, pending and ignores old session response',
      () async {
    final pending = Completer<DriverProfile>();
    repository.onboardResponse = () => pending.future;
    final onboarding = OnboardingCubit(DriverUseCases(repository), session);
    final first = onboarding.submit('79A1-123456');
    await Future<void>.delayed(Duration.zero);
    await onboarding.submit('79A1-123456');
    expect(repository.onboardCalls, 1);
    generation = 2;
    pending.complete(const DriverProfile('driver-1', 'PENDING', 'OFFLINE'));
    await first;
    expect(onboarding.state.submitted, isFalse);
    await onboarding.close();
  });

  test(
      'Onboarding success requires a new login; uncertain result cannot be resent',
      () async {
    final onboarding = OnboardingCubit(DriverUseCases(repository), session);
    await onboarding.submit('79A1-123456');
    expect(onboarding.state.submitted, isTrue);
    expect(generation, 1); // Onboarding does not silently change the JWT role.
    await onboarding.submit('79A1-123456');
    expect(repository.onboardCalls, 1);
    await onboarding.close();

    repository.onboardResponse = () async => throw const NetworkException();
    final uncertain = OnboardingCubit(DriverUseCases(repository), session);
    await uncertain.submit('79A1-123456');
    expect(uncertain.state.uncertain, isTrue);
    await uncertain.submit('79A1-123456');
    expect(repository.onboardCalls, 2);
    await uncertain.close();
  });

  test('Vehicle list, creation and activation use server state', () async {
    await cubit.initialize();
    expect(cubit.state.activeVehicle?.publicId, 'vehicle-1');
    await cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    expect(cubit.state.vehicles.length, 2);
    await cubit.activateVehicle('vehicle-2');
    expect(cubit.state.activeVehicle?.publicId, 'vehicle-2');
  });

  test('Rapid repeated vehicle submission sends only one POST', () async {
    final pending = Completer<void>();
    repository.addDelay = () => pending.future;
    await cubit.initialize();
    final first =
        cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    await cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    expect(repository.addCalls, 1);
    pending.complete();
    await first;
    expect(cubit.state.vehicles.length, 2);
  });

  test('Approval and vehicle errors never fabricate ONLINE', () async {
    await cubit.initialize();
    repository.statusError = const ServerException(
        message: 'not approved',
        statusCode: 400,
        errorCode: 'DRIVER_NOT_APPROVED');
    await cubit.goOnline();
    expect(cubit.state.operatingStatus, isNull);
    expect(cubit.state.error, contains('Admin'));
    repository.statusError = const ServerException(
        message: 'vehicle required',
        statusCode: 400,
        errorCode: 'ACTIVE_VEHICLE_REQUIRED');
    await cubit.goOnline();
    expect(cubit.state.error, contains('kích hoạt'));
    expect(repository.gpsCalls, 0);
  });

  test('ONLINE uploads actual GPS then polls; pause and OFFLINE stop activity',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    expect(repository.lastStatus, 'ONLINE');
    expect(repository.lastPoint?.latitude, 21.0287);
    expect(repository.lastPoint?.longitude, 105.8524);
    expect(repository.gpsCalls, 1);
    expect(repository.offerCalls, 1);
    cubit.pause();
    await cubit.pollOnce();
    expect(repository.offerCalls, 1);
    await cubit.resume();
    expect(repository.offerCalls, 2);
    await cubit.goOffline();
    await cubit.pollOnce();
    expect(repository.lastStatus, 'OFFLINE');
    expect(repository.offerCalls, 2);
  });

  test('Denied, permanently denied and disabled GPS stop eligibility',
      () async {
    await cubit.initialize();
    for (final problem in DriverLocationProblem.values) {
      location.problem = problem;
      await cubit.goOnline();
      expect(cubit.state.locationProblem, problem);
      expect(repository.offerCalls, 0);
      await cubit.goOffline();
    }
  });

  test('Stale GPS prevents offer polling', () async {
    await cubit.initialize();
    await cubit.goOnline();
    now = now.add(const Duration(seconds: 30));
    await cubit.pollOnce();
    expect(repository.offerCalls, 1);
    expect(cubit.state.locationMessage, contains('30 giây'));
  });

  test('Only one offer poll in flight, and old account response is ignored',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final pending = Completer<List<DriverOffer>>();
    repository.offerResponse = () => pending.future;
    final first = cubit.pollOnce();
    await Future<void>.delayed(Duration.zero);
    await cubit.pollOnce();
    expect(repository.offerCalls, 2); // one initial + one pending
    generation = 2;
    pending.complete([offer(now.add(const Duration(seconds: 15)))]);
    await first;
    expect(cubit.state.offer, isNull);
    await cubit.pollOnce();
    expect(repository.offerCalls, 2);
  });

  test('A poll started before Reject cannot resurrect that offer', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    final pending = Completer<List<DriverOffer>>();
    repository.offerResponse = () => pending.future;
    final poll = cubit.pollOnce();
    await Future<void>.delayed(Duration.zero);
    await cubit.decide(false);
    expect(cubit.state.offer, isNull);
    pending.complete([offer(now.add(const Duration(seconds: 15)))]);
    await poll;
    expect(cubit.state.offer, isNull);
  });

  test('Paused foreground timers issue no further polls or GPS uploads',
      () async {
    await cubit.close();
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        userPublicId: 'user-A',
        isMock: false,
        now: () => now,
        pollInterval: const Duration(milliseconds: 15),
        heartbeatInterval: const Duration(milliseconds: 15));
    await cubit.initialize();
    await cubit.goOnline();
    // Under full-suite parallel load, a fixed 75 ms sleep may elapse before
    // both timers get their second turn. Wait for the observable condition.
    for (var i = 0;
        i < 20 && (repository.gpsCalls <= 1 || repository.offerCalls <= 1);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(repository.gpsCalls, greaterThan(1));
    expect(repository.offerCalls, greaterThan(1));
    cubit.pause();
    final polls = repository.offerCalls;
    final uploads = repository.gpsCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repository.offerCalls, polls);
    expect(repository.gpsCalls, uploads);
  });

  test('Pausing during GPS acquisition prevents its delayed upload', () async {
    final pending = Completer<DriverCoordinates>();
    location.currentResponse = () => pending.future;
    await cubit.initialize();
    final online = cubit.goOnline();
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    pending.complete(const DriverCoordinates(21.0287, 105.8524));
    await online;
    expect(repository.gpsCalls, 0);
    expect(repository.offerCalls, 0);
  });

  test('Strict expiry disables decision without calling Backend', () async {
    expect(
        remainingOfferSeconds(now.add(const Duration(seconds: 15)), now), 15);
    expect(remainingOfferSeconds(now, now), 0);
    expect(remainingOfferSeconds(now, now.add(const Duration(microseconds: 1))),
        0);
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    expect(cubit.state.offer?.offerPublicId, 'offer-1');
    now = now.add(const Duration(seconds: 15));
    await cubit.decide(true);
    expect(repository.acceptCalls, 0);
    expect(cubit.state.operatingStatus, 'ONLINE');
  });

  test('Only the first active offer is actionable', () async {
    repository.offers = [
      offer(now.add(const Duration(seconds: 15))),
      DriverOffer(
          offerPublicId: 'offer-2',
          bookingPublicId: 'booking-2',
          pickupLatitude: 21,
          pickupLongitude: 105,
          dropoffLatitude: 21.1,
          dropoffLongitude: 105.1,
          vehicleType: 'MOTORBIKE',
          currency: 'VND',
          finalFare: '17000',
          expiresAt: now.add(const Duration(seconds: 15)))
    ];
    await cubit.initialize();
    await cubit.goOnline();
    expect(cubit.state.offer?.offerPublicId, 'offer-1');
    await cubit.decide(true);
    expect(repository.acceptCalls, 1);
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
  });

  test('Accept sends once, confirms BUSY and preserves Booking handoff',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    final pending = Completer<OfferDecision>();
    repository.acceptResponse = () => pending.future;
    await cubit.initialize();
    await cubit.goOnline();
    final first = cubit.decide(true);
    await cubit.decide(true);
    expect(repository.acceptCalls, 1);
    pending.complete(const OfferDecision('offer-1', 'ACCEPTED'));
    await first;
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(store.values['user-A']?.offer.bookingPublicId, 'booking-1');
    final polls = repository.offerCalls;
    await cubit.pollOnce();
    expect(repository.offerCalls, polls);
    await cubit.goOffline();
    expect(repository.statusCalls, 1); // BUSY is system-managed.
  });

  test('Reject dismisses offer and continues ONLINE polling', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.offers = [];
    await cubit.decide(false);
    expect(repository.rejectCalls, 1);
    expect(cubit.state.offer, isNull);
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(repository.offerCalls, 2);
  });

  test('409 conflict never shows accepted Booking', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.offers = [];
    repository.acceptError =
        const ServerException(message: 'expired', statusCode: 409);
    await cubit.decide(true);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, contains('hết hạn'));
  });

  test('Lost accept response reconciles only matching server assignment',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.acceptError = const NetworkException();
    repository.trackingValue =
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1');
    await cubit.decide(true);
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(repository.acceptCalls, 1);
  });

  test('Lost accept response reconciles completed trip without GPS', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    final uploadsBeforeDecision = repository.gpsCalls;
    repository.acceptError = const NetworkException();
    repository.trackingValue =
        const BookingTracking('booking-1', 'COMPLETED', 'driver-1');

    await cubit.decide(true);

    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(cubit.state.completedAwaitingSettlement, isTrue);
    expect(store.values['user-A'], isNotNull);
    expect(repository.gpsCalls, uploadsBeforeDecision);
    cubit.pause();
    await cubit.resume();
    expect(repository.gpsCalls, uploadsBeforeDecision);
  });

  test('503 with unmatched tracking stays unresolved and never retries',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.acceptError =
        const ServerException(message: 'unavailable', statusCode: 503);
    repository.trackingValue =
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'another-driver');
    await cubit.decide(true);
    expect(cubit.state.unresolvedDecision, isTrue);
    expect(cubit.state.acceptedOffer, isNull);
    await cubit.decide(true);
    expect(repository.acceptCalls, 1);
  });

  test('Old Driver acceptance cannot mutate new session UI', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    final pending = Completer<OfferDecision>();
    repository.acceptResponse = () => pending.future;
    final first = cubit.decide(true);
    generation = 2;
    pending.complete(const OfferDecision('offer-1', 'ACCEPTED'));
    await first;
    expect(cubit.state.acceptedOffer, isNull);
    expect(store.values['user-A'], isNull);
  });

  test('Stored assignment is scoped to Driver account and revalidated',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1');
    await cubit.initialize();
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    await cubit.close();
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        userPublicId: 'user-B',
        isMock: false,
        now: () => now,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1));
    await cubit.initialize();
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, isNull);
  });

  test('COMPLETED with CASH PENDING keeps account-scoped handoff and BUSY',
      () async {
    final trip = MockTripRepository();
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'COMPLETED', 'driver-1');
    when(() => trip.payment('booking-1', 1)).thenAnswer((_) async =>
        const CashPayment(
            paymentPublicId: 'payment-1',
            bookingPublicId: 'booking-1',
            method: 'CASH',
            status: 'PENDING',
            amount: '16500.00',
            currency: 'VND'));
    await cubit.close();
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        tripRepository: trip,
        userPublicId: 'user-A',
        isMock: false,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1));
    await cubit.initialize();
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.completedAwaitingSettlement, isTrue);
    expect(store.values['user-A'], isNotNull);
    expect(repository.gpsCalls, 0);
  });

  test('only verified receipt finishes saved handoff and restores ONLINE',
      () async {
    final trip = MockTripRepository();
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'COMPLETED', 'driver-1');
    when(() => trip.payment('booking-1', 1)).thenAnswer((_) async =>
        const CashPayment(
            paymentPublicId: 'payment-1',
            bookingPublicId: 'booking-1',
            method: 'CASH',
            status: 'PAID',
            amount: '16500.00',
            currency: 'VND'));
    await cubit.close();
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        tripRepository: trip,
        userPublicId: 'user-A',
        isMock: false,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1));
    await cubit.initialize();
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(store.values['user-A'], isNotNull);
    await cubit.finishSettledBooking(CashReceipt(
        paymentPublicId: 'payment-1',
        bookingPublicId: 'booking-1',
        paymentStatus: 'PAID',
        paymentMethod: 'CASH',
        cashCollectedAmount: '16500.00',
        currency: 'VND',
        commissionRate: '0.20',
        commissionAmount: '3300.00',
        commissionPolicyVersion: 'v1',
        paidAt: DateTime.utc(2026, 10, 16, 10, 6),
        driverReleasedAt: DateTime.utc(2026, 10, 16, 10, 6)));
    expect(store.values['user-A'], isNull);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, 'ONLINE');
  });

  testWidgets(
      'Expired offer renders zero seconds and disabled decision buttons',
      (tester) async {
    AppConfig.reset();
    final config = AppConfig.initialize(forceMock: false);
    await sl.reset();
    await setupServiceLocator(config: config);
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) =>
        PreviewDriverCubit(
            DriverState(
                operatingStatus: 'ONLINE',
                offer: offer(DateTime.now()
                    .toUtc()
                    .subtract(const Duration(seconds: 1)))),
            DriverUseCases(repository),
            location,
            session,
            store));
    const user = User(
        publicId: 'user-A',
        phoneNumber: '0900000000',
        fullName: 'Driver A',
        role: UserRole.driver);
    await tester.pumpWidget(BlocProvider<AuthBloc>(
      create: (_) => sl<AuthBloc>(),
      child: const MaterialApp(home: DriverHomeScreen(user: user)),
    ));
    expect(find.textContaining('còn 0 giây'), findsOneWidget);
    final accept = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Nhận chuyến'));
    expect(accept.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Accepted Booking handoff shows M3 trip details', (tester) async {
    final trip = MockTripRepository();
    when(() => trip.tracking('booking-1', any())).thenAnswer((_) async =>
        const TrackingSnapshot(
            bookingPublicId: 'booking-1',
            status: 'COMPLETED',
            driverPublicId: 'driver-1'));
    when(() => trip.payment('booking-1', any())).thenAnswer((_) async =>
        const CashPayment(
            paymentPublicId: 'payment-1',
            bookingPublicId: 'booking-1',
            method: 'CASH',
            status: 'PENDING',
            amount: '16500.00',
            currency: 'VND'));
    await sl.reset();
    AppConfig.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    await sl.unregister<TripRepository>();
    sl.registerSingleton<TripRepository>(trip);
    final fakeSession = MockSession();
    when(() => fakeSession.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => fakeSession.isCurrentSession(any()))
        .thenAnswer((_) async => true);
    await sl.unregister<SecureStorageService>();
    sl.registerSingleton<SecureStorageService>(fakeSession);
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: offer(DateTime.utc(2026, 10, 12, 12, 0, 15)))));
    await tester.pump();
    expect(find.textContaining('Booking UUID: booking-1'), findsOneWidget);
    expect(find.textContaining('Chuyến đi đã hoàn thành'), findsWidgets);
    expect(find.textContaining('16.500 VND'), findsOneWidget);
    expect(find.textContaining('Điểm đón: 21.0287, 105.8524'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Xác nhận đã thu tiền mặt'), 300);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
