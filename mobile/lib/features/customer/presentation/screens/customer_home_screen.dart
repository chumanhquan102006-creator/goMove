import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
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
import '../widgets/customer_premium_widgets.dart';

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

enum _SearchExit { chooseOnMap }

class _SelectedPlace {
  final PlaceSearchResult place;
  final int revision;
  final int? generation;
  const _SelectedPlace(this.place, this.revision, this.generation);
}

class _PlaceSelection extends ChangeNotifier {
  final query = TextEditingController();
  Timer? debounce;
  int revision = 0;
  int? suggestionsGeneration;
  List<PlaceSearchResult> suggestions = const [];
  bool loading = false;
  String? message;
  String? label;
  String? attribution;
  Coordinates? labelPoint;

  void refresh() => notifyListeners();

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    super.dispose();
  }
}

class _CustomerHomeContentState extends State<_CustomerHomeContent>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _sheetController = DraggableScrollableController();
  final _pickupLat = TextEditingController(text: '21.0287');
  final _pickupLon = TextEditingController(text: '105.8524');
  final _dropoffLat = TextEditingController(text: '21.0245');
  final _dropoffLon = TextEditingController(text: '105.8576');
  _MapTarget _mapTarget = _MapTarget.pickup;
  VehicleType _vehicle = VehicleType.motorbike;
  String? _coordinateError;
  bool _mapVisible = true;
  bool _searchRouteOpen = false;
  bool _choosingOnMap = false;
  bool _keyboardWasOpen = false;
  String? _dismissedPaidBookingId;
  double _sheetMinSize = .34;
  double _sheetMaxSize = .90;
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
      selection.suggestionsGeneration = null;
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
    selection.refresh();
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
        selection.suggestionsGeneration = null;
        selection.loading = false;
        if (selection.message == 'Đang tìm địa chỉ cho điểm đã chọn…') {
          selection.message = 'Địa chỉ chưa khả dụng cho điểm này.';
        }
        selection.refresh();
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
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _openSearchFromMap(_MapTarget target) async {
    if (!_foreground || !_isCurrentAccount) return;
    setState(() {
      _mapTarget = target;
      _choosingOnMap = false;
      _searchRouteOpen = true;
    });
    Object? result;
    try {
      final selected = _selection(target);
      result = await Navigator.of(context).push<Object>(
        AppMotion.contentRoute<Object>(
          context,
          _LocationSearchPage(
            target: target,
            selection: selected,
            customerPublicId: widget.user.publicId,
            onChanged: (query) => _onSearchChanged(target, query),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _searchRouteOpen = false);
    }
    if (!mounted || !_foreground || !_isCurrentAccount) return;
    if (result == _SearchExit.chooseOnMap) {
      _chooseOnMap(target);
      return;
    }
    if (result is _SelectedPlace) {
      final selected = _selection(target);
      if (result.generation == null ||
          selected.revision != result.revision ||
          !selected.suggestions.contains(result.place) ||
          !sl.isRegistered<SecureStorageService>()) {
        return;
      }
      final current = await _sessionStillCurrent(
          sl<SecureStorageService>(), result.generation!);
      if (!mounted ||
          !_foreground ||
          !_isCurrentAccount ||
          !current ||
          selected.revision != result.revision) {
        return;
      }
      _setPoint(target, result.place.coordinates,
          label: result.place.label, attribution: result.place.attribution);
    }
  }

  void _chooseOnMap(_MapTarget target) {
    if (!_isCurrentAccount) return;
    setState(() {
      _mapTarget = target;
      _choosingOnMap = true;
    });
    if (_sheetController.isAttached) _sheetController.jumpTo(_sheetMinSize);
  }

  String _floatingPlaceLabel(_MapTarget target, Coordinates? point) {
    final verified = _selectedLabel(target, point);
    if (verified != null) return verified;
    return target == _MapTarget.pickup
        ? 'Tìm nơi đón bạn'
        : 'Bạn muốn đến đâu?';
  }

  void _dragSheet(DragUpdateDetails details, double parentHeight) {
    if (!_sheetController.isAttached || parentHeight <= 0) return;
    final next =
        (_sheetController.size - (details.primaryDelta ?? 0) / parentHeight)
            .clamp(_sheetMinSize, _sheetMaxSize)
            .toDouble();
    _sheetController.jumpTo(next);
  }

  void _settleSheet(DragEndDetails details) {
    if (!_sheetController.isAttached) return;
    final middle = (_sheetMinSize + _sheetMaxSize) / 2;
    final stops = [_sheetMinSize, middle, _sheetMaxSize];
    final current = _sheetController.size;
    final velocity = details.primaryVelocity ?? 0;
    final target = velocity < -250
        ? stops.firstWhere((stop) => stop > current + .01,
            orElse: () => stops.last)
        : velocity > 250
            ? stops.lastWhere((stop) => stop < current - .01,
                orElse: () => stops.first)
            : stops.reduce(
                (a, b) => (a - current).abs() <= (b - current).abs() ? a : b);
    final duration = AppMotion.duration(context, AppMotion.sheet);
    if (duration == Duration.zero) {
      _sheetController.jumpTo(target);
    } else {
      unawaited(_sheetController.animateTo(
        target,
        duration: duration,
        curve: AppMotion.standardCurve,
      ));
    }
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
              title: const Text('Tìm lại chuyến bằng mã'),
              content: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'Nhập mã tham chiếu của chuyến cũ. Chỉ chuyến thuộc tài khoản của bạn mới được hiển thị.'),
                    const SizedBox(height: 12),
                    TextFormField(
                      onChanged: (value) => input = value,
                      maxLength: 36,
                      decoration: const InputDecoration(
                          labelText: 'Mã tham chiếu chuyến đi',
                          border: OutlineInputBorder()),
                      validator: (value) =>
                          RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
                                  .hasMatch((value ?? '').trim())
                              ? null
                              : 'Mã tham chiếu chưa đúng định dạng',
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
                    child: const Text('Tìm chuyến')),
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
      selected.suggestionsGeneration = null;
      selected.loading = false;
      selected.label = label;
      selected.attribution = attribution;
      selected.labelPoint = label == null ? null : point;
      selected.message =
          label == null ? 'Đang tìm địa chỉ cho điểm đã chọn…' : null;
    });
    selected.refresh();
  }

  String _lookupError(Object error) {
    if (error is ServerException && error.statusCode == 429) {
      return 'Tìm kiếm đang quá tải. Hãy thử lại sau hoặc chọn điểm trên bản đồ.';
    }
    if (error is FormatException) return error.message;
    return 'Không tìm được địa chỉ lúc này. Bạn vẫn có thể chọn trên bản đồ hoặc nhập vị trí.';
  }

  void _onSearchChanged(_MapTarget target, String query) {
    final selected = _selection(target);
    selected.debounce?.cancel();
    final revision = ++selected.revision;
    final normalized = query.trim();
    setState(() {
      selected.suggestions = const [];
      selected.suggestionsGeneration = null;
      selected.loading = false;
      selected.message = normalized.isEmpty
          ? null
          : normalized.runes.length < 3
              ? 'Nhập ít nhất 3 ký tự để tìm địa điểm.'
              : null;
    });
    selected.refresh();
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
          'Tìm kiếm địa điểm chưa khả dụng. Bạn vẫn có thể chọn điểm trên bản đồ.');
      selected.refresh();
      return;
    }
    setState(() => selected.loading = true);
    selected.refresh();
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
        selected.refresh();
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
        selected.suggestionsGeneration = snapshot.generation;
        selected.loading = false;
        selected.message =
            results.isEmpty ? 'Không tìm thấy địa điểm phù hợp.' : null;
      });
      selected.refresh();
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
      selected.refresh();
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
        _selection(target).refresh();
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
      _selection(target).refresh();
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
      _selection(target).refresh();
    }
  }

  void _selectMapPoint(Coordinates point) {
    if (!_isCurrentAccount || !point.isValid) return;
    FocusScope.of(context).unfocus();
    final target = _mapTarget;
    _choosingOnMap = false;
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
          onTap: () => setState(() {
            _mapTarget = target;
            _choosingOnMap = true;
          }),
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

  Widget _vehicleCard(VehicleType type) {
    final selected = _vehicle == type;
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (type) {
      VehicleType.motorbike => Icons.two_wheeler_rounded,
      VehicleType.car4Seat => Icons.directions_car_rounded,
      VehicleType.car7Seat => Icons.airport_shuttle_rounded,
    };
    final capacity = switch (type) {
      VehicleType.motorbike => '1 hành khách',
      VehicleType.car4Seat => 'Tối đa 4 chỗ',
      VehicleType.car7Seat => 'Tối đa 7 chỗ',
    };
    return Semantics(
      selected: selected,
      button: true,
      label: type.label,
      child: InkWell(
        key: ValueKey('customer-vehicle-${type.apiValue}'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _vehicle = type),
        child: AnimatedScale(
          scale: selected ? 1 : .96,
          duration: AppMotion.duration(context, AppMotion.touch),
          curve: AppMotion.enterCurve,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.card),
            curve: AppMotion.standardCurve,
            width: 132,
            height: 116,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.paleBlue, AppColors.paleViolet],
                    )
                  : null,
              color: selected ? null : scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected ? AppColors.primary : scheme.outlineVariant,
                  width: selected ? 2 : 1),
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Color(0x181E46A6),
                        blurRadius: 16,
                        offset: Offset(0, 6),
                      )
                    ]
                  : null,
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon,
                    color:
                        selected ? AppColors.primary : scheme.onSurfaceVariant,
                    size: 30),
                const Spacer(),
                if (selected)
                  const Icon(Icons.check_circle_rounded,
                      color: AppColors.primary, size: 18),
              ]),
              const Spacer(),
              Text(type.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text(capacity,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.textSecondary)),
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
      setState(
          () => _coordinateError = 'Hãy chọn điểm đón và điểm đến hợp lệ.');
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
          selected.suggestionsGeneration = null;
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
          _pickupPlace.refresh();
          _dropoffPlace.refresh();
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
              await Navigator.of(context).push(AppMotion.contentRoute<void>(
                  context,
                  BlocProvider.value(
                    value: context.read<BookingCubit>(),
                    child: QuoteReviewScreen(
                      quote: state.quote!,
                      pickupLabel: _selectedLabel(
                          _MapTarget.pickup, state.quote!.pickup),
                      dropoffLabel: _selectedLabel(
                          _MapTarget.dropoff, state.quote!.dropoff),
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
        appBar: AppBar(
            title: LayoutBuilder(
              builder: (context, size) => Row(children: [
                if (size.maxWidth >= 180) ...[
                  const Icon(Icons.near_me_rounded, color: AppColors.primary),
                  const SizedBox(width: 8),
                ],
                const Text('GoMove'),
                if (size.maxWidth >= 220) ...[
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('Chào ${widget.user.fullName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall)),
                ],
              ]),
            ),
            actions: [
              BlocBuilder<CustomerActiveBookingCubit,
                  CustomerActiveBookingState>(
                builder: (context, state) => IconButton(
                  key: const ValueKey('customer-recover-booking'),
                  tooltip: 'Tìm lại chuyến bằng mã',
                  icon: const Icon(Icons.manage_search_rounded),
                  onPressed: state.loading || state.sessionEnded
                      ? null
                      : _recoverExistingBooking,
                ),
              ),
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
          final keyboardOpen = View.of(context).viewInsets.bottom > 0;
          _sheetMinSize = keyboardOpen
              ? .58
              : (248 / constraints.maxHeight).clamp(.28, .48).toDouble();
          _sheetMaxSize = keyboardOpen ? .98 : .92;
          if (keyboardOpen != _keyboardWasOpen) {
            _keyboardWasOpen = keyboardOpen;
            if (keyboardOpen && routeCurrent) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _sheetController.isAttached) {
                  _sheetController.jumpTo(_sheetMaxSize);
                }
              });
            }
          }
          return Stack(children: [
            Positioned.fill(
              child: _mapVisible && (routeCurrent || _searchRouteOpen)
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
            if (_choosingOnMap)
              Positioned(
                top: 72,
                left: 12,
                right: 72,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: 3,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      const Icon(Icons.touch_app_rounded),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_mapTarget == _MapTarget.pickup
                            ? 'Chạm bản đồ để chọn điểm đón'
                            : 'Chạm bản đồ để chọn điểm đến'),
                      ),
                      IconButton(
                        tooltip: 'Đóng chọn trên bản đồ',
                        onPressed: () => setState(() => _choosingOnMap = false),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ]),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: DraggableScrollableSheet(
                key: const ValueKey('customer-booking-sheet'),
                controller: _sheetController,
                expand: false,
                minChildSize: _sheetMinSize,
                initialChildSize: _sheetMinSize,
                maxChildSize: _sheetMaxSize,
                snap: !AppMotion.reduceMotion(context),
                snapSizes: [
                  _sheetMinSize,
                  (_sheetMinSize + _sheetMaxSize) / 2,
                ],
                builder: (context, sheetScrollController) => Material(
                  elevation: 12,
                  color: Theme.of(context).colorScheme.surface,
                  clipBehavior: Clip.antiAlias,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Column(children: [
                    GestureDetector(
                      key: const ValueKey('customer-booking-sheet-grip'),
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) =>
                          _dragSheet(details, constraints.maxHeight),
                      onVerticalDragEnd: _settleSheet,
                      child: SizedBox(
                        width: double.infinity,
                        height: 38,
                        child: Center(
                          child: Container(
                            key:
                                const ValueKey('customer-booking-sheet-handle'),
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!keyboardOpen)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(children: [
                          Expanded(
                              child: CustomerFloatingPlaceField(
                            key: const ValueKey('floating-pickup-search'),
                            label: 'Điểm đón',
                            value:
                                _floatingPlaceLabel(_MapTarget.pickup, pickup),
                            icon: Icons.trip_origin,
                            selected: _mapTarget == _MapTarget.pickup,
                            compact: true,
                            onTap: () => _openSearchFromMap(_MapTarget.pickup),
                          )),
                          const SizedBox(width: 8),
                          Expanded(
                              child: CustomerFloatingPlaceField(
                            key: const ValueKey('floating-dropoff-search'),
                            label: 'Điểm đến',
                            value: _floatingPlaceLabel(
                                _MapTarget.dropoff, dropoff),
                            icon: Icons.location_on_rounded,
                            selected: _mapTarget == _MapTarget.dropoff,
                            compact: true,
                            onTap: () => _openSearchFromMap(_MapTarget.dropoff),
                          )),
                        ]),
                      ),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('customer-booking-sheet-scroll'),
                        controller: sheetScrollController,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                        children: [
                          BlocBuilder<CustomerActiveBookingCubit,
                                  CustomerActiveBookingState>(
                              builder: (context, state) {
                            final booking = state.booking;
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (state.loading)
                                    const LinearProgressIndicator(
                                        semanticsLabel: 'Đang xác minh chuyến'),
                                  if (!state.loading &&
                                      state.isActive &&
                                      booking != null)
                                    AppMotion.entrance(
                                        context,
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: AppColors.paleBlue,
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Row(children: [
                                              const Icon(Icons.near_me_rounded,
                                                  color: AppColors.primary),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  booking.status == 'COMPLETED'
                                                      ? 'Chờ xác nhận tiền mặt'
                                                      : customerTripStatusLabel(
                                                          booking.status),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleSmall,
                                                ),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    _openBooking(booking),
                                                child: const Text('Xem chuyến'),
                                              ),
                                            ]),
                                          ),
                                        )),
                                  if (!state.loading &&
                                      !state.isActive &&
                                      booking != null &&
                                      booking.status == 'COMPLETED' &&
                                      state.payment?.isPaid == true &&
                                      _dismissedPaidBookingId !=
                                          booking.publicId)
                                    AppMotion.entrance(
                                        context,
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: Row(children: [
                                            const Icon(Icons.check_circle,
                                                color: AppColors.success),
                                            const SizedBox(width: 8),
                                            Expanded(
                                                child: Text(
                                                    'Chuyến trước đã thanh toán',
                                                    maxLines: 2,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall)),
                                            TextButton(
                                              onPressed: () =>
                                                  _openBooking(booking),
                                              child: const Text('Biên nhận'),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  'Ẩn chuyến đã thanh toán',
                                              onPressed: () => setState(() =>
                                                  _dismissedPaidBookingId =
                                                      booking.publicId),
                                              icon: const Icon(Icons.close,
                                                  size: 18),
                                            ),
                                          ]),
                                        )),
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
                                ]);
                          }),
                          const SizedBox(height: 12),
                          const SizedBox(height: 4),
                          if (AppConfig.instance.isMock)
                            const Card(
                                child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                  'Đặt xe chưa khả dụng trong bản xem thử.'),
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
                                              'Đang xác minh kết quả đặt chuyến',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          const Text(
                                              'Nếu mạng bị ngắt, thử lại vẫn kiểm tra cùng yêu cầu. Đừng đặt chuyến mới trước khi có kết quả.'),
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
                                                                              'Yêu cầu cũ có thể đã tạo chuyến. Hãy kiểm tra kết quả trước khi bỏ yêu cầu này.'),
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
                          const CustomerSectionHeading(
                            icon: Icons.directions_car_filled_rounded,
                            title: 'Chọn xe phù hợp',
                          ),
                          const SizedBox(height: 10),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final type in VehicleType.values)
                              _vehicleCard(type),
                          ]),
                          const SizedBox(height: 12),
                          ExpansionTile(
                            key: const ValueKey('customer-location-options'),
                            title: const Text('Tùy chọn vị trí khác'),
                            leading: const Icon(Icons.tune_rounded),
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 8),
                            children: [
                              const CustomerSectionHeading(
                                icon: Icons.touch_app_rounded,
                                title: 'Chọn trên bản đồ',
                              ),
                              const SizedBox(height: 8),
                              Wrap(spacing: 8, runSpacing: 4, children: [
                                AnimatedScale(
                                  key:
                                      const ValueKey('pickup-selection-motion'),
                                  scale:
                                      _mapTarget == _MapTarget.pickup ? 1 : .98,
                                  duration: AppMotion.duration(
                                      context, AppMotion.touch),
                                  curve: AppMotion.enterCurve,
                                  child: ChoiceChip(
                                    label: const Text('Chọn điểm đón'),
                                    avatar: Icon(Icons.trip_origin,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary),
                                    selected: _mapTarget == _MapTarget.pickup,
                                    onSelected: (_) =>
                                        _chooseOnMap(_MapTarget.pickup),
                                  ),
                                ),
                                AnimatedScale(
                                  key: const ValueKey(
                                      'dropoff-selection-motion'),
                                  scale: _mapTarget == _MapTarget.dropoff
                                      ? 1
                                      : .98,
                                  duration: AppMotion.duration(
                                      context, AppMotion.touch),
                                  curve: AppMotion.enterCurve,
                                  child: ChoiceChip(
                                    label: const Text('Chọn điểm đến'),
                                    avatar: const Icon(Icons.location_on,
                                        color: Color(0xFFE87521)),
                                    selected: _mapTarget == _MapTarget.dropoff,
                                    onSelected: (_) =>
                                        _chooseOnMap(_MapTarget.dropoff),
                                  ),
                                ),
                              ]),
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 4, bottom: 8),
                                child: Text(
                                  'Đang chọn: ${_mapTarget == _MapTarget.pickup ? 'Điểm đón' : 'Điểm đến'}',
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                              ),
                              _pointSummary(
                                  'Điểm đón',
                                  pickup,
                                  Theme.of(context).colorScheme.primary,
                                  _MapTarget.pickup),
                              _pointSummary('Điểm đến', dropoff,
                                  const Color(0xFFE87521), _MapTarget.dropoff),
                              const SizedBox(height: 12),
                              Card(
                                child: ExpansionTile(
                                  key: const ValueKey(
                                      'customer-manual-coordinates'),
                                  leading: const Icon(Icons.pin_drop_outlined),
                                  title: const Text(
                                      'Nhập vị trí thủ công khi cần'),
                                  subtitle: const Text(
                                      'Dùng khi tìm kiếm hoặc bản đồ không khả dụng'),
                                  childrenPadding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  children: [
                                    Form(
                                      key: _form,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          const Text('Điểm đón'),
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
                                          const Text('Điểm đến'),
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
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Wrap(spacing: 8, runSpacing: 2, children: [
                            TextButton.icon(
                              onPressed: AppConfig.instance.isMock ||
                                      !_isCurrentAccount
                                  ? null
                                  : _openHistory,
                              icon: const Icon(Icons.history),
                              label: const Text('Lịch sử chuyến đi'),
                            ),
                            BlocBuilder<CustomerActiveBookingCubit,
                                CustomerActiveBookingState>(
                              builder: (context, state) => TextButton.icon(
                                onPressed: state.loading || state.sessionEnded
                                    ? null
                                    : _recoverExistingBooking,
                                icon: const Icon(Icons.manage_search_rounded),
                                label: const Text('Tìm lại chuyến bằng mã'),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const DriverOnboardingScreen())),
                              icon: const Icon(Icons.two_wheeler_rounded),
                              label: const Text('Đăng ký làm tài xế'),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: BlocBuilder<CustomerActiveBookingCubit,
                            CustomerActiveBookingState>(
                          builder: (context, active) => active.isActive &&
                                  active.booking != null
                              ? CustomerPressableAction(
                                  onPressed: active.loading
                                      ? null
                                      : () => _openBooking(active.booking!),
                                  child: const Text(
                                      'Tiếp tục chuyến đang diễn ra'),
                                )
                              : BlocBuilder<QuoteCubit, QuoteState>(
                                  builder: (context, state) => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_coordinateError != null)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: Text(_coordinateError!,
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .error)),
                                        ),
                                      SizedBox(
                                        height: 52,
                                        child: CustomerPressableAction(
                                          onPressed: state.loading ||
                                                  AppConfig.instance.isMock
                                              ? null
                                              : _request,
                                          child: AnimatedSwitcher(
                                            duration: AppMotion.duration(
                                                context, AppMotion.feedback),
                                            child: state.loading
                                                ? const SizedBox(
                                                    key: ValueKey(
                                                        'quote-loading'),
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                            strokeWidth: 2))
                                                : const Text(
                                                    'Xem giá chuyến đi',
                                                    key: ValueKey(
                                                        'quote-action')),
                                          ),
                                        ),
                                      ),
                                      if (state.error != null)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 8),
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

/// Flutter-only search route. The Home state owns requests and validates the
/// session again before applying a selected result to the map.
class _LocationSearchPage extends StatefulWidget {
  final _MapTarget target;
  final _PlaceSelection selection;
  final String customerPublicId;
  final ValueChanged<String> onChanged;

  const _LocationSearchPage({
    required this.target,
    required this.selection,
    required this.customerPublicId,
    required this.onChanged,
  });

  @override
  State<_LocationSearchPage> createState() => _LocationSearchPageState();
}

class _LocationSearchPageState extends State<_LocationSearchPage> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pickup = widget.target == _MapTarget.pickup;
    final title = pickup ? 'Tìm điểm đón' : 'Tìm điểm đến';
    final colors = Theme.of(context).colorScheme;
    final auth = context.watch<AuthBloc>().state;
    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is! AuthenticatedState ||
            state.user.publicId != widget.customerPublicId) {
          if (ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        }
      },
      child: auth is! AuthenticatedState ||
              auth.user.publicId != widget.customerPublicId
          ? const Scaffold(body: SizedBox.shrink())
          : Scaffold(
              key: const ValueKey('customer-location-search-page'),
              appBar: AppBar(title: Text(title)),
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: AnimatedBuilder(
                      animation: widget.selection,
                      builder: (context, _) => Column(children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: TextField(
                            key: ValueKey(pickup
                                ? 'pickup-place-search'
                                : 'dropoff-place-search'),
                            controller: widget.selection.query,
                            focusNode: _focusNode,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            maxLength: 100,
                            decoration: InputDecoration(
                              hintText: 'Tên địa điểm hoặc địa chỉ',
                              prefixIcon: Icon(pickup
                                  ? Icons.trip_origin
                                  : Icons.location_on_rounded),
                              suffixIcon: widget.selection.loading
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)))
                                  : widget.selection.query.text.isNotEmpty
                                      ? IconButton(
                                          tooltip: 'Xóa tìm kiếm',
                                          onPressed: () {
                                            widget.selection.query.clear();
                                            widget.onChanged('');
                                          },
                                          icon: const Icon(Icons.close_rounded))
                                      : null,
                            ),
                            onChanged: widget.onChanged,
                          ),
                        ),
                        if (widget.selection.loading)
                          const LinearProgressIndicator(
                              semanticsLabel: 'Đang tìm địa điểm'),
                        Expanded(
                          child: ListView(
                            key: const ValueKey(
                                'customer-location-search-results'),
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            children: [
                              if (widget.selection.query.text.trim().isEmpty &&
                                  widget.selection.suggestions.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 36),
                                  child: Column(children: [
                                    Icon(Icons.search_rounded,
                                        size: 40, color: colors.primary),
                                    const SizedBox(height: 12),
                                    Text('Bạn muốn đến đâu?',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                  ]),
                                ),
                              if (widget.selection.message != null)
                                Semantics(
                                  liveRegion: true,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    child: Text(widget.selection.message!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium),
                                  ),
                                ),
                              for (final result in widget.selection.suggestions)
                                ListTile(
                                  contentPadding:
                                      const EdgeInsets.symmetric(horizontal: 4),
                                  leading: Icon(Icons.place_rounded,
                                      color: colors.primary),
                                  title: Text(result.name ?? result.label),
                                  subtitle: Text([
                                    if (result.name != null) result.label,
                                    if (result.district != null &&
                                        !result.label
                                            .contains(result.district!))
                                      result.district!,
                                    if (result.city != null &&
                                        !result.label.contains(result.city!))
                                      result.city!,
                                    if (result.attribution != null)
                                      result.attribution!,
                                  ].join(' · ')),
                                  onTap: () => Navigator.of(context).pop(
                                    _SelectedPlace(
                                        result,
                                        widget.selection.revision,
                                        widget.selection.suggestionsGeneration),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: OutlinedButton.icon(
                            key: const ValueKey('customer-search-choose-map'),
                            onPressed: () => Navigator.of(context)
                                .pop(_SearchExit.chooseOnMap),
                            icon: const Icon(Icons.touch_app_rounded),
                            label: const Text('Chọn trên bản đồ'),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
