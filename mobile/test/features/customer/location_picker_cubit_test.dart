import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/location_picker_cubit.dart';

class _Session extends Mock implements SecureStorageService {}

class _Geocoding implements GeocodingRepository {
  final calls = <Coordinates>[];
  Future<PlaceSearchResult?> Function(Coordinates)? handler;
  @override
  Future<List<PlaceSearchResult>> search(String query,
          {int? sessionGeneration}) async =>
      [];
  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) {
    calls.add(point);
    return handler?.call(point) ?? Future.value(null);
  }
}

const a = Coordinates(21.03, 105.85);
const b = Coordinates(21.04, 105.86);
PlaceSearchResult address(String label, Coordinates point) =>
    PlaceSearchResult(label: label, coordinates: point);

void main() {
  late _Session session;
  late _Geocoding geocoding;
  late LocationPickerCubit picker;
  var currentAccount = true;
  setUp(() {
    session = _Session();
    geocoding = _Geocoding();
    currentAccount = true;
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(7, 'test-access', null));
    when(() => session.getUserPublicId())
        .thenAnswer((_) async => 'test-customer');
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
    picker = LocationPickerCubit(
        session: session,
        geocoding: geocoding,
        customerPublicId: 'test-customer',
        isCurrentAccount: () => currentAccount);
  });
  void pickerTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await picker.close();
      }
    });
  }

  Future<int> enter() async {
    await picker.enter(LocationPickerTarget.pickup, a);
    return picker.state.epoch;
  }

  pickerTest('Enter waits for a stable native camera before confirmation',
      (tester) async {
    final epoch = await enter();
    expect(picker.state.point, same(a));
    expect(picker.state.canConfirm, isFalse);
    picker.cameraMoving(epoch, 1);
    expect(picker.state.phase, LocationPickerPhase.moving);
    picker.cameraIdle(epoch, 1, b);
    expect(picker.state.point, same(b));
    expect(picker.state.canConfirm, isTrue);
    expect(geocoding.calls, isEmpty);
  });

  pickerTest('Confirm returns exact target once without waiting for geocoding',
      (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, b);
    final first = picker.confirm();
    expect(await picker.confirm(), isNull);
    final result = await first;
    expect(result!.target, LocationPickerTarget.pickup);
    expect(result.point, same(b));
    expect(result.address, isNull);
    expect(picker.state.isOpen, isFalse);
    expect(geocoding.calls, isEmpty);
  });

  pickerTest('Lookup starts only after 600ms stability, never during a pan',
      (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 599));
    expect(geocoding.calls, isEmpty);
    picker.cameraMoving(epoch, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(geocoding.calls, isEmpty);
    picker.cameraIdle(epoch, 2, b);
    await tester.pump(const Duration(milliseconds: 600));
    expect(geocoding.calls, [b]);
  });

  pickerTest('One in-flight lookup retains only latest pending point',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    geocoding.handler = (_) => pending.future;
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    await tester.pump(const Duration(milliseconds: 600));
    const c = Coordinates(21.05, 105.87);
    picker.cameraMoving(epoch, 3);
    picker.cameraIdle(epoch, 3, c);
    await tester.pump(const Duration(milliseconds: 600));
    expect(geocoding.calls, [a]);
    geocoding.handler = (point) async => address('latest', point);
    pending.complete(address('stale', a));
    await tester.pump();
    expect(geocoding.calls, [a, c]);
    expect(picker.state.address?.label, 'latest');
  });

  pickerTest('Lookup starts stay at least one second apart', (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    expect(geocoding.calls, [a]);
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    await tester.pump(const Duration(milliseconds: 600));
    expect(geocoding.calls, [a]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(geocoding.calls, [a, b]);
  });

  pickerTest('Cancel and reopen at same point rejects old epoch response',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    geocoding.handler = (_) => pending.future;
    final first = await enter();
    picker.cameraIdle(first, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    picker.cancel();
    final second = await enter();
    picker.cameraIdle(second, 2, a);
    pending.complete(address('old epoch', a));
    await tester.pump();
    expect(picker.state.address, isNull);
    expect(picker.state.epoch, second);
    picker.cameraIdle(first, 50, b);
    expect(picker.state.point, same(a));
  });

  pickerTest('Generation change during confirm discards draft', (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, b);
    when(() => session.isCurrentSession(7)).thenAnswer((_) async => false);
    expect(await picker.confirm(), isNull);
    expect(picker.state.isOpen, isFalse);
  });

  pickerTest('New movement while confirm is authorizing prevents stale commit',
      (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    final check = Completer<bool>();
    when(() => session.isCurrentSession(7)).thenAnswer((_) => check.future);
    final confirm = picker.confirm();
    await tester.pump();
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    check.complete(true);
    expect(await confirm, isNull);
    expect(picker.state.point, same(b));
  });

  pickerTest('Account replacement blocks lookup and commit', (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, b);
    currentAccount = false;
    await tester.pump(const Duration(seconds: 1));
    expect(geocoding.calls, isEmpty);
    expect(await picker.confirm(), isNull);
  });

  pickerTest('Stored owner mismatch cannot open a camera-enabled picker',
      (tester) async {
    when(() => session.getUserPublicId())
        .thenAnswer((_) async => 'other-customer');
    await enter();
    expect(picker.state.isOpen, isFalse);
  });

  pickerTest('Background invalidates work; resume requires fresh camera epoch',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    geocoding.handler = (_) => pending.future;
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    picker.suspend();
    expect(picker.state.canConfirm, isFalse);
    pending.complete(address('background result', a));
    await tester.pump();
    await picker.resume();
    expect(picker.state.epoch, isNot(epoch));
    expect(picker.state.canConfirm, isFalse);
    expect(picker.state.address, isNull);
    picker.cameraIdle(epoch, 9, b);
    expect(picker.state.point, same(a));
  });

  pickerTest('Resume rejects a different session generation', (tester) async {
    await enter();
    picker.suspend();
    when(() => session.isCurrentSession(7)).thenAnswer((_) async => false);
    await picker.resume();
    expect(picker.state.isOpen, isFalse);
  });

  pickerTest('429 stops automatic requests for this picker epoch',
      (tester) async {
    geocoding.handler = (_) async =>
        throw const ServerException(message: 'busy', statusCode: 429);
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    expect(picker.state.message, contains('quá tải'));
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    await tester.pump(const Duration(seconds: 5));
    expect(geocoding.calls, hasLength(1));
    expect(picker.state.canConfirm, isTrue);
  });

  pickerTest(
      'Invalid/unavailable camera cannot confirm; a later valid idle recovers',
      (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, const Coordinates(double.nan, 0));
    expect(picker.state.phase, LocationPickerPhase.unavailable);
    expect(await picker.confirm(), isNull);
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    expect(picker.state.canConfirm, isTrue);
  });

  pickerTest('Reverse address for different coordinates is never attached',
      (tester) async {
    geocoding.handler = (_) async => address('wrong point', b);
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    expect(picker.state.address, isNull);
    expect((await picker.confirm())!.point, same(a));
  });
  pickerTest('Stale 429 still stops requests for the current picker',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    geocoding.handler = (_) => pending.future;
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    picker.cameraMoving(epoch, 2);
    picker.cameraIdle(epoch, 2, b);
    await tester.pump(const Duration(milliseconds: 600));
    pending
        .completeError(const ServerException(message: 'busy', statusCode: 429));
    await tester.pump(const Duration(seconds: 3));
    expect(geocoding.calls, hasLength(1));
    expect(picker.state.point, same(b));
    expect(picker.state.canConfirm, isTrue);
  });

  pickerTest('Repeated idle at the exact point does not repeat reverse',
      (tester) async {
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 4; i++) {
      picker.cameraIdle(epoch, 1, a);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(geocoding.calls, hasLength(1));
  });

  pickerTest('Geocoding timeout keeps exact coordinates confirmable',
      (tester) async {
    geocoding.handler = (_) async => throw TimeoutException('lookup timeout');
    final epoch = await enter();
    picker.cameraIdle(epoch, 1, a);
    await tester.pump(const Duration(milliseconds: 600));
    expect(picker.state.lookingUp, isFalse);
    expect(picker.state.address, isNull);
    expect((await picker.confirm())!.point, same(a));
  });
}
