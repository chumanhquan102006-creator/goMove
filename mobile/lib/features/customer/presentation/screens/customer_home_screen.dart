import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../driver/presentation/screens/driver_onboarding_screen.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/models/place_search_result.dart';
import '../../domain/repositories/geocoding_repository.dart';
import '../bloc/booking_cubit.dart';
import '../bloc/customer_active_booking_cubit.dart';
import '../bloc/quote_cubit.dart';
import 'booking_status_screen.dart';
import 'customer_map_canvas.dart';
import 'quote_review_screen.dart';
import 'trip_history_screen.dart';

class CustomerHomeScreen extends StatelessWidget {
  final User user;
  final CustomerMapBuilder? mapBuilder;
  const CustomerHomeScreen({super.key, required this.user, this.mapBuilder});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
        key: ValueKey(user.publicId),
        providers: [
          BlocProvider(create: (_) => sl<QuoteCubit>()),
          BlocProvider(
              create: (_) =>
                  sl<BookingCubit>(param1: user.publicId)..restore()),
          BlocProvider(
              create: (_) =>
                  sl<CustomerActiveBookingCubit>(param1: user.publicId)
                    ..restore()),
        ],
        child: _CustomerHomeContent(user: user, mapBuilder: mapBuilder),
      );
}

class _CustomerHomeContent extends StatefulWidget {
  final User user;
  final CustomerMapBuilder? mapBuilder;
  const _CustomerHomeContent({required this.user, this.mapBuilder});
  @override
  State<_CustomerHomeContent> createState() => _CustomerHomeContentState();
}

enum _MapTarget { pickup, dropoff }

class _PlaceSelection {
  final query = TextEditingController();
  Timer? debounce;
  int revision = 0;
  List<PlaceSearchResult> suggestions = const [];
  bool loading = false;
  String? message;
  String? label;
  String? attribution;
  Coordinates? labelPoint;

  void dispose() {
    debounce?.cancel();
    query.dispose();
  }
}

class _CustomerHomeContentState extends State<_CustomerHomeContent>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _pickupLat = TextEditingController(text: '21.0287');
  final _pickupLon = TextEditingController(text: '105.8524');
  final _dropoffLat = TextEditingController(text: '21.0245');
  final _dropoffLon = TextEditingController(text: '105.8576');
  _MapTarget _mapTarget = _MapTarget.pickup;
  VehicleType _vehicle = VehicleType.motorbike;
  String? _coordinateError;
  bool _mapVisible = true;
  bool _foreground = true;
  bool _authInvalidated = false;
  final _pickupPlace = _PlaceSelection();
  final _dropoffPlace = _PlaceSelection();
  int _pickupReverseRevision = 0;
  int _dropoffReverseRevision = 0;
  bool _settingCoordinates = false;

  _PlaceSelection _selection(_MapTarget target) =>
      target == _MapTarget.pickup ? _pickupPlace : _dropoffPlace;

  bool get _isCurrentAccount {
    final auth = context.read<AuthBloc>().state;
    return auth is AuthenticatedState &&
        auth.user.publicId == widget.user.publicId;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickupLat.addListener(_onPickupCoordinateEdited);
    _pickupLon.addListener(_onPickupCoordinateEdited);
    _dropoffLat.addListener(_onDropoffCoordinateEdited);
    _dropoffLon.addListener(_onDropoffCoordinateEdited);
  }

  void _onPickupCoordinateEdited() => _onCoordinateEdited(_MapTarget.pickup);
  void _onDropoffCoordinateEdited() => _onCoordinateEdited(_MapTarget.dropoff);

  void _onCoordinateEdited(_MapTarget target) {
    if (_settingCoordinates || !mounted) return;
    final selection = _selection(target);
    selection.debounce?.cancel();
    selection.revision++;
    selection.query.clear();
    setState(() {
      _coordinateError = null;
      selection.suggestions = const [];
      selection.loading = false;
      selection.label = null;
      selection.attribution = null;
      selection.labelPoint = null;
      selection.message = 'Chưa có địa chỉ được xác minh cho tọa độ này.';
      if (target == _MapTarget.pickup) {
        _pickupReverseRevision++;
      } else {
        _dropoffReverseRevision++;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && _isCurrentAccount) {
      context.read<CustomerActiveBookingCubit>().restore();
      if (mounted) setState(() {});
    } else if (state != AppLifecycleState.resumed) {
      for (final selection in [_pickupPlace, _dropoffPlace]) {
        selection.debounce?.cancel();
        selection.revision++;
        selection.suggestions = const [];
        selection.loading = false;
        if (selection.message == 'Đang tìm địa chỉ cho điểm đã chọn…') {
          selection.message = 'Địa chỉ chưa khả dụng cho điểm này.';
        }
      }
      _pickupReverseRevision++;
      _dropoffReverseRevision++;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pickupLat.removeListener(_onPickupCoordinateEdited);
    _pickupLon.removeListener(_onPickupCoordinateEdited);
    _dropoffLat.removeListener(_onDropoffCoordinateEdited);
    _dropoffLon.removeListener(_onDropoffCoordinateEdited);
    for (final controller in [
      _pickupLat,
      _pickupLon,
      _dropoffLat,
      _dropoffLon
    ]) {
      controller.dispose();
    }
    _pickupPlace.dispose();
    _dropoffPlace.dispose();
    super.dispose();
  }

  Future<void> _openBooking(Booking booking) async {
    if (!_isCurrentAccount) return;
    final recovery = context.read<CustomerActiveBookingCubit>();
    setState(() => _mapVisible = false);
    try {
      await Navigator.of(context).push(AppMotion.immediateRoute<void>(
          BookingStatusScreen(booking: booking)));
    } finally {
      if (mounted && _isCurrentAccount) {
        setState(() => _mapVisible = true);
        await recovery.refresh();
      }
    }
  }

  void _openHistory() {
    if (!_isCurrentAccount || AppConfig.instance.isMock) return;
    Navigator.of(context).push(AppMotion.immediateRoute<void>(
        TripHistoryScreen(customerPublicId: widget.user.publicId)));
  }

  Future<void> _recoverExistingBooking() async {
    final form = GlobalKey<FormState>();
    var input = '';
    final publicId = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Khôi phục Booking bằng UUID'),
              content: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'Chỉ Booking thuộc tài khoản đang đăng nhập mới được khôi phục. Máy chủ sẽ kiểm tra quyền truy cập trước khi hiển thị.'),
                    const SizedBox(height: 12),
                    TextFormField(
                      onChanged: (value) => input = value,
                      maxLength: 36,
                      decoration: const InputDecoration(
                          labelText: 'Booking public UUID',
                          border: OutlineInputBorder()),
                      validator: (value) =>
                          RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
                                  .hasMatch((value ?? '').trim())
                              ? null
                              : 'Nhập đúng UUID của Booking',
                    ),
                  ]),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Hủy')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState?.validate() ?? false) {
                        Navigator.pop(dialog, input.trim());
                      }
                    },
                    child: const Text('Kiểm tra Booking')),
              ],
            ));
    if (publicId != null && mounted && _isCurrentAccount) {
      await context
          .read<CustomerActiveBookingCubit>()
          .recoverByPublicId(publicId);
    }
  }

  Widget _coordinate(String label, TextEditingController controller, double min,
          double max) =>
      TextFormField(
        controller: controller,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.next,
        scrollPadding: const EdgeInsets.only(bottom: 96),
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        validator: (value) {
          final number = double.tryParse((value ?? '').trim());
          return number == null ||
                  !number.isFinite ||
                  number < min ||
                  number > max
              ? 'Nhập tọa độ từ $min đến $max'
              : null;
        },
      );

  Coordinates? _point(
      TextEditingController latitude, TextEditingController longitude) {
    final lat = double.tryParse(latitude.text.trim());
    final lon = double.tryParse(longitude.text.trim());
    if (lat == null || lon == null) return null;
    final point = Coordinates(lat, lon);
    return point.isValid ? point : null;
  }

  Coordinates? _pointFor(_MapTarget target) => target == _MapTarget.pickup
      ? _point(_pickupLat, _pickupLon)
      : _point(_dropoffLat, _dropoffLon);

  bool _samePoint(Coordinates? a, Coordinates? b) =>
      a != null &&
      b != null &&
      a.latitude == b.latitude &&
      a.longitude == b.longitude;

  bool _canUseSearch(_PlaceSelection selection, int revision) =>
      mounted &&
      _foreground &&
      _isCurrentAccount &&
      revision == selection.revision;

  bool _canUseReverse(_MapTarget target, int revision, Coordinates point) =>
      mounted &&
      _foreground &&
      _isCurrentAccount &&
      revision ==
          (target == _MapTarget.pickup
              ? _pickupReverseRevision
              : _dropoffReverseRevision) &&
      _samePoint(_pointFor(target), point);

  Future<bool> _sessionStillCurrent(
      SecureStorageService session, int generation) async {
    try {
      return await session.isCurrentSession(generation);
    } catch (_) {
      return false;
    }
  }

  String? _selectedLabel(_MapTarget target, Coordinates? point) {
    final selected = _selection(target);
    return _samePoint(selected.labelPoint, point) ? selected.label : null;
  }

  void _setPoint(_MapTarget target, Coordinates point,
      {String? label, String? attribution}) {
    final selected = _selection(target);
    selected.debounce?.cancel();
    selected.revision++;
    selected.query.text = label ?? '';
    _settingCoordinates = true;
    try {
      if (target == _MapTarget.pickup) {
        _pickupLat.text = point.latitude.toString();
        _pickupLon.text = point.longitude.toString();
        _pickupReverseRevision++;
      } else {
        _dropoffLat.text = point.latitude.toString();
        _dropoffLon.text = point.longitude.toString();
        _dropoffReverseRevision++;
      }
    } finally {
      _settingCoordinates = false;
    }
    setState(() {
      _coordinateError = null;
      selected.suggestions = const [];
      selected.loading = false;
      selected.label = label;
      selected.attribution = attribution;
      selected.labelPoint = label == null ? null : point;
      selected.message =
          label == null ? 'Đang tìm địa chỉ cho điểm đã chọn…' : null;
    });
  }

  String _lookupError(Object error) {
    if (error is ServerException && error.statusCode == 429) {
      return 'Dịch vụ địa điểm đang giới hạn yêu cầu. Hãy thử lại sau hoặc nhập tọa độ.';
    }
    if (error is FormatException) return error.message;
    return 'Không tìm được địa chỉ lúc này. Bạn vẫn có thể chọn trên bản đồ hoặc nhập tọa độ.';
  }

  void _onSearchChanged(_MapTarget target, String query) {
    final selected = _selection(target);
    selected.debounce?.cancel();
    final revision = ++selected.revision;
    final normalized = query.trim();
    setState(() {
      selected.suggestions = const [];
      selected.loading = false;
      selected.message = normalized.isEmpty
          ? null
          : normalized.runes.length < 3
              ? 'Nhập ít nhất 3 ký tự để tìm địa điểm.'
              : null;
    });
    if (normalized.runes.length < 3) return;
    selected.debounce = Timer(const Duration(milliseconds: 400),
        () => unawaited(_search(target, normalized, revision)));
  }

  Future<void> _search(_MapTarget target, String query, int revision) async {
    final selected = _selection(target);
    if (!_canUseSearch(selected, revision)) return;
    if (AppConfig.instance.isMock ||
        !sl.isRegistered<GeocodingRepository>() ||
        !sl.isRegistered<SecureStorageService>()) {
      setState(() => selected.message =
          'Tìm địa điểm cần kết nối Backend GoMove ở chế độ thật.');
      return;
    }
    setState(() => selected.loading = true);
    int? requestGeneration;
    try {
      final session = sl<SecureStorageService>();
      final snapshot = await session.getSession();
      requestGeneration = snapshot.generation;
      if (!_canUseSearch(selected, revision)) {
        return;
      }
      if (snapshot.accessToken == null) {
        setState(() {
          selected.loading = false;
          selected.message = 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.';
        });
        return;
      }
      final results = await sl<GeocodingRepository>()
          .search(query, sessionGeneration: snapshot.generation);
      if (!_canUseSearch(selected, revision)) {
        return;
      }
      final current = await _sessionStillCurrent(session, snapshot.generation);
      if (!current || !_canUseSearch(selected, revision)) {
        return;
      }
      setState(() {
        selected.suggestions = results.take(5).toList(growable: false);
        selected.loading = false;
        selected.message =
            results.isEmpty ? 'Không tìm thấy địa điểm phù hợp.' : null;
      });
    } catch (error) {
      if (!_canUseSearch(selected, revision)) {
        return;
      }
      if (requestGeneration != null &&
          !await _sessionStillCurrent(
              sl<SecureStorageService>(), requestGeneration)) {
        return;
      }
      if (!_canUseSearch(selected, revision)) {
        return;
      }
      setState(() {
        selected.loading = false;
        selected.message = _lookupError(error);
      });
    }
  }

  Future<void> _reverseSelected(_MapTarget target, Coordinates point) async {
    final revision = target == _MapTarget.pickup
        ? _pickupReverseRevision
        : _dropoffReverseRevision;
    if (!_canUseReverse(target, revision, point)) return;
    if (!sl.isRegistered<GeocodingRepository>() ||
        !sl.isRegistered<SecureStorageService>() ||
        AppConfig.instance.isMock) {
      if (mounted) {
        setState(() => _selection(target).message =
            'Chưa có địa chỉ cho điểm này; tọa độ đã chọn vẫn được giữ.');
      }
      return;
    }
    int? requestGeneration;
    try {
      final session = sl<SecureStorageService>();
      final snapshot = await session.getSession();
      requestGeneration = snapshot.generation;
      if (!_canUseReverse(target, revision, point) ||
          snapshot.accessToken == null) {
        return;
      }
      final result = await sl<GeocodingRepository>()
          .reverse(point, sessionGeneration: snapshot.generation);
      if (!_canUseReverse(target, revision, point)) {
        return;
      }
      final current = await _sessionStillCurrent(session, snapshot.generation);
      if (!current || !_canUseReverse(target, revision, point)) {
        return;
      }
      final validResult =
          result != null && _samePoint(result.coordinates, point);
      setState(() {
        final selected = _selection(target);
        selected.label = validResult ? result.label : null;
        selected.attribution = validResult ? result.attribution : null;
        selected.labelPoint = validResult ? point : null;
        selected.message = validResult
            ? null
            : 'Chưa tìm được địa chỉ cho điểm này; tọa độ đã chọn vẫn được giữ.';
      });
    } catch (_) {
      if (!_canUseReverse(target, revision, point)) {
        return;
      }
      if (requestGeneration != null &&
          !await _sessionStillCurrent(
              sl<SecureStorageService>(), requestGeneration)) {
        return;
      }
      if (!_canUseReverse(target, revision, point)) {
        return;
      }
      setState(() => _selection(target).message =
          'Không thể xác minh địa chỉ lúc này; tọa độ đã chọn vẫn được giữ.');
    }
  }

  Widget _searchBox(_MapTarget target) {
    final selected = _selection(target);
    final pickup = target == _MapTarget.pickup;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: ValueKey(pickup ? 'pickup-place-search' : 'dropoff-place-search'),
        controller: selected.query,
        textInputAction: TextInputAction.search,
        maxLength: 100,
        scrollPadding: const EdgeInsets.only(bottom: 120),
        decoration: InputDecoration(
          labelText: pickup ? 'Tìm điểm đón' : 'Tìm điểm đến',
          hintText: 'Tên địa điểm hoặc địa chỉ',
          prefixIcon: Icon(pickup ? Icons.trip_origin : Icons.location_on),
          border: const OutlineInputBorder(),
          suffixIcon: selected.loading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : null,
        ),
        onChanged: (query) => _onSearchChanged(target, query),
      ),
      if (selected.message != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(selected.message!,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      for (final result in selected.suggestions)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: Icon(pickup ? Icons.trip_origin : Icons.location_on),
          title: Text(result.name ?? result.label,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              [
                if (result.name != null) result.label,
                if (result.street != null &&
                    !result.label.contains(result.street!))
                  result.street!,
                if (result.district != null &&
                    !result.label.contains(result.district!))
                  result.district!,
                if (result.city != null && !result.label.contains(result.city!))
                  result.city!,
                '${result.coordinates.latitude.toStringAsFixed(6)}, '
                    '${result.coordinates.longitude.toStringAsFixed(6)}',
                if (result.attribution != null) result.attribution!,
              ].join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
          onTap: () {
            if (!_isCurrentAccount) return;
            FocusScope.of(context).unfocus();
            _setPoint(target, result.coordinates,
                label: result.label, attribution: result.attribution);
          },
        ),
    ]);
  }

  void _selectMapPoint(Coordinates point) {
    if (!_isCurrentAccount || !point.isValid) return;
    FocusScope.of(context).unfocus();
    final target = _mapTarget;
    _setPoint(target, point);
    unawaited(_reverseSelected(target, point));
  }

  Widget _pointSummary(
      String label, Coordinates? point, Color color, _MapTarget target) {
    final selected = _mapTarget == target;
    final coordinateLabel = point == null
        ? 'Chưa có tọa độ hợp lệ'
        : 'Vĩ độ ${point.latitude.toStringAsFixed(6)} · Kinh độ ${point.longitude.toStringAsFixed(6)}';
    final address = _selectedLabel(target, point);
    final selection = _selection(target);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        key: ValueKey('$target-point-summary-motion'),
        duration: AppMotion.duration(context, AppMotion.touch),
        curve: AppMotion.enterCurve,
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(20) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _mapTarget = target),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(
                  target == _MapTarget.pickup
                      ? Icons.trip_origin
                      : Icons.location_on,
                  color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                        address ??
                            selection.message ??
                            'Chưa có địa chỉ được xác minh',
                        style: Theme.of(context).textTheme.bodyMedium),
                    if (address != null && selection.attribution != null)
                      Text(selection.attribution!,
                          style: Theme.of(context).textTheme.bodySmall),
                    AnimatedSwitcher(
                      duration: AppMotion.duration(context, AppMotion.feedback),
                      switchInCurve: AppMotion.enterCurve,
                      switchOutCurve: AppMotion.exitCurve,
                      child: Text(coordinateLabel,
                          key: ValueKey(coordinateLabel),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle,
                    size: 20, color: Theme.of(context).colorScheme.primary),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _coordinatePair(
      String firstLabel,
      TextEditingController first,
      double firstMin,
      double firstMax,
      String secondLabel,
      TextEditingController second,
      double secondMin,
      double secondMax) {
    return LayoutBuilder(builder: (context, constraints) {
      final firstField = _coordinate(firstLabel, first, firstMin, firstMax);
      final secondField =
          _coordinate(secondLabel, second, secondMin, secondMax);
      if (constraints.maxWidth < 350) {
        return Column(children: [
          firstField,
          const SizedBox(height: 10),
          secondField,
        ]);
      }
      return Row(children: [
        Expanded(child: firstField),
        const SizedBox(width: 8),
        Expanded(child: secondField),
      ]);
    });
  }

  void _request() {
    if (!_isCurrentAccount || context.read<QuoteCubit>().state.loading) return;
    // The fields live in a lazy sheet ListView and may be offscreen/unmounted
    // while the primary action stays visible. Validate the controller values
    // themselves so a collapsed sheet can still request the intended Quote.
    final pickup = _point(_pickupLat, _pickupLon);
    final dropoff = _point(_dropoffLat, _dropoffLon);
    if (pickup == null || dropoff == null) {
      _form.currentState?.validate();
      setState(() =>
          _coordinateError = 'Tọa độ không hợp lệ. Hãy kiểm tra bốn ô nhập.');
      return;
    }
    final request = QuoteRequest(
      pickup: pickup,
      dropoff: dropoff,
      vehicleType: _vehicle,
    );
    try {
      request.validate();
    } on FormatException catch (error) {
      setState(() => _coordinateError = error.message);
      return;
    }
    context.read<QuoteCubit>().request(request);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthenticatedState ||
        auth.user.publicId != widget.user.publicId) {
      if (!_authInvalidated) {
        _authInvalidated = true;
        for (final selected in [_pickupPlace, _dropoffPlace]) {
          selected.debounce?.cancel();
          selected.revision++;
          selected.suggestions = const [];
          selected.loading = false;
          selected.label = null;
          selected.attribution = null;
          selected.labelPoint = null;
          selected.message = null;
        }
        _pickupReverseRevision++;
        _dropoffReverseRevision++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _pickupPlace.query.clear();
          _dropoffPlace.query.clear();
        });
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    _authInvalidated = false;
    final pickup = _point(_pickupLat, _pickupLon);
    final dropoff = _point(_dropoffLat, _dropoffLon);
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    return MultiBlocListener(
      listeners: [
        BlocListener<QuoteCubit, QuoteState>(listener: (context, state) async {
          if (state.quote != null && _isCurrentAccount) {
            setState(() => _mapVisible = false);
            try {
              await Navigator.of(context)
                  .push(AppMotion.immediateRoute<void>(BlocProvider.value(
                value: context.read<BookingCubit>(),
                child: QuoteReviewScreen(
                  quote: state.quote!,
                  pickupLabel:
                      _selectedLabel(_MapTarget.pickup, state.quote!.pickup),
                  dropoffLabel:
                      _selectedLabel(_MapTarget.dropoff, state.quote!.dropoff),
                ),
              )));
            } finally {
              if (mounted && context.mounted && _isCurrentAccount) {
                setState(() => _mapVisible = true);
                await context.read<CustomerActiveBookingCubit>().restore();
              }
            }
          }
        }),
        BlocListener<BookingCubit, BookingState>(
            listener: (context, state) async {
          if (state.booking != null &&
              _isCurrentAccount &&
              ModalRoute.of(context)?.isCurrent == true) {
            setState(() => _mapVisible = false);
            try {
              await Navigator.of(context).push(AppMotion.immediateRoute<void>(
                  BookingStatusScreen(booking: state.booking!)));
            } finally {
              if (mounted && context.mounted && _isCurrentAccount) {
                setState(() => _mapVisible = true);
                await context.read<CustomerActiveBookingCubit>().restore();
              }
            }
          }
        }),
      ],
      child: Scaffold(
        appBar: AppBar(title: const Text('Đặt xe GoMove'), actions: [
          IconButton(
            tooltip: 'Lịch sử chuyến đi',
            icon: const Icon(Icons.history),
            onPressed: AppConfig.instance.isMock || !_isCurrentAccount
                ? null
                : _openHistory,
          ),
          IconButton(
            tooltip: 'Đăng xuất',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthLogoutRequested()),
          )
        ]),
        body: LayoutBuilder(builder: (context, constraints) {
          // Reserve an uncovered strip for the map recenter control even when
          // the sheet is expanded on a narrow device or above the keyboard.
          final maxSheetExtent =
              (1 - 60 / constraints.maxHeight).clamp(.52, .86);
          return Stack(children: [
            Positioned.fill(
              child: _mapVisible && routeCurrent
                  ? (widget.mapBuilder
                          ?.call(context, pickup, dropoff, _selectMapPoint) ??
                      CustomerMapCanvas(
                        pickup: pickup,
                        dropoff: dropoff,
                        onTap: _selectMapPoint,
                        fullScreen: true,
                      ))
                  : const ColoredBox(color: Colors.transparent),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: DraggableScrollableSheet(
                key: const ValueKey('customer-booking-sheet'),
                expand: false,
                minChildSize: .46,
                initialChildSize: .46,
                maxChildSize: maxSheetExtent,
                snap: true,
                builder: (context, sheetScrollController) => Material(
                  elevation: 12,
                  color: Theme.of(context).colorScheme.surface,
                  clipBehavior: Clip.antiAlias,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Column(children: [
                    Expanded(
                      child: ListView(
                        key: const ValueKey('customer-booking-sheet-scroll'),
                        controller: sheetScrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        children: [
                          Center(
                            child: Container(
                              key: const ValueKey(
                                  'customer-booking-sheet-handle'),
                              width: 40,
                              height: 5,
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          Text('Xin chào, ${widget.user.fullName}',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 4),
                          Text(
                              'Chọn hành trình và nhận báo giá trước khi đặt xe.',
                              style: Theme.of(context).textTheme.bodyMedium),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const DriverOnboardingScreen())),
                              icon: const Icon(Icons.directions_bike),
                              label: const Text('Đăng ký làm tài xế'),
                            ),
                          ),
                          BlocBuilder<CustomerActiveBookingCubit,
                                  CustomerActiveBookingState>(
                              builder: (context, state) {
                            final booking = state.booking;
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (state.loading)
                                    const LinearProgressIndicator(
                                        semanticsLabel:
                                            'Đang xác minh Booking'),
                                  if (!state.loading &&
                                      state.isActive &&
                                      booking != null)
                                    AppMotion.entrance(
                                        context,
                                        Card(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer,
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.all(16),
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Icon(Icons.directions_car,
                                                          color: Theme.of(
                                                                  context)
                                                              .colorScheme
                                                              .onPrimaryContainer),
                                                      const SizedBox(height: 8),
                                                      Text(
                                                          customerTripStatusLabel(
                                                              booking.status),
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium),
                                                      Text(
                                                          'Booking UUID: ${booking.publicId}'),
                                                      if (booking.status ==
                                                          'COMPLETED')
                                                        Text(state.payment ==
                                                                null
                                                            ? 'Chưa xác minh được thanh toán tiền mặt.'
                                                            : 'Thanh toán tiền mặt chưa xác nhận (PENDING).'),
                                                      const SizedBox(height: 8),
                                                      FilledButton.icon(
                                                          onPressed: state
                                                                  .loading
                                                              ? null
                                                              : () =>
                                                                  _openBooking(
                                                                      booking),
                                                          icon: const Icon(Icons
                                                              .directions_car),
                                                          label: const Text(
                                                              'Tiếp tục chuyến đang diễn ra')),
                                                    ])))),
                                  if (!state.loading &&
                                      !state.isActive &&
                                      booking != null &&
                                      booking.status == 'COMPLETED' &&
                                      state.payment?.isPaid == true)
                                    AppMotion.entrance(
                                        context,
                                        Card(
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.all(12),
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      const Text(
                                                          'Chuyến đã hoàn thành · Đã thanh toán (PAID)'),
                                                      Text(
                                                          'Booking UUID: ${booking.publicId}'),
                                                      TextButton(
                                                          onPressed: state
                                                                  .loading
                                                              ? null
                                                              : () =>
                                                                  _openBooking(
                                                                      booking),
                                                          child: const Text(
                                                              'Xem lại chuyến')),
                                                    ])))),
                                  if (!state.loading &&
                                      booking != null &&
                                      const {'CANCELLED', 'NO_DRIVER_AVAILABLE'}
                                          .contains(booking.status))
                                    Card(
                                        child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Text(booking.status ==
                                                    'CANCELLED'
                                                ? 'Chuyến trước đã được hủy. Bạn có thể đặt chuyến mới.'
                                                : 'Không tìm được tài xế cho chuyến trước. Bạn có thể thử đặt chuyến mới.'))),
                                  if (state.error != null)
                                    Card(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .errorContainer,
                                        child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Text(state.error!))),
                                  if (state.sessionEnded)
                                    const Text(
                                        'Phiên đăng nhập đã thay đổi. Hãy đăng nhập lại để khôi phục chuyến.'),
                                  TextButton.icon(
                                      onPressed:
                                          state.loading || state.sessionEnded
                                              ? null
                                              : _recoverExistingBooking,
                                      icon: const Icon(Icons.manage_search),
                                      label: const Text(
                                          'Khôi phục Booking bằng UUID')),
                                ]);
                          }),
                          const SizedBox(height: 12),
                          if (AppConfig.instance.isMock)
                            const Card(
                                child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                  'Mock Auth đang bật. Chạy MOCK_ENABLED=false để dùng Quote/Booking thật.'),
                            )),
                          BlocBuilder<BookingCubit, BookingState>(
                              builder: (context, state) {
                            final pending = state.pending;
                            if (pending == null) return const SizedBox.shrink();
                            return Card(
                                color: Theme.of(context)
                                    .colorScheme
                                    .tertiaryContainer,
                                child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                              'Booking đang chờ xác minh kết quả',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          Text(
                                              'Quote: ${pending.quotePublicId}'),
                                          const Text(
                                              'Nếu mạng bị ngắt, thử lại sẽ dùng cùng Idempotency-Key.'),
                                          Wrap(spacing: 8, children: [
                                            FilledButton(
                                                onPressed: state.loading
                                                    ? null
                                                    : () => context
                                                        .read<BookingCubit>()
                                                        .submit(pending
                                                            .quotePublicId),
                                                child: const Text(
                                                    'Thử lại yêu cầu cũ')),
                                            TextButton(
                                                onPressed: state.loading
                                                    ? null
                                                    : () async {
                                                        final confirmed =
                                                            await showDialog<
                                                                    bool>(
                                                                context:
                                                                    context,
                                                                builder: (ctx) =>
                                                                    AlertDialog(
                                                                      title: const Text(
                                                                          'Bỏ yêu cầu đang chờ?'),
                                                                      content:
                                                                          const Text(
                                                                              'Kết quả cũ có thể đã tạo Booking. Chỉ bỏ khi bạn đã tự xác minh kết quả hoặc chấp nhận rủi ro đó.'),
                                                                      actions: [
                                                                        TextButton(
                                                                            onPressed: () => Navigator.pop(ctx,
                                                                                false),
                                                                            child:
                                                                                const Text('Giữ lại')),
                                                                        TextButton(
                                                                            onPressed: () => Navigator.pop(ctx,
                                                                                true),
                                                                            child:
                                                                                const Text('Bỏ yêu cầu'))
                                                                      ],
                                                                    ));
                                                        if (confirmed == true &&
                                                            context.mounted) {
                                                          await context
                                                              .read<
                                                                  BookingCubit>()
                                                              .abandon();
                                                        }
                                                      },
                                                child:
                                                    const Text('Bỏ yêu cầu')),
                                          ]),
                                          if (state.error != null)
                                            Text(state.error!,
                                                style: const TextStyle(
                                                    color: Colors.red)),
                                        ])));
                          }),
                          const SizedBox(height: 12),
                          Text('Tìm địa điểm thật',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                              'Tìm điểm đón và điểm đến độc lập. Chọn kết quả để đặt marker đúng tọa độ; vẫn có thể chạm bản đồ hoặc nhập tọa độ.',
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 10),
                          _searchBox(_MapTarget.pickup),
                          const SizedBox(height: 8),
                          _searchBox(_MapTarget.dropoff),
                          const SizedBox(height: 8),
                          Text('Chọn điểm trên bản đồ',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                              'Chọn chế độ rồi chạm bản đồ. Chấm xanh viền là điểm đón, chấm cam là điểm đến.',
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 4, children: [
                            AnimatedScale(
                              key: const ValueKey('pickup-selection-motion'),
                              scale: _mapTarget == _MapTarget.pickup ? 1 : .98,
                              duration:
                                  AppMotion.duration(context, AppMotion.touch),
                              curve: AppMotion.enterCurve,
                              child: ChoiceChip(
                                label: const Text('Chọn điểm đón'),
                                avatar: Icon(Icons.trip_origin,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                                selected: _mapTarget == _MapTarget.pickup,
                                onSelected: (_) => setState(
                                    () => _mapTarget = _MapTarget.pickup),
                              ),
                            ),
                            AnimatedScale(
                              key: const ValueKey('dropoff-selection-motion'),
                              scale: _mapTarget == _MapTarget.dropoff ? 1 : .98,
                              duration:
                                  AppMotion.duration(context, AppMotion.touch),
                              curve: AppMotion.enterCurve,
                              child: ChoiceChip(
                                label: const Text('Chọn điểm đến'),
                                avatar: const Icon(Icons.location_on,
                                    color: Color(0xFFE87521)),
                                selected: _mapTarget == _MapTarget.dropoff,
                                onSelected: (_) => setState(
                                    () => _mapTarget = _MapTarget.dropoff),
                              ),
                            ),
                          ]),
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                            child: Text(
                              'Đang chọn: ${_mapTarget == _MapTarget.pickup ? 'Điểm đón' : 'Điểm đến'}',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          Text(
                            'Chạm vùng bản đồ phía trên để đặt điểm. Kéo bảng xuống để xem bản đồ rõ hơn.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 10),
                          _pointSummary(
                              'Điểm đón',
                              pickup,
                              Theme.of(context).colorScheme.primary,
                              _MapTarget.pickup),
                          _pointSummary('Điểm đến', dropoff,
                              const Color(0xFFE87521), _MapTarget.dropoff),
                          const SizedBox(height: 8),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text('Tọa độ thủ công và loại xe',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Có thể nhập tọa độ thủ công khi tìm địa điểm hoặc bản đồ không tải. Các tọa độ ban đầu là ví dụ ở Hà Nội; địa chỉ chỉ hiện sau khi được xác minh.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                  const SizedBox(height: 14),
                                  Form(
                                      key: _form,
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text('Điểm đón',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall),
                                            const SizedBox(height: 8),
                                            _coordinatePair(
                                                'Điểm đón · vĩ độ',
                                                _pickupLat,
                                                -90,
                                                90,
                                                'Điểm đón · kinh độ',
                                                _pickupLon,
                                                -180,
                                                180),
                                            const SizedBox(height: 14),
                                            Text('Điểm đến',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall),
                                            const SizedBox(height: 8),
                                            _coordinatePair(
                                                'Điểm đến · vĩ độ',
                                                _dropoffLat,
                                                -90,
                                                90,
                                                'Điểm đến · kinh độ',
                                                _dropoffLon,
                                                -180,
                                                180),
                                            const SizedBox(height: 16),
                                            DropdownButtonFormField<
                                                    VehicleType>(
                                                initialValue: _vehicle,
                                                decoration: const InputDecoration(
                                                    labelText: 'Loại xe',
                                                    border:
                                                        OutlineInputBorder()),
                                                items: VehicleType.values
                                                    .map((value) =>
                                                        DropdownMenuItem(
                                                            value: value,
                                                            child: Text(
                                                                value.label)))
                                                    .toList(),
                                                onChanged: (value) => setState(
                                                    () => _vehicle =
                                                        value ?? _vehicle)),
                                          ])),
                                ],
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: AppConfig.instance.isMock ||
                                      !_isCurrentAccount
                                  ? null
                                  : _openHistory,
                              icon: const Icon(Icons.history),
                              label: const Text('Lịch sử chuyến đi'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: BlocBuilder<QuoteCubit, QuoteState>(
                          builder: (context, state) => Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_coordinateError != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(_coordinateError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                ),
                              SizedBox(
                                height: 52,
                                child: FilledButton(
                                  onPressed:
                                      state.loading || AppConfig.instance.isMock
                                          ? null
                                          : _request,
                                  child: AnimatedSwitcher(
                                    duration: AppMotion.duration(
                                        context, AppMotion.feedback),
                                    child: state.loading
                                        ? const SizedBox(
                                            key: ValueKey('quote-loading'),
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Text('Lấy báo giá từ máy chủ',
                                            key: ValueKey('quote-action')),
                                  ),
                                ),
                              ),
                              if (state.error != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(state.error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}
