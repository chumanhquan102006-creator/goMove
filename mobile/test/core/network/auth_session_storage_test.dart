import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/constants/storage_keys.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:mocktail/mocktail.dart';

class MockSessionStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockSessionStorage storage;
  late Map<String, String> values;
  late SecureStorageServiceImpl sessions;
  Completer<void>? bWriteStarted;
  Completer<void>? releaseBWrite;

  setUp(() {
    storage = MockSessionStorage();
    values = {};
    bWriteStarted = null;
    releaseBWrite = null;
    when(() => storage.read(key: any(named: 'key'))).thenAnswer(
        (call) async => values[call.namedArguments[#key] as String]);
    when(() => storage.write(
            key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((call) async {
      final value = call.namedArguments[#value] as String;
      if (value == 'B-refresh' && releaseBWrite != null) {
        bWriteStarted!.complete();
        await releaseBWrite!.future;
      }
      values[call.namedArguments[#key] as String] = value;
    });
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      values.remove(call.namedArguments[#key] as String);
    });
    sessions = SecureStorageServiceImpl(storage: storage);
  });

  test('Old generation cannot rotate, clear or change B identity', () async {
    await sessions.saveTokens(accessToken: 'A-access',
        refreshToken: 'A-refresh', userPublicId: 'A');
    final a = await sessions.getSession();
    await sessions.saveTokens(accessToken: 'B-access',
        refreshToken: 'B-refresh', userPublicId: 'B');
    final b = await sessions.getSession();
    expect(a.generation, isNot(b.generation));
    expect(await sessions.rotateTokensIfCurrent(
        generation: a.generation, expectedRefreshToken: 'A-refresh',
        accessToken: 'A-new', refreshToken: 'A-refresh-new'), isFalse);
    expect(await sessions.clearIfCurrent(a.generation), isFalse);
    expect(await sessions.saveUserPublicIdIfCurrent(a.generation, 'A'), isFalse);
    expect(values[StorageKeys.accessToken], 'B-access');
    expect(values[StorageKeys.refreshToken], 'B-refresh');
    expect(values[StorageKeys.userPublicId], 'B');

    expect(await sessions.rotateTokensIfCurrent(
        generation: b.generation, expectedRefreshToken: 'B-refresh',
        accessToken: 'B-new', refreshToken: 'B-refresh-new'), isTrue);
    expect((await sessions.getSession()).generation, b.generation);
    expect(values[StorageKeys.accessToken], 'B-new');
  });

  test('A stale clear queued during B login cannot erase B', () async {
    await sessions.saveTokens(accessToken: 'A-access',
        refreshToken: 'A-refresh', userPublicId: 'A');
    final a = await sessions.getSession();
    bWriteStarted = Completer<void>();
    releaseBWrite = Completer<void>();
    final bLogin = sessions.saveTokens(accessToken: 'B-access',
        refreshToken: 'B-refresh', userPublicId: 'B');
    await bWriteStarted!.future;
    final staleClear = sessions.clearIfCurrent(a.generation);
    releaseBWrite!.complete();
    await bLogin;
    expect(await staleClear, isFalse);
    expect(values[StorageKeys.accessToken], 'B-access');
    expect(values[StorageKeys.userPublicId], 'B');
  });
}
