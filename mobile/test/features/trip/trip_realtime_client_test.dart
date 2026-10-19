import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';

const bookingA = '19bcf827-34b4-45e8-9f15-1f50abbc6090';
const bookingB = '783eb1d8-4355-46b3-8d45-65d1f8c032dd';

class _Session implements SecureStorageService {
  int generation = 1;
  String? token = 'token-A-1';
  String? refresh = 'refresh-A-1';

  @override
  Future<AuthSessionSnapshot> getSession() async =>
      AuthSessionSnapshot(generation, token, refresh);
  @override
  Future<bool> isCurrentSession(int value) async => generation == value;
  @override
  Future<String?> getAccessToken() async => token;
  @override
  Future<String?> getRefreshToken() async => refresh;
  @override
  Future<String?> getUserPublicId() async => null;
  @override
  Future<void> saveUserPublicId(String publicId) async {}
  @override
  Future<bool> saveUserPublicIdIfCurrent(
          int generation, String publicId) async =>
      this.generation == generation;
  @override
  Future<void> saveTokens(
      {required String accessToken,
      required String refreshToken,
      String? userPublicId}) async {
    generation++;
    token = accessToken;
    refresh = refreshToken;
  }

  @override
  Future<bool> rotateTokensIfCurrent(
      {required int generation,
      required String expectedRefreshToken,
      required String accessToken,
      required String refreshToken}) async {
    if (this.generation != generation || refresh != expectedRefreshToken) {
      return false;
    }
    token = accessToken;
    refresh = refreshToken;
    return true;
  }

  @override
  Future<bool> clearIfCurrent(int generation) async {
    if (this.generation != generation) return false;
    await clearAll();
    return true;
  }

  @override
  Future<void> clearAll() async {
    generation++;
    token = null;
    refresh = null;
  }
}

class _Transport implements TripStompTransport {
  final StompConfig config;
  bool active = false;
  @override
  bool connected = false;
  String? subscribedDestination;
  void Function(String?)? onBody;
  int unsubscribed = 0;
  final sent = <(String, String)>[];

  _Transport(this.config);

  @override
  void activate() => active = true;
  @override
  void deactivate() {
    active = false;
    connected = false;
  }

  @override
  void Function() subscribe(
      String destination, void Function(String?) callback) {
    subscribedDestination = destination;
    onBody = callback;
    return () {
      unsubscribed++;
      onBody = null;
    };
  }

  @override
  void send(String destination, String body) => sent.add((destination, body));

  void connect() {
    connected = true;
    config.onConnect(StompFrame(command: 'CONNECTED'));
  }

  void message(String body) => onBody?.call(body);
  void fail() => config.onWebSocketDone();
}

class _Harness {
  final session = _Session();
  final transports = <_Transport>[];
  DateTime now = DateTime.utc(2026, 10, 16, 10);
  final Duration tokenCheckInterval;
  _Harness({this.tokenCheckInterval = const Duration(seconds: 15)});
  late final client = TripRealtimeClientImpl(
      config: const AppConfig(
          environment: AppEnvironment.dev,
          appTitle: 'test',
          apiBaseUrl: 'http://localhost:8080/api/v1',
          wsBaseUrl: 'ws://localhost:8080/ws',
          connectTimeout: Duration(seconds: 1),
          receiveTimeout: Duration(seconds: 1),
          sendTimeout: Duration(seconds: 1),
          isMock: false),
      session: session,
      now: () => now,
      reconnectBaseDelay: const Duration(milliseconds: 5),
      tokenCheckInterval: tokenCheckInterval,
      transportFactory: (config) {
        final transport = _Transport(config);
        transports.add(transport);
        return transport;
      });
}

String _status(String bookingId, String status) => jsonEncode({
      'type': 'TRIP_STATUS_CHANGED',
      'bookingPublicId': bookingId,
      'status': status,
      'occurredAt': '2026-10-16T10:00:00Z',
    });

String _location(String bookingId) => jsonEncode({
      'type': 'DRIVER_LOCATION_UPDATED',
      'bookingPublicId': bookingId,
      'latitude': 21.0,
      'longitude': 105.0,
      'accuracy': 5.0,
      'bearing': 0.0,
      'recordedAt': '2026-10-16T10:00:01Z',
    });

String _jwt(DateTime expiry) => 'e30.${base64Url.encode(utf8.encode(jsonEncode({
          'exp': expiry.millisecondsSinceEpoch ~/ 1000
        })))}.signature';

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('CONNECT carries current JWT in STOMP header, never URL or debug',
      () async {
    final h = _Harness();
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async {});
    await _settle();
    final config = h.transports.single.config;
    expect(config.url, 'ws://localhost:8080/ws');
    expect(config.stompConnectHeaders, {'Authorization': 'Bearer token-A-1'});
    expect(config.webSocketConnectHeaders, isNull);
    expect(config.url, isNot(contains('token')));
    h.transports.single.connect();
    await _settle();
    expect(h.transports.single.subscribedDestination, '/topic/ride/$bookingA');
    expect(subscription.state, TripRealtimeConnectionState.connected);
    await subscription.dispose();
  });

  test('REST reconciliation gates frames and rejects wrong booking or JSON',
      () async {
    final h = _Harness();
    final gate = Completer<void>();
    var reconciliations = 0;
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async {
          reconciliations++;
          await gate.future;
        });
    final received = <TripRealtimeEvent>[];
    final listener = subscription.events.listen(received.add);
    await _settle();
    h.transports.single.connect();
    await _settle();
    h.transports.single.message(_status(bookingA, 'DRIVER_ARRIVED'));
    expect(received, isEmpty);
    expect(subscription.state, isNot(TripRealtimeConnectionState.connected));
    gate.complete();
    await _settle();
    expect(reconciliations, 1);
    expect(received.single, isA<TripStatusChangedEvent>());
    h.transports.single.message(_status(bookingB, 'COMPLETED'));
    h.transports.single.message('{broken');
    h.transports.single.message(_location(bookingA));
    await _settle();
    expect(received.length, 2);
    expect(received.last, isA<TripDriverLocationEvent>());
    await listener.cancel();
    await subscription.dispose();
  });

  test('customer cannot SEND, driver SEND is validated and omits timestamp',
      () async {
    final h = _Harness();
    final customer = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async {});
    await _settle();
    h.transports.single.connect();
    await _settle();
    const point = DriverCoordinates(21, 105, accuracy: 5, bearing: 0);
    expect(await customer.sendLocation(point, sampledAt: h.now), isFalse);
    expect(h.transports.single.sent, isEmpty);

    final driver = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: true,
        reconcileBeforeEvents: () async {});
    await _settle();
    final transport = h.transports.last;
    transport.connect();
    await _settle();
    expect(
        await driver.sendLocation(point,
            sampledAt: h.now.subtract(const Duration(seconds: 31))),
        isFalse);
    expect(
        await driver.sendLocation(const DriverCoordinates(91, 105),
            sampledAt: h.now),
        isFalse);
    expect(await driver.sendLocation(point, sampledAt: h.now), isTrue);
    expect(await driver.sendLocation(point, sampledAt: h.now), isFalse);
    expect(transport.sent.length, 1);
    expect(transport.sent.single.$1, '/app/ride/$bookingA/location');
    expect(jsonDecode(transport.sent.single.$2), {
      'latitude': 21,
      'longitude': 105,
      'accuracy': 5,
      'bearing': 0,
    });
    await driver.dispose();
  });

  test('reconnect reads rotated token and reconciles before new events',
      () async {
    final h = _Harness();
    var reconciliations = 0;
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async => reconciliations++);
    await _settle();
    h.transports.single.connect();
    await _settle();
    expect(reconciliations, 1);
    h.session.token = 'token-A-2';
    h.transports.single.fail();
    expect(subscription.state, TripRealtimeConnectionState.failed);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(h.transports.length, 2);
    expect(h.transports.last.config.stompConnectHeaders,
        {'Authorization': 'Bearer token-A-2'});
    h.transports.last.connect();
    await _settle();
    expect(reconciliations, 2);
    expect(subscription.state, TripRealtimeConnectionState.connected);
    await subscription.dispose();
  });

  test('open subscription detects same-session rotation without socket loss',
      () async {
    final h = _Harness(tokenCheckInterval: const Duration(milliseconds: 5));
    var reconciliations = 0;
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async => reconciliations++);
    await _settle();
    final first = h.transports.single;
    first.connect();
    await _settle();
    h.session.token = 'token-A-rotated';
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(first.active, isFalse);
    expect(h.transports.length, 2);
    expect(h.transports.last.config.stompConnectHeaders,
        {'Authorization': 'Bearer token-A-rotated'});
    h.transports.last.connect();
    await _settle();
    expect(reconciliations, 2);
    await subscription.dispose();
  });

  test('expired open JWT forces REST refresh and fresh STOMP connection',
      () async {
    final h = _Harness(tokenCheckInterval: const Duration(milliseconds: 5));
    final originalToken = _jwt(h.now.add(const Duration(minutes: 1)));
    final refreshedToken = _jwt(h.now.add(const Duration(minutes: 20)));
    h.session.token = originalToken;
    var reconciliations = 0;
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: false,
        reconcileBeforeEvents: () async {
          reconciliations++;
          if (reconciliations == 2) h.session.token = refreshedToken;
        });
    await _settle();
    final first = h.transports.single;
    first.connect();
    await _settle();
    h.now = h.now.add(const Duration(minutes: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(first.active, isFalse);
    expect(h.transports.length, 2);
    expect(h.transports.last.config.stompConnectHeaders,
        {'Authorization': 'Bearer $refreshedToken'});
    h.transports.last.connect();
    await _settle();
    expect(reconciliations, 3);
    expect(subscription.state, TripRealtimeConnectionState.connected);
    await subscription.dispose();
  });

  test('logout/account switch invalidates late frames and old GPS SEND',
      () async {
    final h = _Harness();
    final subscription = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: true,
        reconcileBeforeEvents: () async {});
    final events = <TripRealtimeEvent>[];
    subscription.events.listen(events.add);
    await _settle();
    final oldTransport = h.transports.single;
    oldTransport.connect();
    await _settle();
    h.session.generation = 2;
    h.session.token = 'token-B';
    oldTransport.message(_status(bookingA, 'IN_PROGRESS'));
    expect(
        await subscription.sendLocation(const DriverCoordinates(21, 105),
            sampledAt: h.now),
        isFalse);
    await _settle();
    expect(events, isEmpty);
    expect(oldTransport.active, isFalse);
    expect(subscription.state, TripRealtimeConnectionState.disconnected);
  });

  test('new Booking disposes old topic and completion stops locations',
      () async {
    final h = _Harness();
    final first = h.client.listen(
        bookingPublicId: bookingA,
        sessionGeneration: 1,
        driver: true,
        reconcileBeforeEvents: () async {});
    await _settle();
    final oldTransport = h.transports.single;
    oldTransport.connect();
    await _settle();
    final second = h.client.listen(
        bookingPublicId: bookingB,
        sessionGeneration: 1,
        driver: true,
        reconcileBeforeEvents: () async {});
    expect(first.state, TripRealtimeConnectionState.disconnected);
    expect(oldTransport.unsubscribed, 1);
    expect(oldTransport.active, isFalse);
    await _settle();
    final newTransport = h.transports.last;
    newTransport.connect();
    await _settle();
    final events = <TripRealtimeEvent>[];
    second.events.listen(events.add);
    newTransport.message(_status(bookingB, 'COMPLETED'));
    newTransport.message(_location(bookingB));
    await _settle();
    expect(events.length, 1);
    expect((events.single as TripStatusChangedEvent).status, 'COMPLETED');
    expect(
        await second.sendLocation(const DriverCoordinates(21, 105),
            sampledAt: h.now),
        isFalse);
    await second.dispose();
  });

  test('parser rejects malformed coordinates, timestamps, types and status',
      () {
    expect(parseTripRealtimeEvent(_location(bookingA), bookingA),
        isA<TripDriverLocationEvent>());
    expect(parseTripRealtimeEvent(_location(bookingB), bookingA), isNull);
    expect(
        parseTripRealtimeEvent(_status(bookingA, 'FUTURE'), bookingA), isNull);
    expect(
        parseTripRealtimeEvent(
            jsonEncode({
              'type': 'DRIVER_LOCATION_UPDATED',
              'bookingPublicId': bookingA,
              'latitude': 91,
              'longitude': 105,
              'recordedAt': '2026-10-16T10:00:00Z',
            }),
            bookingA),
        isNull);
    expect(
        parseTripRealtimeEvent(
            jsonEncode({
              'type': 'DRIVER_LOCATION_UPDATED',
              'bookingPublicId': bookingA,
              'latitude': 21,
              'longitude': 105,
              'recordedAt': 'not-a-date',
            }),
            bookingA),
        isNull);
  });
}
