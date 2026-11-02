import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/review/domain/review_models.dart';
import 'package:gomove_mobile/features/review/domain/review_repository.dart';
import 'package:gomove_mobile/features/review/presentation/admin_quality_cubit.dart';
import 'package:gomove_mobile/features/review/presentation/driver_reputation_cubit.dart';
import 'package:mocktail/mocktail.dart';

const driverId = 'driver-a';
const adminId = 'admin-a';
final caseItem = QualityCase('case-1', driverId, 'OPEN', 10, 2.5,
    'Điểm gần đây dưới ngưỡng', DateTime.utc(2026, 11, 1));
final detail = QualityDetail(caseItem,
    [RatingEvidence(2, 'Cần cải thiện', DateTime.utc(2026, 11, 1))], const []);

class _Session extends Mock implements SecureStorageService {}

class _Review extends Mock implements ReviewRepository {}

void main() {
  late _Session session;
  late _Review review;
  var generation = 1;
  String? owner = driverId;

  setUp(() {
    generation = 1;
    owner = driverId;
    session = _Session();
    review = _Review();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any()))
        .thenAnswer((call) async => call.positionalArguments[0] == generation);
  });

  void stubDriver({Future<DriverReputation> Function()? reputation}) {
    when(() => review.reputation(any())).thenAnswer((_) =>
        reputation?.call() ??
        Future.value(const DriverReputation(null, 0, 0, 0, 0, [])));
    when(() => review.rewards(any(), any()))
        .thenAnswer((_) async => const ReviewPage<RewardEvent>([], 0, false));
    when(() => review.myCases(any(), any()))
        .thenAnswer((_) async => const ReviewPage<QualityCase>([], 0, false));
  }

  void stubAdmin({Future<QualityDetail> Function()? read}) {
    when(() => review.adminCases(any(), any(), any()))
        .thenAnswer((_) async => ReviewPage([caseItem], 0, false));
    when(() => review.adminDetail(any(), any()))
        .thenAnswer((_) => read?.call() ?? Future.value(detail));
  }

  test('Driver sees only verified reputation, points and case history',
      () async {
    stubDriver();
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    expect(cubit.state.reputation?.average, isNull);
    expect(cubit.state.reputation?.ratingCount, 0);
    expect(cubit.state.rewards, isEmpty);
    await cubit.close();
  });

  test('Quality case carries a real Driver name without replacing support ID',
      () {
    final parsed = QualityCase.fromJson({
      'publicId': 'case-1',
      'driverPublicId': driverId,
      'driverDisplayName': 'Tài xế Minh',
      'status': 'OPEN',
      'ratingCount': 10,
      'recentAverage': 2.5,
      'reason': 'Điểm gần đây dưới ngưỡng',
      'createdAt': '2026-11-01T00:00:00Z',
    });
    expect(parsed.driverDisplayName, 'Tài xế Minh');
    expect(parsed.driverPublicId, driverId);
  });

  test('Background and account replacement discard late Driver data', () async {
    final pending = Completer<DriverReputation>();
    stubDriver(reputation: () => pending.future);
    final cubit = DriverReputationCubit(review, session, driverId);
    final load = cubit.load();
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(const DriverReputation(5, 1, 10, 0, 10, []));
    await load;
    expect(cubit.state.reputation, isNull);
    generation = 2;
    owner = 'driver-b';
    await cubit.load();
    expect(cubit.state.sessionEnded, isTrue);
    await cubit.close();
  });

  test('Unauthorized Driver reputation response closes private state',
      () async {
    stubDriver(
        reputation: () async =>
            throw const ServerException(message: 'expired', statusCode: 401));
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.reputation, isNull);
    await cubit.close();
  });

  test('Driver reward history loads the next authorized page once', () async {
    stubDriver();
    final first = RewardEvent('event-1', 5, 10, DateTime.utc(2026, 11, 1));
    final second = RewardEvent('event-2', 4, 5, DateTime.utc(2026, 11, 2));
    when(() => review.rewards(any(), any())).thenAnswer((call) async =>
        call.positionalArguments[0] == 0
            ? ReviewPage([first], 0, true)
            : ReviewPage([first, second], 1, false));
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    expect(cubit.state.rewards.map((e) => e.publicId), ['event-1']);
    await cubit.loadMoreRewards();
    expect(cubit.state.rewards.map((e) => e.publicId), ['event-1', 'event-2']);
    await cubit.loadMoreRewards();
    verify(() => review.rewards(1, 1)).called(1);
    await cubit.close();
  });

  test('Driver background rejects a late reward page', () async {
    stubDriver();
    final pending = Completer<ReviewPage<RewardEvent>>();
    when(() => review.rewards(any(), any())).thenAnswer((call) =>
        call.positionalArguments[0] == 0
            ? Future.value(const ReviewPage<RewardEvent>([], 0, true))
            : pending.future);
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    final more = cubit.loadMoreRewards();
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(ReviewPage(
        [RewardEvent('event-2', 4, 5, DateTime.utc(2026, 11, 2))], 1, false));
    await more;
    expect(cubit.state.rewards, isEmpty);
    await cubit.close();
  });

  test('Driver case pages discard repeated public IDs', () async {
    stubDriver();
    final later = QualityCase('case-2', driverId, 'DISMISSED', 20, 2.8,
        'Đã rà soát', DateTime.utc(2026, 11, 2));
    when(() => review.myCases(any(), any())).thenAnswer((call) async =>
        call.positionalArguments[0] == 0
            ? ReviewPage([caseItem], 0, true)
            : ReviewPage([caseItem, later], 1, false));
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    await cubit.loadMoreCases();
    expect(
        cubit.state.cases.map((item) => item.publicId), ['case-1', 'case-2']);
    await cubit.close();
  });

  test('Driver account switch rejects a late reward page', () async {
    stubDriver();
    final pending = Completer<ReviewPage<RewardEvent>>();
    when(() => review.rewards(any(), any())).thenAnswer((call) =>
        call.positionalArguments[0] == 0
            ? Future.value(const ReviewPage<RewardEvent>([], 0, true))
            : pending.future);
    final cubit = DriverReputationCubit(review, session, driverId);
    await cubit.load();
    final more = cubit.loadMoreRewards();
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = 'driver-b';
    pending.complete(ReviewPage(
        [RewardEvent('event-2', 4, 5, DateTime.utc(2026, 11, 2))], 1, false));
    await more;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.rewards, isEmpty);
    await cubit.close();
  });

  test('Admin background clears comments and late detail cannot restore them',
      () async {
    owner = adminId;
    final pending = Completer<QualityDetail>();
    stubAdmin(read: () => pending.future);
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    final opening = cubit.open(caseItem.publicId);
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(detail);
    await opening;
    expect(cubit.state.detail, isNull);
    expect(cubit.state.cases, isEmpty);
    await cubit.close();
  });

  test('Admin decision gates duplicate mutations until authoritative read',
      () async {
    owner = adminId;
    var current = detail;
    stubAdmin(read: () async => current);
    final pending = Completer<QualityDetail>();
    when(() => review.adminAction(any(), any(), any(), any()))
        .thenAnswer((_) => pending.future);
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    await cubit.open(caseItem.publicId);
    final action = cubit.act('WARN', 'Nhắc nhở');
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.working, isTrue);
    await cubit.act('WARN', 'Nhắc nhở');
    verify(() => review.adminAction(any(), any(), any(), any())).called(1);
    final warned = QualityCase('case-1', driverId, 'WARNED', 10, 2.5,
        caseItem.reason, caseItem.createdAt);
    current = QualityDetail(warned, detail.evidence,
        [QualityAction('WARN', 'Nhắc nhở', DateTime.utc(2026, 11, 1))]);
    pending.complete(current);
    await action;
    expect(cubit.state.working, isFalse);
    expect(cubit.state.uncertain, isFalse);
    expect(cubit.state.detail?.qualityCase.status, 'WARNED');
    await cubit.close();
  });

  test('Admin session switch rejects a late quality response', () async {
    owner = adminId;
    final pending = Completer<QualityDetail>();
    stubAdmin(read: () => pending.future);
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    final opening = cubit.open(caseItem.publicId);
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = 'user-b';
    pending.complete(detail);
    await opening;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.detail, isNull);
    await cubit.close();
  });

  test('Admin quality list loads more and rejects old pages after background',
      () async {
    owner = adminId;
    stubAdmin();
    final later = QualityCase('case-2', driverId, 'DISMISSED', 20, 2.8,
        'Đã rà soát', DateTime.utc(2026, 11, 2));
    final pending = Completer<ReviewPage<QualityCase>>();
    when(() => review.adminCases(any(), any(), any())).thenAnswer((call) =>
        call.positionalArguments[0] == 0
            ? Future.value(ReviewPage([caseItem], 0, true))
            : pending.future);
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    final more = cubit.loadMoreCases();
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(ReviewPage([later], 1, false));
    await more;
    expect(cubit.state.cases, isEmpty);
    await cubit.close();
  });

  test('Admin quality list includes the next server page without duplicates',
      () async {
    owner = adminId;
    stubAdmin();
    final later = QualityCase('case-2', driverId, 'DISMISSED', 20, 2.8,
        'Đã rà soát', DateTime.utc(2026, 11, 2));
    when(() => review.adminCases(any(), any(), any())).thenAnswer(
        (call) async => call.positionalArguments[0] == 0
            ? ReviewPage([caseItem], 0, true)
            : ReviewPage([caseItem, later], 1, false));
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    await cubit.loadMoreCases();
    await cubit.loadMoreCases();
    expect(
        cubit.state.cases.map((item) => item.publicId), ['case-1', 'case-2']);
    verify(() => review.adminCases(1, null, 1)).called(1);
    await cubit.close();
  });

  test('Admin account switch rejects a late quality page', () async {
    owner = adminId;
    stubAdmin();
    final pending = Completer<ReviewPage<QualityCase>>();
    when(() => review.adminCases(any(), any(), any())).thenAnswer((call) =>
        call.positionalArguments[0] == 0
            ? Future.value(ReviewPage([caseItem], 0, true))
            : pending.future);
    final cubit = AdminQualityCubit(review, session, adminId);
    await cubit.load();
    final more = cubit.loadMoreCases();
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = 'user-b';
    pending.complete(ReviewPage([caseItem], 1, false));
    await more;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.cases, isEmpty);
    await cubit.close();
  });
}
