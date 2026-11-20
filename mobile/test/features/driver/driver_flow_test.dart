import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
import 'package:gomove_mobile/features/driver/data/accepted_booking_store.dart';
import 'package:gomove_mobile/features/driver/data/location/driver_location_source.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_earnings_summary.dart';
import 'package:gomove_mobile/features/driver/domain/repositories/driver_earnings_repository.dart';
import 'package:gomove_mobile/features/driver/domain/repositories/driver_repository.dart';
import 'package:gomove_mobile/features/driver/domain/usecases/driver_usecases.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_earnings_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/onboarding_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_home_screen.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_accepted_booking_screen.dart';
import 'package:gomove_mobile/features/review/domain/review_models.dart';
import 'package:gomove_mobile/features/review/domain/review_repository.dart';
import 'package:gomove_mobile/features/review/presentation/driver_reputation_cubit.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/road_route_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockSession extends Mock implements SecureStorageService {}

class MockTripRepository extends Mock implements TripRepository {}

class PassiveRealtime implements TripRealtimeClient {
  @override
  TripRealtimeSubscription listen({
    required String bookingPublicId,
    required int sessionGeneration,
    required bool driver,
    required Future<void> Function() reconcileBeforeEvents,
  }) =>
      PassiveSubscription();
}

class PassiveSubscription implements TripRealtimeSubscription {
  @override
  Stream<TripRealtimeEvent> get events => const Stream.empty();
  @override
  Stream<TripRealtimeConnectionState> get connectionStates =>
      const Stream.empty();
  @override
  TripRealtimeConnectionState get state =>
      TripRealtimeConnectionState.disconnected;
  @override
  Future<bool> sendLocation(DriverCoordinates point,
          {required DateTime sampledAt}) async =>
      false;
  @override
  Future<void> dispose() async {}
}

class MemoryAcceptedStore implements AcceptedBookingStore {
  final values = <String, AcceptedBookingRecord>{};
  Object? writeError;
  Object? clearError;
  Future<void> Function(AcceptedBookingRecord)? beforeWrite;
  void Function(AcceptedBookingRecord)? onWrite;
  @override
  Future<AcceptedBookingRecord?> read(String userPublicId) async =>
      values[userPublicId];
  @override
  Future<void> write(String userPublicId, AcceptedBookingRecord record) async {
    if (writeError != null) throw writeError!;
    if (beforeWrite != null) await beforeWrite!(record);
    values[userPublicId] = record;
    onWrite?.call(record);
  }

  @override
  Future<void> clear(String userPublicId) async {
    if (clearError != null) throw clearError!;
    values.remove(userPublicId);
  }
}

class FakeLocation implements DriverLocationSource {
  DriverCoordinates point =
      const DriverCoordinates(21.0287, 105.8524, accuracy: 8, bearing: 0);
  DateTime Function() now = DateTime.now;
  DriverLocationProblem? problem;
  Future<DriverCoordinates> Function()? currentResponse;
  int calls = 0;
  @override
  Future<DriverCoordinates> current() async {
    calls++;
    if (problem != null) throw DriverLocationException(problem!);
    if (currentResponse != null) return await currentResponse!();
    return DriverCoordinates(point.latitude, point.longitude,
        accuracy: point.accuracy,
        bearing: point.bearing,
        approximate: point.approximate,
        sampledAt: point.sampledAt ?? now());
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
  Object? trackingError;
  Object? vehicleError;
  Future<DriverProfile> Function(String status)? statusResponse;
  Future<void> Function()? gpsResponse;
  Future<List<DriverVehicle>> Function()? vehicleResponse;
  Future<BookingTracking> Function()? trackingResponse;
  Future<DriverProfile> Function()? onboardResponse;
  Future<List<DriverOffer>> Function()? offerResponse;
  Future<OfferDecision> Function()? acceptResponse;
  Future<void> Function()? addDelay;
  Future<void> Function()? activateDelay;
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
    if (statusResponse != null) return statusResponse!(status);
    return DriverProfile('driver-1', 'APPROVED', status);
  }

  @override
  Future<List<DriverVehicle>> vehicles(int session) async {
    vehicleCalls++;
    if (vehicleError != null) throw vehicleError!;
    if (vehicleResponse != null) return vehicleResponse!();
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
    if (activateDelay != null) await activateDelay!();
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
    if (gpsResponse != null) await gpsResponse!();
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
    if (trackingError != null) throw trackingError!;
    if (trackingResponse != null) return trackingResponse!();
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

  void show(DriverState next) => emit(next);
}

class MockEarningsRepository extends Mock implements DriverEarningsRepository {}

class MockReviewRepository extends Mock implements ReviewRepository {}

class PreviewEarningsCubit extends DriverEarningsCubit {
  PreviewEarningsCubit(
      DriverEarningsState preview, SecureStorageService session)
      : super(MockEarningsRepository(), session, 'user-A') {
    emit(preview);
  }

  @override
  Future<void> load() async {}
}

class PreviewReputationCubit extends DriverReputationCubit {
  PreviewReputationCubit(
      DriverReputationState preview, SecureStorageService session)
      : super(MockReviewRepository(), session, 'user-A') {
    emit(preview);
  }

  @override
  Future<void> load() async {}

  void show(DriverReputationState next) => emit(next);
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
    location.now = () => now;
    generation = 1;
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => 'user-A');
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

  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
  });

  Future<void> restartDriver(
      {String user = 'user-A',
      TripRepository? tripRepository,
      Duration heartbeat = const Duration(hours: 1)}) async {
    await cubit.close();
    when(() => session.getUserPublicId()).thenAnswer((_) async => user);
    cubit = DriverCubit(
        useCases: DriverUseCases(repository),
        location: location,
        session: session,
        acceptedStore: store,
        tripRepository: tripRepository,
        userPublicId: user,
        isMock: false,
        now: () => now,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: heartbeat);
    await cubit.initialize();
  }

  Future<MockTripRepository> activeTripDriver() async {
    final trip = MockTripRepository();
    when(() => trip.tracking('booking-1', any())).thenAnswer((_) async =>
        TrackingSnapshot(
            bookingPublicId: 'booking-1',
            status: 'IN_PROGRESS',
            driverPublicId: 'driver-1',
            latitude: 21.0287,
            longitude: 105.8524,
            locationUpdatedAt: now));
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'IN_PROGRESS', 'driver-1');
    await restartDriver(
        tripRepository: trip, heartbeat: DriverCubit.locationHeartbeatInterval);
    cubit.setTripChannelActive(true);
    return trip;
  }

  test('Resume closure BUSY active channel verifies fresh REST GPS', () async {
    final trip = await activeTripDriver();
    final uploads = repository.gpsCalls;
    cubit.pause();
    await cubit.resume();
    expect(cubit.state.notice, isNull);
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(repository.gpsCalls, uploads,
        reason: 'The connected trip channel still owns GPS publishing.');
    verify(() => trip.tracking('booking-1', 1)).called(1);
  });

  test('Resume closure waits for Vehicle action then revalidates ONLINE',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final action = Completer<void>();
    repository.addDelay = () => action.future;
    final add =
        cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    await Future<void>.delayed(Duration.zero);
    final calls = repository.statusCalls;
    cubit.pause();
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.operatingStatus, isNull);
    expect(repository.statusCalls, calls);
    action.complete();
    await add;
    await resume;
    expect(repository.statusCalls, calls + 1);
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, contains('Đã thêm xe'));
  });

  for (final invalid in [
    'stale',
    'boundary',
    'future',
    'missing',
    'wrong booking',
    'wrong driver',
    'terminal',
    'invalid coordinates'
  ]) {
    test('Resume closure connected socket cannot prove $invalid GPS', () async {
      final trip = await activeTripDriver();
      final snapshot = TrackingSnapshot(
          bookingPublicId:
              invalid == 'wrong booking' ? 'booking-2' : 'booking-1',
          driverPublicId: invalid == 'wrong driver' ? 'driver-2' : 'driver-1',
          status: invalid == 'terminal' ? 'COMPLETED' : 'IN_PROGRESS',
          latitude: invalid == 'invalid coordinates' ? double.nan : 21.0287,
          longitude: 105.8524,
          locationUpdatedAt: invalid == 'missing'
              ? null
              : invalid == 'future'
                  ? now.add(const Duration(seconds: 1))
                  : invalid == 'stale'
                      ? now.subtract(const Duration(seconds: 31))
                      : invalid == 'boundary'
                          ? now.subtract(const Duration(seconds: 30))
                          : now);
      when(() => trip.tracking('booking-1', any()))
          .thenAnswer((_) async => snapshot);
      cubit.pause();
      await cubit.resume();
      expect(cubit.state.notice, contains('tạm dừng'));
      expect(cubit.state.operatingStatus, 'BUSY');
    });
  }

  for (final initial in ['stale', 'network failure']) {
    testWidgets('Resume closure retries $initial until REST confirms fresh GPS',
        (tester) async {
      final trip = await activeTripDriver();
      when(() => trip.tracking('booking-1', any())).thenAnswer((_) async {
        if (initial == 'network failure') {
          throw const ServerException(
              message: 'tracking unavailable', statusCode: 503);
        }
        return TrackingSnapshot(
            bookingPublicId: 'booking-1',
            status: 'IN_PROGRESS',
            driverPublicId: 'driver-1',
            latitude: 21.0287,
            longitude: 105.8524,
            locationUpdatedAt: now.subtract(const Duration(seconds: 31)));
      });
      cubit.pause();
      await cubit.resume();
      expect(cubit.state.notice, contains('tạm dừng'));
      when(() => trip.tracking('booking-1', any())).thenAnswer((_) async =>
          TrackingSnapshot(
              bookingPublicId: 'booking-1',
              status: 'IN_PROGRESS',
              driverPublicId: 'driver-1',
              latitude: 21.0287,
              longitude: 105.8524,
              locationUpdatedAt: now));
      now = now.add(DriverCubit.locationHeartbeatInterval);
      await tester.pump(DriverCubit.locationHeartbeatInterval);
      await tester.pump();
      expect(cubit.state.notice, isNull);
      verify(() => trip.tracking('booking-1', 1)).called(2);
      await tester.pump(const Duration(seconds: 27));
      verifyNoMoreInteractions(trip);
    });
  }

  testWidgets('Resume closure keeps one verification in flight',
      (tester) async {
    final trip = await activeTripDriver();
    final pending = Completer<TrackingSnapshot>();
    when(() => trip.tracking('booking-1', any()))
        .thenAnswer((_) => pending.future);
    cubit.pause();
    final resume = cubit.resume();
    await tester.pump();
    verify(() => trip.tracking('booking-1', 1)).called(1);
    now = now.add(const Duration(seconds: 27));
    await tester.pump(const Duration(seconds: 27));
    verifyNoMoreInteractions(trip);
    pending.complete(TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'IN_PROGRESS',
        driverPublicId: 'driver-1',
        latitude: 21.0287,
        longitude: 105.8524,
        locationUpdatedAt: now));
    await resume;
    expect(cubit.state.notice, isNull);
  });

  for (final invalidation in ['session replacement', 'dispose']) {
    testWidgets('Resume closure discards active trip proof after $invalidation',
        (tester) async {
      final trip = await activeTripDriver();
      final pending = Completer<TrackingSnapshot>();
      when(() => trip.tracking('booking-1', any()))
          .thenAnswer((_) => pending.future);
      cubit.pause();
      final resume = cubit.resume();
      await tester.pump();
      if (invalidation == 'dispose') {
        final closing = cubit.close();
        await tester.pump();
        await closing;
      } else {
        generation++;
      }
      final previous = cubit.state;
      pending.complete(TrackingSnapshot(
          bookingPublicId: 'booking-1',
          status: 'IN_PROGRESS',
          driverPublicId: 'driver-1',
          latitude: 21.0287,
          longitude: 105.8524,
          locationUpdatedAt: now));
      await resume;
      expect(cubit.state, same(previous));
      await tester.pump(const Duration(seconds: 27));
      verify(() => trip.tracking('booking-1', 1)).called(1);
    });

    test(
        'Resume closure discards deferred Vehicle revalidation after $invalidation',
        () async {
      await cubit.initialize();
      await cubit.goOnline();
      final action = Completer<void>();
      repository.addDelay = () => action.future;
      final add =
          cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
      await Future<void>.delayed(Duration.zero);
      final calls = repository.statusCalls;
      cubit.pause();
      final resume = cubit.resume();
      await Future<void>.delayed(Duration.zero);
      if (invalidation == 'dispose') {
        await cubit.close();
      } else {
        generation++;
      }
      final previous = cubit.state;
      action.complete();
      await add;
      await resume;
      expect(cubit.state, same(previous));
      expect(repository.statusCalls, calls);
    });
  }

  test('Resume closure waits for activation and preserves failed revalidation',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final action = Completer<void>();
    repository.activateDelay = () => action.future;
    final activate = cubit.activateVehicle('vehicle-1');
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    repository.statusError =
        const ServerException(message: 'revalidation failed', statusCode: 503);
    action.complete();
    await activate;
    await resume;
    expect(cubit.state.operatingStatus, isNull);
    expect(cubit.state.actionBusy, isFalse);
    expect(cubit.state.error, 'revalidation failed');
    expect(cubit.state.notice, 'Xe đã được kích hoạt.');
    repository.statusError = null;
    await cubit.resume();
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.error, isNull);
  });

  test('Resume closure only the newest deferred resume revalidates', () async {
    await cubit.initialize();
    await cubit.goOnline();
    final action = Completer<void>();
    repository.addDelay = () => action.future;
    final add =
        cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    await Future<void>.delayed(Duration.zero);
    final calls = repository.statusCalls;
    cubit.pause();
    final older = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final newer = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    action.complete();
    await Future.wait([add, older, newer]);
    expect(repository.statusCalls, calls + 1);
    expect(cubit.state.operatingStatus, 'ONLINE');
  });

  test(
      'Resume closure failed Vehicle action still releases deferred revalidation',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final action = Completer<void>();
    repository.addDelay = () => action.future;
    final add =
        cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    action.completeError(
        const ServerException(message: 'vehicle failed', statusCode: 503));
    await add;
    await resume;
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.actionBusy, isFalse);
    expect(cubit.state.error, 'vehicle failed');
    expect(repository.statusCalls, 2);
  });

  test('Resume closure active trip proof preserves a newer Vehicle notice',
      () async {
    final trip = await activeTripDriver();
    final pending = Completer<TrackingSnapshot>();
    when(() => trip.tracking('booking-1', any()))
        .thenAnswer((_) => pending.future);
    cubit.pause();
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    await cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    final independent = cubit.state.notice;
    pending.complete(TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'IN_PROGRESS',
        driverPublicId: 'driver-1',
        latitude: 21.0287,
        longitude: 105.8524,
        locationUpdatedAt: now));
    await resume;
    expect(cubit.state.notice, independent);
    expect(independent, contains('Đã thêm xe'));
  });

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

  test('Driver reliability clears only the confirmed OFFLINE notice on ONLINE',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    await cubit.goOffline();
    expect(cubit.state.notice, 'Máy chủ đã xác nhận OFFLINE.');
    final pending = Completer<DriverProfile>();
    repository.statusResponse = (_) => pending.future;
    final online = cubit.goOnline();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.operatingStatus, 'OFFLINE');
    expect(cubit.state.notice, 'Máy chủ đã xác nhận OFFLINE.');
    repository.vehicleError =
        const ServerException(message: 'vehicle_read_failed', statusCode: 503);
    await cubit.reloadVehicles();
    now = now.add(const Duration(seconds: 1));
    pending.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await online;
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, isNull);
    expect(cubit.state.error, 'vehicle_read_failed');
  });

  test('Driver reliability preserves OFFLINE when the ONLINE request fails',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    await cubit.goOffline();
    repository.statusError = const ServerException(
        message: 'status_request_failed', statusCode: 503);
    await cubit.goOnline();
    expect(cubit.state.operatingStatus, 'OFFLINE');
    expect(cubit.state.notice, 'Máy chủ đã xác nhận OFFLINE.');
    expect(cubit.state.error, 'status_request_failed');
    repository.statusError = null;
    now = now.add(const Duration(seconds: 1));
    await cubit.goOnline();
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.error, isNull);
  });

  test('Driver reliability retains an independent error that still applies',
      () async {
    await cubit.initialize();
    repository.vehicleError =
        const ServerException(message: 'vehicle_read_failed', statusCode: 503);
    await cubit.reloadVehicles();
    await cubit.goOnline();
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.error, 'vehicle_read_failed');
  });

  test('Driver reliability requires ONLINE in the actual server profile',
      () async {
    await cubit.initialize();
    repository.statusResponse =
        (_) async => const DriverProfile('driver-1', 'APPROVED', 'OFFLINE');
    await cubit.goOnline();
    expect(cubit.state.operatingStatus, 'OFFLINE');
    expect(repository.gpsCalls, 0);
  });

  test('Driver reliability clears expired pause notice after verified resume',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    await cubit.goOffline();
    final pending = Completer<DriverProfile>();
    repository.statusResponse = (_) => pending.future;
    final online = cubit.goOnline();
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final notice = cubit.state.notice;
    pending.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await online;
    expect(cubit.state.notice, notice);
    expect(cubit.state.foreground, isFalse);
    repository.statusResponse = null;
    await cubit.resume();
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, isNull);
    expect(cubit.state.notice, isNot(contains('xác nhận OFFLINE')));
  });

  test('Ownership regression keeps Vehicle E when Poll E recovers', () async {
    await cubit.initialize();
    repository.offerResponse = () =>
        Future.error(const ServerException(message: 'E', statusCode: 503));
    await cubit.goOnline();
    repository.vehicleError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.reloadVehicles();
    repository.offerResponse = null;
    await cubit.pollOnce();
    expect(cubit.state.error, 'E');
  });

  test('Ownership regression old Status E cannot clear later Vehicle E',
      () async {
    await cubit.initialize();
    repository.statusError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.goOnline();
    repository.statusError = null;
    await cubit.goOnline();
    expect(cubit.state.error, isNull);
    repository.vehicleError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.reloadVehicles();
    await cubit.goOnline();
    expect(cubit.state.error, 'E');
  });

  test(
      'Ownership regression ignores an older vehicle success after a newer error',
      () async {
    await cubit.initialize();
    final first = Completer<List<DriverVehicle>>();
    repository.vehicleResponse = () => first.future;
    final older = cubit.reloadVehicles();
    await Future<void>.delayed(Duration.zero);
    repository.vehicleError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.reloadVehicles();
    first.complete(repository.vehicleList);
    await older;
    expect(cubit.state.error, 'E');
  });

  test('Ownership regression failed resume never confirms ONLINE', () async {
    await cubit.initialize();
    await cubit.goOnline();
    cubit.pause();
    repository.statusError =
        const ServerException(message: 'resume_failed', statusCode: 503);
    await cubit.resume();
    expect(cubit.state.operatingStatus, isNot('ONLINE'));
    expect(cubit.state.error, 'resume_failed');
    expect(cubit.state.notice, contains('tạm dừng'));
  });

  test('Ownership regression old resume cannot acknowledge a newer pause',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    cubit.pause();
    final first = Completer<DriverProfile>();
    repository.statusResponse = (_) => first.future;
    final older = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final second = Completer<DriverProfile>();
    repository.statusResponse = (_) => second.future;
    final newer = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    first.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await older;
    expect(cubit.state.operatingStatus, isNot('ONLINE'));
    expect(cubit.state.notice, contains('tạm dừng'));
    second.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await newer;
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, isNull);
  });

  test('Driver reliability does not revive OFFLINE notice after a paused reply',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final pending = Completer<DriverProfile>();
    repository.statusResponse = (_) => pending.future;
    final offline = cubit.goOffline();
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final notice = cubit.state.notice;
    pending.complete(const DriverProfile('driver-1', 'APPROVED', 'OFFLINE'));
    await offline;
    expect(cubit.state.notice, notice);
    expect(cubit.state.operatingStatus, isNull,
        reason: 'The reply belongs to the activity before pause.');
    repository.statusResponse = null;
    await cubit.resume();
    expect(cubit.state.operatingStatus, 'OFFLINE');
    expect(cubit.state.notice, 'Máy chủ đã xác nhận OFFLINE.');
  });

  for (final source in ['Poll', 'Status']) {
    test(
        'Ownership regression $source recovery cannot clear an in-flight Vehicle E',
        () async {
      await cubit.initialize();
      final pendingPoll = Completer<List<DriverOffer>>();
      final pendingStatus = Completer<DriverProfile>();
      late Future<void> recovery;
      if (source == 'Poll') {
        repository.offerResponse = () =>
            Future.error(const ServerException(message: 'E', statusCode: 503));
        await cubit.goOnline();
        repository.offerResponse = () => pendingPoll.future;
        recovery = cubit.pollOnce();
      } else {
        repository.statusError =
            const ServerException(message: 'E', statusCode: 503);
        await cubit.goOnline();
        repository.statusError = null;
        repository.statusResponse = (_) => pendingStatus.future;
        recovery = cubit.goOnline();
      }
      await Future<void>.delayed(Duration.zero);
      repository.vehicleError =
          const ServerException(message: 'E', statusCode: 503);
      await cubit.reloadVehicles();
      if (source == 'Poll') {
        pendingPoll.complete([]);
      } else {
        pendingStatus
            .complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
      }
      await recovery;
      expect(cubit.state.error, 'E');
    });
  }

  test('Ownership regression late resume preserves a newer Vehicle error',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    cubit.pause();
    final pending = Completer<DriverProfile>();
    repository.statusResponse = (_) => pending.future;
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    repository.vehicleError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.reloadVehicles();
    pending.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await resume;
    expect(cubit.state.error, 'E');
    expect(cubit.state.notice, isNull);
    expect(cubit.state.operatingStatus, 'ONLINE');
  });

  for (final invalidation in ['session replacement', 'dispose']) {
    test(
        'Ownership regression late resume error is ignored after $invalidation',
        () async {
      await cubit.initialize();
      await cubit.goOnline();
      cubit.pause();
      final pending = Completer<DriverProfile>();
      repository.statusResponse = (_) => pending.future;
      final resume = cubit.resume();
      await Future<void>.delayed(Duration.zero);
      if (invalidation == 'dispose') {
        await cubit.close();
      } else {
        generation++;
      }
      final previous = cubit.state;
      pending.completeError(
          const ServerException(message: 'late E', statusCode: 503));
      await resume;
      expect(cubit.state, same(previous));
    });
  }

  test(
      'Ownership regression successful ONLINE preserves independent vehicle notice',
      () async {
    await cubit.initialize();
    await cubit.goOnline();
    final pending = Completer<void>();
    repository.addDelay = () => pending.future;
    final add =
        cubit.addVehicle(const VehicleDraft('79B-456.78', 'CAR_4_SEAT'));
    await Future<void>.delayed(Duration.zero);
    cubit.pause();
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.operatingStatus, isNot('ONLINE'));
    pending.complete();
    await add;
    await resume;
    final independent = cubit.state.notice;
    expect(independent, contains('Đã thêm xe'));
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(cubit.state.notice, independent);
  });

  test('Ownership regression BUSY resume clears pause only after confirmed GPS',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'PASSENGER_ONBOARD', 'driver-1');
    await cubit.initialize();
    cubit.pause();
    final pending = Completer<void>();
    repository.gpsResponse = () => pending.future;
    now = now.add(const Duration(seconds: 1));
    final resume = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.notice, contains('tạm dừng'));
    pending.complete();
    await resume;
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(cubit.state.notice, isNull);
  });

  test('Ownership regression Vehicle recovery clears its own error', () async {
    await cubit.initialize();
    repository.vehicleError =
        const ServerException(message: 'E', statusCode: 503);
    await cubit.reloadVehicles();
    expect(cubit.state.error, 'E');
    repository.vehicleError = null;
    await cubit.reloadVehicles();
    expect(cubit.state.error, isNull);
  });

  test(
      'Ownership regression newer vehicle load finishes initialization loading',
      () async {
    final first = Completer<List<DriverVehicle>>();
    repository.vehicleResponse = () => first.future;
    final initialization = cubit.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.loading, isTrue);
    repository.vehicleResponse = () async => repository.vehicleList;
    await cubit.reloadVehicles();
    expect(cubit.state.loading, isFalse);
    first.complete([]);
    await initialization;
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.vehicles, repository.vehicleList);
  });

  for (final invalidation in ['session replacement', 'dispose']) {
    test(
        'Ownership regression late session read cannot emit after $invalidation',
        () async {
      final pending = Completer<AuthSessionSnapshot>();
      when(() => session.getSession()).thenAnswer((_) => pending.future);
      final initialization = cubit.initialize();
      await Future<void>.delayed(Duration.zero);
      if (invalidation == 'dispose') {
        await cubit.close();
      } else {
        generation++;
      }
      final previous = cubit.state;
      pending.complete(const AuthSessionSnapshot(1, 'access', 'refresh'));
      await initialization;
      expect(cubit.state, same(previous));
      expect(repository.vehicleCalls, 0);
    });
  }

  for (final invalidation in ['session replacement', 'logout/dispose']) {
    test('Driver reliability ignores late ONLINE after $invalidation',
        () async {
      await cubit.initialize();
      final pending = Completer<DriverProfile>();
      repository.statusResponse = (_) => pending.future;
      final online = cubit.goOnline();
      await Future<void>.delayed(Duration.zero);
      if (invalidation == 'session replacement') {
        generation++;
      } else {
        await cubit.close();
      }
      final previous = cubit.state;
      pending.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
      await online;
      expect(cubit.state, same(previous));
      expect(repository.gpsCalls, 0);
    });
  }

  test(
      'Driver reliability keeps fresh GPS on duplicate then expires and recovers',
      () async {
    await cubit.initialize();
    final sampled = now;
    location.currentResponse = () async =>
        DriverCoordinates(21.0287, 105.8524, accuracy: 8, sampledAt: sampled);
    await cubit.goOnline();
    final message = cubit.state.locationMessage;
    now = now.add(const Duration(seconds: 5));
    await cubit.goOnline();
    expect(repository.gpsCalls, 1);
    expect(cubit.state.lastLocationUpload, sampled);
    expect(cubit.state.locationMessage, message);
    now = sampled.add(DriverCubit.locationFreshness);
    await cubit.goOnline();
    expect(repository.gpsCalls, 1);
    expect(cubit.state.locationMessage, contains('30 giây'));
    expect(repository.offerCalls, 2);
    now = now.add(const Duration(seconds: 1));
    location.currentResponse = null;
    await cubit.goOnline();
    expect(repository.gpsCalls, 2);
    expect(cubit.state.lastLocationUpload, now);
    expect(cubit.state.locationMessage, 'GPS mới đã gửi đến máy chủ.');
  });

  test(
      'Driver reliability distinguishes no sample and upload failure from expiry',
      () async {
    await cubit.initialize();
    location.currentResponse =
        () async => const DriverCoordinates(21.0287, 105.8524);
    await cubit.goOnline();
    expect(repository.gpsCalls, 0);
    expect(cubit.state.locationMessage, contains('chưa có mẫu'));
    expect(cubit.state.locationMessage, isNot(contains('30 giây')));
    location.currentResponse = () => Future.error(TimeoutException('no fix'));
    await cubit.goOnline();
    expect(cubit.state.locationMessage, contains('Chưa nhận được mẫu GPS'));
    location.currentResponse = null;
    repository.gpsResponse = () => Future.error(
        const ServerException(message: 'gps_upload_failed', statusCode: 503));
    await cubit.goOnline();
    expect(cubit.state.lastLocationUpload, isNull);
    expect(
        cubit.state.locationMessage, contains('Chưa gửi được GPS đến máy chủ'));
    await cubit.pollOnce();
    expect(cubit.state.locationMessage, contains('gps_upload_failed'));
    repository.gpsResponse = null;
    await cubit.goOnline();
    expect(cubit.state.locationMessage, 'GPS mới đã gửi đến máy chủ.');
    await cubit.goOffline();
    expect(cubit.state.locationMessage, contains('OFFLINE'));
  });

  test(
      'Driver reliability serializes status changes and ignores late GPS failure',
      () async {
    await cubit.initialize();
    final pending = Completer<DriverProfile>();
    repository.statusResponse = (_) => pending.future;
    final online = cubit.goOnline();
    await cubit.goOnline();
    await cubit.goOffline();
    expect(repository.statusCalls, 1);
    final gps = Completer<void>();
    repository.gpsResponse = () => gps.future;
    pending.complete(const DriverProfile('driver-1', 'APPROVED', 'ONLINE'));
    await Future<void>.delayed(Duration.zero);
    expect(repository.gpsCalls, 1);
    repository.statusResponse = null;
    await cubit.goOffline();
    final offline = cubit.state;
    gps.completeError(
        const ServerException(message: 'late_failure', statusCode: 503));
    await online;
    expect(cubit.state, same(offline));
    expect(cubit.state.operatingStatus, 'OFFLINE');
    expect(cubit.state.locationMessage, contains('OFFLINE'));
  });

  test('Driver reliability clears only recovered poll errors', () async {
    await cubit.initialize();
    repository.offerResponse = () => Future.error(
        const ServerException(message: 'poll_failed', statusCode: 503));
    await cubit.goOnline();
    expect(cubit.state.error, 'poll_failed');
    repository.offerResponse = null;
    await cubit.pollOnce();
    expect(cubit.state.error, isNull);
  });

  test('REST heartbeat rejects missing, stale and future device fixes',
      () async {
    await cubit.initialize();
    final invalidSamples = <DateTime?>[
      null,
      now.subtract(const Duration(seconds: 31)),
      now.add(const Duration(seconds: 1)),
    ];
    for (final sampledAt in invalidSamples) {
      location.currentResponse = () async => DriverCoordinates(
          21.0287, 105.8524,
          accuracy: 8, sampledAt: sampledAt);
      await cubit.goOnline();
      expect(repository.gpsCalls, 0);
      expect(cubit.state.lastLocationUpload, isNull);
    }

    location.currentResponse = () async =>
        DriverCoordinates(21.0287, 105.8524, accuracy: 8, sampledAt: now);
    await cubit.goOnline();
    expect(repository.gpsCalls, 1);
    expect(cubit.state.lastLocationUpload, now);
  });

  test('REST heartbeat rejects repeated or older samples, not stationary GPS',
      () async {
    await cubit.initialize();
    final firstSample = now;
    location.currentResponse = () async => DriverCoordinates(21.0287, 105.8524,
        accuracy: 8, sampledAt: firstSample);
    await cubit.goOnline();
    expect(repository.gpsCalls, 1);
    expect(cubit.state.lastLocationUpload, firstSample);

    await cubit.goOnline(); // The same device fix must not be republished.
    expect(repository.gpsCalls, 1);
    expect(cubit.state.lastLocationUpload, firstSample);

    location.currentResponse = () async => DriverCoordinates(21.0287, 105.8524,
        accuracy: 8,
        sampledAt: firstSample.subtract(const Duration(seconds: 1)));
    await cubit.goOnline();
    expect(repository.gpsCalls, 1);
    expect(cubit.state.lastLocationUpload, firstSample);

    now = now.add(const Duration(seconds: 1));
    location.currentResponse = () async =>
        DriverCoordinates(21.0287, 105.8524, accuracy: 8, sampledAt: now);
    await cubit.goOnline();
    expect(repository.gpsCalls, 2);
    expect(cubit.state.lastLocationUpload, now);
    expect(repository.lastPoint?.latitude, 21.0287);
    expect(repository.lastPoint?.longitude, 105.8524);
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
    location.currentResponse = () async {
      now = now.add(const Duration(milliseconds: 1));
      return DriverCoordinates(21.0287, 105.8524, sampledAt: now);
    };
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

  test('Connected ride channel cancels a BUSY fallback GPS acquisition',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'PASSENGER_ONBOARD', 'driver-1');
    final pending = Completer<DriverCoordinates>();
    location.currentResponse = () => pending.future;

    final initializing = cubit.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(location.calls, 1);

    cubit.setTripChannelActive(true);
    pending.complete(DriverCoordinates(21.0287, 105.8524, sampledAt: now));
    await initializing;
    expect(repository.gpsCalls, 0);
    expect(cubit.state.lastLocationUpload, isNull);
  });

  test('BUSY REST fallback pauses for ride channel and resumes on disconnect',
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
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(milliseconds: 15));
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'PASSENGER_ONBOARD', 'driver-1');
    location.currentResponse = () async {
      now = now.add(const Duration(milliseconds: 1));
      return DriverCoordinates(21.0287, 105.8524, sampledAt: now);
    };

    await cubit.initialize();
    expect(repository.gpsCalls, 1);
    cubit.setTripChannelActive(true);
    final atHandoff = repository.gpsCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repository.gpsCalls, atHandoff);

    cubit.setTripChannelActive(false);
    for (var i = 0; i < 20 && repository.gpsCalls == atHandoff; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(repository.gpsCalls, greaterThan(atHandoff));

    cubit.markTripCompleted('booking-1');
    final atCompletion = repository.gpsCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repository.gpsCalls, atCompletion);
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
    final sent = Completer<void>();
    repository.acceptResponse = () {
      sent.complete();
      return pending.future;
    };
    await cubit.initialize();
    await cubit.goOnline();
    final first = cubit.decide(true);
    await sent.future;
    await cubit.decide(true);
    expect(repository.acceptCalls, 1);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    expect(cubit.state.acceptedOffer, isNull);
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

  test('Confirmed cancellation clears handoff and revalidates online state',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    await cubit.decide(true);
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');

    await cubit.finishCancelledBooking('booking-1');

    expect(store.values['user-A'], isNull);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, 'ONLINE');
    expect(repository.statusCalls, 2);
    expect(cubit.state.notice, contains('trực tuyến trở lại'));
  });

  test('Failed online revalidation never fabricates a status after cancel',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    await cubit.decide(true);
    repository.statusError = const NetworkException('offline');

    await cubit.finishCancelledBooking('booking-1');

    expect(store.values['user-A'], isNull);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, isNull);
    expect(cubit.state.notice, contains('Bật trực tuyến lại'));
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

  test('M3B storage failure prevents the accept HTTP request', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    store.writeError = StateError('storage unavailable');

    await cubit.decide(true);

    expect(repository.acceptCalls, 0);
    expect(store.values, isEmpty);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.offerActionBusy, isFalse);
    expect(cubit.state.error, contains('chưa gửi yêu cầu'));
  });

  test('M3B termination before HTTP leaves intent but no phantom trip',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    Future<void>? closing;
    store.onWrite = (record) {
      if (record.pendingAcceptance) closing = cubit.close();
    };

    await cubit.decide(true);
    await closing;
    store.onWrite = null;
    repository.trackingError =
        const ServerException(message: 'masked', statusCode: 404);
    await restartDriver();

    expect(repository.acceptCalls, 0);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.unresolvedDecision, isTrue);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    await cubit.goOnline();
    await cubit.goOffline();
    expect(repository.statusCalls, 1);
  });

  test('M3B termination before confirmed persistence preserves durable intent',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    final confirming = Completer<void>();
    final diskWrite = Completer<void>();
    store.beforeWrite = (record) async {
      if (!record.pendingAcceptance) {
        confirming.complete();
        await diskWrite.future;
      }
    };
    final deciding = cubit.decide(true);
    await confirming.future;
    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    await cubit.close();
    diskWrite.completeError(StateError('process terminated before disk write'));
    await deciding;
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    store.beforeWrite = null;
    repository.trackingValue =
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1');

    await restartDriver();

    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(store.values['user-A']?.pendingAcceptance, isFalse);
    expect(store.values, hasLength(1));
    expect(repository.acceptCalls, 1);
  });

  test(
      'M3B unavailable backend retains intent and duplicate recovery is read-only',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.acceptError = const NetworkException();
    repository.trackingError = const NetworkException();
    await cubit.decide(true);
    await restartDriver();
    expect(cubit.state.acceptedOffer, isNull);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    repository.trackingError = null;
    final requested = Completer<void>();
    final tracking = Completer<BookingTracking>();
    repository.trackingResponse = () {
      requested.complete();
      return tracking.future;
    };
    final callsBefore = repository.trackingCalls;
    final first = cubit.reconcile();
    await requested.future;
    await cubit.reconcile();
    expect(repository.trackingCalls, callsBefore + 1);
    tracking.complete(
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1'));
    await first;

    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(store.values['user-A']?.pendingAcceptance, isFalse);
    expect(repository.acceptCalls, 1);
  });

  test('M3B authoritative rejected accept and masked tracking resolve intent',
      () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    repository.offers = [];
    repository.acceptError = const ServerException(
        message: 'expired', errorCode: 'OFFER_EXPIRED', statusCode: 409);
    repository.trackingError =
        const ServerException(message: 'masked', statusCode: 404);

    await cubit.decide(true);

    expect(store.values, isEmpty);
    expect(cubit.state.unresolvedDecision, isFalse);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.notice, contains('hết hạn'));
    expect(repository.acceptCalls, 1);
  });

  test('M3B expired local intent and absent offer do not prove non-acceptance',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.subtract(const Duration(minutes: 1))),
        pendingAcceptance: true);
    repository.trackingError =
        const ServerException(message: 'masked', statusCode: 404);

    await cubit.initialize();
    await cubit.reconcile();
    await cubit.decide(true);

    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.unresolvedDecision, isTrue);
    expect(repository.acceptCalls, 0);
    expect(repository.offerCalls, 0);
  });

  test(
      'M3B server cancellation clears pending intent; storage failure is retryable',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))),
        pendingAcceptance: true);
    repository.trackingValue =
        const BookingTracking('booking-1', 'CANCELLED', 'driver-1');
    store.clearError = StateError('storage unavailable');
    await cubit.initialize();
    expect(store.values['user-A'], isNotNull);
    expect(cubit.state.unresolvedDecision, isTrue);
    store.clearError = null;

    await cubit.reconcile();

    expect(store.values, isEmpty);
    expect(cubit.state.offer, isNull);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.unresolvedDecision, isFalse);
    expect(repository.acceptCalls, 0);
    expect(repository.gpsCalls, 0);
  });

  for (final mismatch in [
    const BookingTracking('booking-2', 'DRIVER_ACCEPTED', 'driver-1'),
    const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-2'),
  ]) {
    test(
        'M3B pending intent rejects mismatched ${mismatch.bookingPublicId}/${mismatch.driverPublicId}',
        () async {
      store.values['user-A'] = AcceptedBookingRecord(
          'driver-1', offer(now.add(const Duration(seconds: 15))),
          pendingAcceptance: true);
      repository.trackingValue = mismatch;

      await cubit.initialize();

      expect(cubit.state.acceptedOffer, isNull);
      expect(store.values['user-A']?.pendingAcceptance, isTrue);
      expect(repository.gpsCalls, 0);
    });
  }

  test('M3B late recovery from a logged-out account cannot promote intent',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))),
        pendingAcceptance: true);
    final requested = Completer<void>();
    final response = Completer<BookingTracking>();
    repository.trackingResponse = () {
      requested.complete();
      return response.future;
    };
    final initializing = cubit.initialize();
    await requested.future;
    generation++;
    when(() => session.getUserPublicId()).thenAnswer((_) async => 'user-B');
    response.complete(
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1'));
    await initializing;
    expect(cubit.state.acceptedOffer, isNull);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    final previousCalls = repository.trackingCalls;

    await restartDriver(user: 'user-B');

    expect(cubit.state.acceptedOffer, isNull);
    expect(repository.trackingCalls, previousCalls);
    expect(store.values['user-B'], isNull);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
  });

  test('M3B authenticated account mismatch cannot read the stored handoff',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))),
        pendingAcceptance: true);
    when(() => session.getUserPublicId()).thenAnswer((_) async => 'user-B');

    await cubit.initialize();
    await cubit.goOnline();

    expect(cubit.state.acceptedOffer, isNull);
    expect(repository.trackingCalls, 0);
    expect(repository.vehicleCalls, 0);
    expect(repository.statusCalls, 0);
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
  });

  test('M3B completed pending acceptance restores settlement without GPS',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))),
        pendingAcceptance: true);
    repository.trackingValue =
        const BookingTracking('booking-1', 'COMPLETED', 'driver-1');

    await cubit.initialize();

    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(cubit.state.completedAwaitingSettlement, isTrue);
    expect(store.values['user-A']?.pendingAcceptance, isFalse);
    expect(repository.gpsCalls, 0);
    expect(repository.acceptCalls, 0);
  });

  test('M3B committed acceptance survives restart before response', () async {
    repository.offers = [offer(now.add(const Duration(seconds: 15)))];
    await cubit.initialize();
    await cubit.goOnline();
    final sent = Completer<void>();
    final response = Completer<OfferDecision>();
    repository.acceptResponse = () {
      sent.complete();
      return response.future;
    };
    final deciding = cubit.decide(true);
    await sent.future;
    // The server has committed, but this process never receives the reply.
    repository.trackingValue =
        const BookingTracking('booking-1', 'DRIVER_ACCEPTED', 'driver-1');
    await cubit.close();
    response.complete(const OfferDecision('offer-1', 'ACCEPTED'));
    await deciding;
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

    await cubit.initialize();

    expect(cubit.state.acceptedOffer?.bookingPublicId, 'booking-1');
    expect(cubit.state.operatingStatus, 'BUSY');
    expect(repository.acceptCalls, 1);
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
    final sent = Completer<void>();
    repository.acceptResponse = () {
      sent.complete();
      return pending.future;
    };
    final first = cubit.decide(true);
    await sent.future;
    generation = 2;
    pending.complete(const OfferDecision('offer-1', 'ACCEPTED'));
    await first;
    expect(cubit.state.acceptedOffer, isNull);
    // The old account retains its durable intent, never a confirmed handoff.
    expect(store.values['user-A']?.pendingAcceptance, isTrue);
    expect(store.values['user-B'], isNull);
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

  test('Restart clears a server-cancelled handoff and explains how to resume',
      () async {
    store.values['user-A'] = AcceptedBookingRecord(
        'driver-1', offer(now.add(const Duration(seconds: 15))));
    repository.trackingValue =
        const BookingTracking('booking-1', 'CANCELLED', 'driver-1');

    await cubit.initialize();

    expect(store.values['user-A'], isNull);
    expect(cubit.state.acceptedOffer, isNull);
    expect(cubit.state.operatingStatus, isNull);
    expect(cubit.state.notice, contains('chuyến đã lưu bị hủy'));
    expect(repository.gpsCalls, 0);
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
    // The address provider is outside this trip-flow widget test.
    await sl.unregister<GeocodingRepository>();
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
    expect(find.textContaining('Booking UUID: booking-1'), findsNothing);
    expect(find.textContaining('Chuyến đi đã hoàn thành'), findsWidgets);
    expect(find.textContaining('16.500 VND'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Xác nhận đã thu tiền mặt'), 80,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsOneWidget);
    await tester.dragFrom(
        tester
            .getCenter(find.byKey(const ValueKey('driver-trip-sheet-handle'))),
        const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(find.text('Điểm đón và điểm đến'), -80,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('driver-trip-sheet-scroll')),
            matching: find.byType(Scrollable)));
    await tester.ensureVisible(find.text('Điểm đón và điểm đến'));
    await tester.pump();
    await tester.tap(find.text('Điểm đón và điểm đến'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
        find.textContaining('Điểm đón: 21.0287, 105.8524'), 80,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('driver-trip-sheet-scroll')),
            matching: find.byType(Scrollable)));
    expect(find.textContaining('Điểm đón: 21.0287, 105.8524'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver Home stays usable on a narrow screen with an offer',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppConfig.reset();
    await sl.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) =>
        PreviewDriverCubit(
            DriverState(
                operatingStatus: 'ONLINE',
                approvalStatus: 'APPROVED',
                vehicles: repository.vehicleList,
                offer: offer(
                    DateTime.now().toUtc().add(const Duration(seconds: 15)))),
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
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: DriverHomeScreen(user: user),
        ),
      ),
    ));
    expect(find.text('Đã duyệt'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Nhận chuyến'), 180);
    expect(find.textContaining('Giá đã chấp nhận: 16.500 VND'), findsOneWidget);
    expect(find.text('21.0287, 105.8524'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('driver-offer-offer-1'))).dy,
      lessThan(tester
          .getTopLeft(find.byKey(const ValueKey('driver-home-status-panel')))
          .dy),
    );
    expect(tester.takeException(), isNull);
    final accept = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Nhận chuyến'));
    expect(accept.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver dashboard shows authorized cash, vehicle, GPS and points',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppConfig.reset();
    await sl.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    final preview = PreviewDriverCubit(
        DriverState(
            operatingStatus: 'OFFLINE',
            approvalStatus: 'APPROVED',
            locationMessage: 'GPS sẵn sàng',
            vehicles: repository.vehicleList),
        DriverUseCases(repository),
        location,
        session,
        store);
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) => preview);
    await sl.unregister<DriverEarningsCubit>();
    sl.registerFactoryParam<DriverEarningsCubit, String, void>((_, __) =>
        PreviewEarningsCubit(
            const DriverEarningsState(
                summary: DriverEarningsSummary(
                    paidTripCount: 1,
                    cashCollectedAmount: '16500.00',
                    commissionDue: '3300.00',
                    afterCommissionAmount: '13200.00',
                    currency: 'VND')),
            session));
    await sl.unregister<DriverReputationCubit>();
    late PreviewReputationCubit reputationPreview;
    sl.registerFactoryParam<DriverReputationCubit, String, void>((_, __) {
      reputationPreview = PreviewReputationCubit(
          const DriverReputationState(
              reputation: DriverReputation(4.5, 2, 5, 0, 5, [])),
          session);
      return reputationPreview;
    });
    const user = User(
        publicId: 'user-A',
        phoneNumber: '0900000000',
        fullName: 'Driver A',
        role: UserRole.driver);
    await tester.pumpWidget(BlocProvider<AuthBloc>(
      create: (_) => sl<AuthBloc>(),
      child: const MaterialApp(home: DriverHomeScreen(user: user)),
    ));
    await tester.pump();
    expect(find.text('Tạm nghỉ'), findsOneWidget);
    expect(find.text('GPS sẵn sàng'), findsOneWidget);
    expect(find.textContaining('79A-123.45'), findsWidgets);
    expect(find.text('1 chuyến đã xác nhận'), findsOneWidget);
    expect(find.text('Tiền mặt đã thu'), findsOneWidget);
    expect(find.text('16.500 VND'), findsOneWidget);
    expect(find.text('Hoa hồng phải nộp'), findsOneWidget);
    expect(find.text('3.300 VND'), findsOneWidget);
    expect(find.text('Giá trị sau hoa hồng'), findsOneWidget);
    expect(find.text('13.200 VND'), findsOneWidget);
    expect(find.text('4.50 ★ · 2 đánh giá'), findsOneWidget);
    expect(find.text('5 GoPoints hiện có'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Bắt đầu nhận chuyến'))
            .onPressed,
        isNotNull);
    preview.show(preview.state.copy(operatingStatus: 'ONLINE'));
    expect(preview.state.operatingStatus, 'ONLINE');
    await tester.pumpAndSettle();
    expect(find.text('Đang nhận chuyến', skipOffstage: false), findsOneWidget);
    expect(find.text('Ngừng nhận chuyến'), findsOneWidget);
    reputationPreview.show(const DriverReputationState(loading: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
        find.text('Đang tải đánh giá…', skipOffstage: false), findsOneWidget);
    expect(find.text('Chưa có đánh giá'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('New offer enters once and busy decision keeps server authority',
      (tester) async {
    AppConfig.reset();
    await sl.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    final preview = PreviewDriverCubit(
        DriverState(
            operatingStatus: 'ONLINE', vehicles: repository.vehicleList),
        DriverUseCases(repository),
        location,
        session,
        store);
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) => preview);
    const user = User(
        publicId: 'user-A',
        phoneNumber: '0900000000',
        fullName: 'Driver A',
        role: UserRole.driver);
    await tester.pumpWidget(BlocProvider<AuthBloc>(
      create: (_) => sl<AuthBloc>(),
      child: const MaterialApp(home: DriverHomeScreen(user: user)),
    ));
    final incoming = offer(DateTime.utc(2099, 1, 1));
    preview.show(preview.state.copy(offer: incoming));
    await tester.pump();
    final motion = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const ValueKey('driver-offer-offer-1')));
    expect(motion.duration, AppMotion.card);
    expect(repository.acceptCalls, 0);
    await tester.pump(AppMotion.card);
    final offerFade = find.ancestor(
      of: find.text('Đề nghị nhận chuyến'),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(offerFade.first).opacity, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Opacity>(offerFade.first).opacity, 1);
    preview.show(preview.state.copy(offerActionBusy: true));
    await tester.pump();
    await tester.scrollUntilVisible(
        find.text('Đang gửi quyết định đến máy chủ…'), 200);
    expect(find.text('Đang gửi quyết định đến máy chủ…'), findsOneWidget);
    final accept = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Nhận chuyến'));
    expect(accept.onPressed, isNull);
    expect(repository.acceptCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Offer entrance is immediate with reduced motion',
      (tester) async {
    AppConfig.reset();
    await sl.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) =>
        PreviewDriverCubit(
            DriverState(
                operatingStatus: 'ONLINE',
                vehicles: repository.vehicleList,
                offer: offer(DateTime.utc(2099, 1, 1))),
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
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: DriverHomeScreen(user: user),
        ),
      ),
    ));
    final motion = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const ValueKey('driver-offer-offer-1')));
    expect(motion.duration, Duration.zero);
    expect(find.text('Đề nghị nhận chuyến'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Đề nghị nhận chuyến'),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Known unapproved Driver cannot start receiving offers',
      (tester) async {
    AppConfig.reset();
    await sl.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    await sl.unregister<DriverCubit>();
    sl.registerFactoryParam<DriverCubit, String, void>((_, __) =>
        PreviewDriverCubit(
            DriverState(
                operatingStatus: 'OFFLINE',
                approvalStatus: 'PENDING',
                vehicles: repository.vehicleList),
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
    expect(find.textContaining('Cần được phê duyệt'), findsOneWidget);
    final online = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Bắt đầu nhận chuyến'));
    expect(online.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('PAID cash displays receipt recovery, not cash confirmation',
      (tester) async {
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
            status: 'PAID',
            amount: '16500.00',
            currency: 'VND'));
    await sl.reset();
    AppConfig.reset();
    await setupServiceLocator(config: AppConfig.initialize(forceMock: false));
    await sl.unregister<GeocodingRepository>();
    await sl.unregister<TripRepository>();
    sl.registerSingleton<TripRepository>(trip);
    final fakeSession = MockSession();
    when(() => fakeSession.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => fakeSession.isCurrentSession(any()))
        .thenAnswer((_) async => true);
    await sl.unregister<SecureStorageService>();
    sl.registerSingleton<SecureStorageService>(fakeSession);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: offer(DateTime.utc(2026, 10, 12, 12, 0, 15)))));
    await tester.pump();
    await tester.scrollUntilVisible(
        find.text('Lấy lại biên nhận đã xác nhận'), 250);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsNothing);
    await tester.scrollUntilVisible(find.textContaining('Tiền mặt: Đã thu'), 80,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Tiền mặt: Đã thu'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Active trip offers only its next server-confirmed action',
      (tester) async {
    final trip = MockTripRepository();
    when(() => trip.tracking('booking-1', any())).thenAnswer((_) async =>
        const TrackingSnapshot(
            bookingPublicId: 'booking-1',
            status: 'IN_PROGRESS',
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
    await sl.unregister<GeocodingRepository>();
    await sl.unregister<RoadRouteRepository>();
    await sl.unregister<TripRepository>();
    sl.registerSingleton<TripRepository>(trip);
    await sl.unregister<TripRealtimeClient>();
    sl.registerSingleton<TripRealtimeClient>(PassiveRealtime());
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
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Hoàn thành chuyến'), 250);
    final next = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Hoàn thành chuyến'));
    expect(next.onPressed, isNotNull);
    expect(find.widgetWithText(FilledButton, 'Đã đón khách'), findsNothing);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
