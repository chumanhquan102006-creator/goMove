import 'dart:async';
import 'dart:convert';

import 'package:stomp_dart_client/stomp_dart_client.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../driver/domain/models/driver_models.dart';

enum TripRealtimeConnectionState {
  connecting,
  connected,
  reconnecting,
  disconnected,
  failed,
}

abstract class TripRealtimeEvent {
  String get bookingPublicId;
}

class TripStatusChangedEvent implements TripRealtimeEvent {
  @override
  final String bookingPublicId;
  final String status;
  final DateTime occurredAt;

  const TripStatusChangedEvent(
      this.bookingPublicId, this.status, this.occurredAt);
}

class TripDriverLocationEvent implements TripRealtimeEvent {
  @override
  final String bookingPublicId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? bearing;
  final DateTime recordedAt;

  const TripDriverLocationEvent(this.bookingPublicId, this.latitude,
      this.longitude, this.accuracy, this.bearing, this.recordedAt);
}

/// Returns null for an unknown, malformed, or cross-booking broker message.
TripRealtimeEvent? parseTripRealtimeEvent(
    String? body, String bookingPublicId) {
  if (body == null) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> ||
        decoded['bookingPublicId'] is! String ||
        (decoded['bookingPublicId'] as String).toLowerCase() !=
            bookingPublicId.toLowerCase()) {
      return null;
    }
    final id = decoded['bookingPublicId'] as String;
    if (decoded['type'] == 'TRIP_STATUS_CHANGED') {
      final status = decoded['status'];
      final timestamp = decoded['occurredAt'];
      if (status is! String ||
          !const {
            'DRIVER_ACCEPTED',
            'DRIVER_ARRIVED',
            'PASSENGER_ONBOARD',
            'IN_PROGRESS',
            'COMPLETED',
          }.contains(status) ||
          timestamp is! String) {
        return null;
      }
      return TripStatusChangedEvent(
          id, status, DateTime.parse(timestamp).toUtc());
    }
    if (decoded['type'] == 'DRIVER_LOCATION_UPDATED') {
      final latitude = _finiteNumber(decoded['latitude']);
      final longitude = _finiteNumber(decoded['longitude']);
      final accuracy = decoded['accuracy'] == null
          ? null
          : _finiteNumber(decoded['accuracy']);
      final bearing =
          decoded['bearing'] == null ? null : _finiteNumber(decoded['bearing']);
      final timestamp = decoded['recordedAt'];
      if (latitude == null ||
          latitude < -90 ||
          latitude > 90 ||
          longitude == null ||
          longitude < -180 ||
          longitude > 180 ||
          (decoded['accuracy'] != null && accuracy == null) ||
          (accuracy != null && accuracy < 0) ||
          (decoded['bearing'] != null && bearing == null) ||
          (bearing != null && (bearing < 0 || bearing >= 360)) ||
          timestamp is! String) {
        return null;
      }
      return TripDriverLocationEvent(id, latitude, longitude, accuracy, bearing,
          DateTime.parse(timestamp).toUtc());
    }
  } catch (_) {
    // A broker frame is not trusted state; keep REST reconciliation available.
  }
  return null;
}

double? _finiteNumber(Object? value) =>
    value is num && value.toDouble().isFinite ? value.toDouble() : null;

abstract class TripRealtimeClient {
  TripRealtimeSubscription listen({
    required String bookingPublicId,
    required int sessionGeneration,
    required bool driver,
    required Future<void> Function() reconcileBeforeEvents,
  });
}

abstract class TripRealtimeSubscription {
  Stream<TripRealtimeEvent> get events;
  Stream<TripRealtimeConnectionState> get connectionStates;
  TripRealtimeConnectionState get state;

  /// A false result means no SEND was made. [sampledAt] is local validation
  /// metadata and is never placed in the STOMP JSON payload.
  Future<bool> sendLocation(DriverCoordinates point,
      {required DateTime sampledAt});
  Future<void> dispose();
}

/// Small transport seam permits deterministic tests without opening a socket.
abstract class TripStompTransport {
  bool get connected;
  void activate();
  void deactivate();
  void Function() subscribe(String destination, void Function(String?) onBody);
  void send(String destination, String body);
}

typedef TripStompTransportFactory = TripStompTransport Function(
    StompConfig config);

class _StompDartTransport implements TripStompTransport {
  final StompClient _client;
  _StompDartTransport(StompConfig config)
      : _client = StompClient(config: config);

  @override
  bool get connected => _client.connected;
  @override
  void activate() => _client.activate();
  @override
  void deactivate() => _client.deactivate();
  @override
  void Function() subscribe(String destination, void Function(String?) onBody) {
    final unsubscribe = _client.subscribe(
        destination: destination, callback: (frame) => onBody(frame.body));
    return () => unsubscribe();
  }

  @override
  void send(String destination, String body) => _client.send(
      destination: destination,
      headers: const {'content-type': 'application/json'},
      body: body);
}

class TripRealtimeClientImpl implements TripRealtimeClient {
  final AppConfig config;
  final SecureStorageService session;
  final TripStompTransportFactory _transportFactory;
  final DateTime Function() _now;
  final Duration reconnectBaseDelay;
  final Duration tokenCheckInterval;
  _TripRealtimeSubscription? _active;

  TripRealtimeClientImpl({
    required this.config,
    required this.session,
    TripStompTransportFactory? transportFactory,
    DateTime Function()? now,
    this.reconnectBaseDelay = const Duration(seconds: 3),
    this.tokenCheckInterval = const Duration(seconds: 15),
  })  : _transportFactory = transportFactory ?? _StompDartTransport.new,
        _now = now ?? DateTime.now;

  @override
  TripRealtimeSubscription listen({
    required String bookingPublicId,
    required int sessionGeneration,
    required bool driver,
    required Future<void> Function() reconcileBeforeEvents,
  }) {
    _active?._stop();
    final subscription = _TripRealtimeSubscription(
      config: config,
      session: session,
      transportFactory: _transportFactory,
      now: _now,
      reconnectBaseDelay: reconnectBaseDelay,
      tokenCheckInterval: tokenCheckInterval,
      bookingPublicId: bookingPublicId,
      sessionGeneration: sessionGeneration,
      driver: driver,
      reconcileBeforeEvents: reconcileBeforeEvents,
    );
    _active = subscription;
    subscription._start();
    return subscription;
  }
}

class _TripRealtimeSubscription implements TripRealtimeSubscription {
  static final _uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  final AppConfig config;
  final SecureStorageService session;
  final TripStompTransportFactory transportFactory;
  final DateTime Function() now;
  final Duration reconnectBaseDelay;
  final Duration tokenCheckInterval;
  final String bookingPublicId;
  final int sessionGeneration;
  final bool driver;
  final Future<void> Function() reconcileBeforeEvents;
  final _events = StreamController<TripRealtimeEvent>.broadcast();
  final _states = StreamController<TripRealtimeConnectionState>.broadcast();
  final _pendingBodies = <String?>[];

  TripStompTransport? _transport;
  void Function()? _unsubscribe;
  Timer? _retryTimer;
  Timer? _tokenTimer;
  Future<void> _eventTail = Future<void>.value();
  TripRealtimeConnectionState _state = TripRealtimeConnectionState.connecting;
  DateTime? _lastSentSampleAt;
  int _epoch = 0;
  int _failureCount = 0;
  String? _connectedToken;
  bool _stopped = false;
  bool _ready = false;
  bool _sending = false;
  bool _completed = false;
  bool _everConnected = false;
  bool _checkingToken = false;

  _TripRealtimeSubscription({
    required this.config,
    required this.session,
    required this.transportFactory,
    required this.now,
    required this.reconnectBaseDelay,
    required this.tokenCheckInterval,
    required this.bookingPublicId,
    required this.sessionGeneration,
    required this.driver,
    required this.reconcileBeforeEvents,
  });

  @override
  Stream<TripRealtimeEvent> get events => _events.stream;
  @override
  Stream<TripRealtimeConnectionState> get connectionStates => _states.stream;
  @override
  TripRealtimeConnectionState get state => _state;

  bool _currentEpoch(int epoch) => !_stopped && epoch == _epoch;

  void _setState(TripRealtimeConnectionState value) {
    if (_state == value) return;
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  void _start() {
    final uri = Uri.tryParse(config.wsBaseUrl);
    if (!_uuid.hasMatch(bookingPublicId) ||
        uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      _setState(TripRealtimeConnectionState.failed);
      return;
    }
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_stopped) return;
    final epoch = ++_epoch;
    _ready = false;
    _pendingBodies.clear();
    _setState(_failureCount == 0 && !_everConnected
        ? TripRealtimeConnectionState.connecting
        : TripRealtimeConnectionState.reconnecting);
    try {
      var snapshot = await session.getSession();
      if (!_currentEpoch(epoch)) return;
      if (snapshot.generation != sessionGeneration) {
        _stop();
        return;
      }
      if (_tokenExpired(snapshot.accessToken)) {
        // A protected REST read uses the existing 401/refresh path. A new
        // STOMP CONNECT must never reuse the expired JWT.
        await reconcileBeforeEvents();
        snapshot = await session.getSession();
        if (!_currentEpoch(epoch)) return;
        if (snapshot.generation != sessionGeneration) {
          _stop();
          return;
        }
      }
      final token = snapshot.accessToken;
      if (token == null || token.isEmpty || _tokenExpired(token)) {
        _failed(epoch);
        return;
      }
      final transport = transportFactory(StompConfig(
        url: config.wsBaseUrl,
        reconnectDelay: Duration.zero,
        connectionTimeout: config.connectTimeout,
        stompConnectHeaders: {'Authorization': 'Bearer $token'},
        onConnect: (_) => unawaited(_connected(epoch)),
        onStompError: (_) => _failed(epoch),
        onWebSocketError: (_) => _failed(epoch),
        onWebSocketDone: () => _failed(epoch),
        // The package's debug frames include CONNECT headers. Never log them.
        onDebugMessage: (_) {},
      ));
      if (!_currentEpoch(epoch)) {
        transport.deactivate();
        return;
      }
      _transport = transport;
      _connectedToken = token;
      transport.activate();
    } catch (_) {
      _failed(epoch);
    }
  }

  Future<void> _connected(int epoch) async {
    if (!_currentEpoch(epoch)) return;
    final transport = _transport;
    if (transport == null || !transport.connected) return;
    try {
      if (!await session.isCurrentSession(sessionGeneration)) {
        _stop();
        return;
      }
      if (!_currentEpoch(epoch)) return;
      _unsubscribe = transport.subscribe(
          '/topic/ride/$bookingPublicId', (body) => _received(epoch, body));
      // The subscription is in place first. Frames are buffered until the
      // durable REST state has been fetched successfully.
      await reconcileBeforeEvents();
      if (!_currentEpoch(epoch)) return;
      if (!await session.isCurrentSession(sessionGeneration)) {
        _stop();
        return;
      }
      if (!_currentEpoch(epoch) || !transport.connected) return;
      _failureCount = 0;
      _everConnected = true;
      _ready = true;
      _setState(TripRealtimeConnectionState.connected);
      _tokenTimer?.cancel();
      _tokenTimer =
          Timer.periodic(tokenCheckInterval, (_) => unawaited(_checkToken()));
      final buffered = List<String?>.of(_pendingBodies);
      _pendingBodies.clear();
      for (final body in buffered) {
        _received(epoch, body);
      }
    } catch (_) {
      _failed(epoch);
    }
  }

  bool _tokenExpired(String? token) {
    if (token == null) return false;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (payload is! Map<String, dynamic> || payload['exp'] is! num) {
        return false;
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch(
          ((payload['exp'] as num) * 1000).toInt(),
          isUtc: true);
      return !now().toUtc().isBefore(expiry);
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkToken() async {
    if (_stopped || !_ready || _checkingToken) return;
    _checkingToken = true;
    final epoch = _epoch;
    try {
      var snapshot = await session.getSession();
      if (!_currentEpoch(epoch)) return;
      if (snapshot.generation != sessionGeneration) {
        _stop();
        return;
      }
      if (snapshot.accessToken != _connectedToken) {
        _restart(epoch);
        return;
      }
      if (_tokenExpired(snapshot.accessToken)) {
        // Outbound private frames are dropped by the Backend once the JWT
        // expires, even if this WebSocket still appears connected.
        _ready = false;
        _setState(TripRealtimeConnectionState.reconnecting);
        await reconcileBeforeEvents();
        snapshot = await session.getSession();
        if (!_currentEpoch(epoch)) return;
        if (snapshot.generation != sessionGeneration) {
          _stop();
        } else if (snapshot.accessToken != _connectedToken) {
          _restart(epoch);
        } else {
          _failed(epoch);
        }
      }
    } catch (_) {
      _failed(epoch);
    } finally {
      _checkingToken = false;
    }
  }

  void _restart(int epoch) {
    if (!_currentEpoch(epoch)) return;
    _epoch++;
    _ready = false;
    _pendingBodies.clear();
    _disconnectTransport();
    _setState(TripRealtimeConnectionState.reconnecting);
    unawaited(_connect());
  }

  void _received(int epoch, String? body) {
    if (!_currentEpoch(epoch)) return;
    if (!_ready) {
      if (_pendingBodies.length < 64) {
        _pendingBodies.add(body);
      } else {
        // A saturated buffer cannot be trusted as a complete event history.
        _failed(epoch);
      }
      return;
    }
    _eventTail = _eventTail.then((_) async {
      if (!_currentEpoch(epoch) || !_ready) return;
      if (!await session.isCurrentSession(sessionGeneration)) {
        _stop();
        return;
      }
      if (!_currentEpoch(epoch)) return;
      final event = parseTripRealtimeEvent(body, bookingPublicId);
      if (event == null || _completed) return;
      if (event is TripStatusChangedEvent && event.status == 'COMPLETED') {
        _completed = true;
      }
      if (!_events.isClosed) _events.add(event);
    }).catchError((Object _) {
      // Malformed frames cannot mutate trip state.
    });
  }

  @override
  Future<bool> sendLocation(DriverCoordinates point,
      {required DateTime sampledAt}) async {
    if (!driver || _stopped || _sending || !_ready || _completed) return false;
    final epoch = _epoch;
    final transport = _transport;
    if (transport == null || !transport.connected) return false;
    final age = now().toUtc().difference(sampledAt.toUtc());
    if (age.isNegative ||
        age > const Duration(seconds: 30) ||
        (_lastSentSampleAt != null && !sampledAt.isAfter(_lastSentSampleAt!)) ||
        !point.latitude.isFinite ||
        point.latitude < -90 ||
        point.latitude > 90 ||
        !point.longitude.isFinite ||
        point.longitude < -180 ||
        point.longitude > 180 ||
        (point.accuracy != null &&
            (!point.accuracy!.isFinite || point.accuracy! < 0)) ||
        (point.bearing != null &&
            (!point.bearing!.isFinite ||
                point.bearing! < 0 ||
                point.bearing! >= 360))) {
      return false;
    }
    _sending = true;
    try {
      if (!await session.isCurrentSession(sessionGeneration) ||
          !_currentEpoch(epoch) ||
          !_ready ||
          _completed) {
        return false;
      }
      transport.send(
          '/app/ride/$bookingPublicId/location',
          jsonEncode({
            'latitude': point.latitude,
            'longitude': point.longitude,
            if (point.accuracy != null) 'accuracy': point.accuracy,
            if (point.bearing != null) 'bearing': point.bearing,
          }));
      _lastSentSampleAt = sampledAt;
      return true;
    } catch (_) {
      _failed(epoch);
      return false;
    } finally {
      _sending = false;
    }
  }

  void _failed(int epoch) {
    if (!_currentEpoch(epoch)) return;
    _epoch++;
    _ready = false;
    _pendingBodies.clear();
    _disconnectTransport();
    _setState(TripRealtimeConnectionState.failed);
    _failureCount++;
    final multiplier = 1 << (_failureCount - 1).clamp(0, 3);
    final delayMs = (reconnectBaseDelay.inMilliseconds * multiplier)
        .clamp(1, const Duration(seconds: 30).inMilliseconds);
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_stopped) unawaited(_connect());
    });
  }

  void _disconnectTransport() {
    _tokenTimer?.cancel();
    _tokenTimer = null;
    _connectedToken = null;
    try {
      _unsubscribe?.call();
    } catch (_) {}
    _unsubscribe = null;
    try {
      _transport?.deactivate();
    } catch (_) {}
    _transport = null;
  }

  void _stop() {
    if (_stopped) return;
    _stopped = true;
    _epoch++;
    _ready = false;
    _pendingBodies.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _disconnectTransport();
    _setState(TripRealtimeConnectionState.disconnected);
    unawaited(_events.close());
    unawaited(_states.close());
  }

  @override
  Future<void> dispose() async => _stop();
}
