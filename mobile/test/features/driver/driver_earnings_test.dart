import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_earnings_summary.dart';
import 'package:gomove_mobile/features/driver/domain/repositories/driver_earnings_repository.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_earnings_cubit.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _Earnings extends Mock implements DriverEarningsRepository {}

const _driver = 'driver-a';
const _summary = DriverEarningsSummary(
  paidTripCount: 2,
  cashCollectedAmount: '33000.00',
  commissionDue: '6600.00',
  afterCommissionAmount: '26400.00',
  currency: 'VND',
);

void main() {
  late _Session session;
  late _Earnings repository;
  var generation = 1;
  String? owner = _driver;

  setUp(() {
    generation = 1;
    owner = _driver;
    session = _Session();
    repository = _Earnings();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any()))
        .thenAnswer((call) async => call.positionalArguments[0] == generation);
    when(() => repository.summary(any())).thenAnswer((_) async => _summary);
  });

  test('Parses exact server money values without floating-point arithmetic',
      () {
    final value = DriverEarningsSummary.fromJson({
      'paidTripCount': 2,
      'cashCollectedAmount': '33000.00',
      'commissionDueAmount': '6600.00',
      'afterCommissionAmount': '26400.00',
      'currency': 'VND',
    });
    expect(value.cashCollectedAmount, '33000.00');
    expect(value.afterCommissionAmount, '26400.00');
    expect(value.paidTripCount, 2);
  });

  test('Loads only authorized earnings and clears them in background',
      () async {
    final cubit = DriverEarningsCubit(repository, session, _driver);
    await cubit.load();
    expect(cubit.state.summary?.paidTripCount, 2);
    cubit.hideForBackground();
    expect(cubit.state.summary, isNull);
    await cubit.load();
    expect(cubit.state.summary?.cashCollectedAmount, '33000.00');
    await cubit.close();
  });

  test('Late response after account replacement cannot reveal old earnings',
      () async {
    final pending = Completer<DriverEarningsSummary>();
    when(() => repository.summary(any())).thenAnswer((_) => pending.future);
    final cubit = DriverEarningsCubit(repository, session, _driver);
    final load = cubit.load();
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = 'driver-b';
    pending.complete(_summary);
    await load;
    expect(cubit.state.summary, isNull);
    expect(cubit.state.sessionEnded, isTrue);
    await cubit.close();
  });

  test('Background discards an in-flight financial summary', () async {
    final pending = Completer<DriverEarningsSummary>();
    when(() => repository.summary(any())).thenAnswer((_) => pending.future);
    final cubit = DriverEarningsCubit(repository, session, _driver);
    final load = cubit.load();
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(_summary);
    await load;
    expect(cubit.state.summary, isNull);
    await cubit.close();
  });

  test('Unauthorized summary removes private state', () async {
    when(() => repository.summary(any()))
        .thenThrow(const ServerException(message: 'expired', statusCode: 401));
    final cubit = DriverEarningsCubit(repository, session, _driver);
    await cubit.load();
    expect(cubit.state.summary, isNull);
    expect(cubit.state.sessionEnded, isTrue);
    await cubit.close();
  });
}
