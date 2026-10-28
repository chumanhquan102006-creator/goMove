import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../customer/domain/models/quote.dart';
import '../../domain/models/road_route.dart';
import '../../domain/repositories/road_route_repository.dart';

/// Loads a static route once for the authenticated session that opened this
/// screen. Server ownership checks remain authoritative; a public UUID alone
/// never grants access. Any failure leaves the booking/trip UI usable.
class AuthorizedRoadRoute extends StatefulWidget {
  final String publicId;
  final String? expectedSourceQuotePublicId;
  final bool isQuote;
  final Coordinates? pickup;
  final Coordinates? dropoff;
  final Widget Function(BuildContext context, RoadRoute? route) builder;
  final RoadRouteRepository? repository;
  final SecureStorageService? session;

  const AuthorizedRoadRoute({
    super.key,
    required this.publicId,
    this.expectedSourceQuotePublicId,
    required this.isQuote,
    required this.builder,
    this.pickup,
    this.dropoff,
    this.repository,
    this.session,
  });

  @override
  State<AuthorizedRoadRoute> createState() => _AuthorizedRoadRouteState();
}

class _AuthorizedRoadRouteState extends State<AuthorizedRoadRoute>
    with WidgetsBindingObserver {
  RoadRoute? _route;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant AuthorizedRoadRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.publicId != widget.publicId ||
        oldWidget.expectedSourceQuotePublicId !=
            widget.expectedSourceQuotePublicId ||
        oldWidget.isQuote != widget.isQuote ||
        oldWidget.repository != widget.repository ||
        oldWidget.session != widget.session) {
      _route = null;
      _request++;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Hide private route data before the async session check can complete.
      _route = null;
      _request++;
      setState(() {});
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    final repository = widget.repository ??
        (sl.isRegistered<RoadRouteRepository>()
            ? sl<RoadRouteRepository>()
            : null);
    final session = widget.session ??
        (sl.isRegistered<SecureStorageService>()
            ? sl<SecureStorageService>()
            : null);
    if (repository == null || session == null) return;
    try {
      final snapshot = await session.getSession();
      if (!mounted || request != _request || snapshot.accessToken == null) {
        return;
      }
      final response = widget.isQuote
          ? await repository.quote(widget.publicId, snapshot.generation)
          : await repository.booking(widget.publicId, snapshot.generation);
      if (!mounted ||
          request != _request ||
          !await session.isCurrentSession(snapshot.generation)) {
        return;
      }
      final matchesId = widget.isQuote
          ? response.sourceQuotePublicId == widget.publicId &&
              response.bookingPublicId == null
          : response.bookingPublicId == widget.publicId &&
              (widget.expectedSourceQuotePublicId == null ||
                  response.sourceQuotePublicId ==
                      widget.expectedSourceQuotePublicId);
      final matchesPoints = widget.pickup == null ||
          widget.dropoff == null ||
          response.matchesEndpoints(widget.pickup!, widget.dropoff!);
      setState(() => _route =
          response.available && matchesId && matchesPoints ? response : null);
    } catch (_) {
      // 401/403/404, legacy geometry and malformed responses all omit the line.
      if (mounted && request == _request) setState(() => _route = null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _route);
}
