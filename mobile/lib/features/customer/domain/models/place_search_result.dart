import 'quote.dart';

/// Provider-derived display metadata. Coordinates remain the Quote input.
class PlaceSearchResult {
  final String label;
  final String? name;
  final String? street;
  final String? district;
  final String? city;
  final String? attribution;
  final Coordinates coordinates;

  const PlaceSearchResult({
    required this.label,
    required this.coordinates,
    this.name,
    this.street,
    this.district,
    this.city,
    this.attribution,
  });

  factory PlaceSearchResult.fromJson(Map<String, dynamic> json) {
    final label = json['label'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (label is! String || label.trim().isEmpty ||
        latitude is! num || longitude is! num) {
      throw const FormatException('Địa điểm không hợp lệ');
    }
    final coordinates = Coordinates(latitude.toDouble(), longitude.toDouble());
    if (!coordinates.isValid) {
      throw const FormatException('Tọa độ địa điểm không hợp lệ');
    }
    return PlaceSearchResult(
      label: label.trim(),
      coordinates: coordinates,
      name: _optional(json['name']),
      street: _optional(json['street']),
      district: _optional(json['district']),
      city: _optional(json['city']),
      attribution: _optional(json['attribution']),
    );
  }

  static String? _optional(Object? value) => value is String &&
          value.trim().isNotEmpty
      ? value.trim()
      : null;
}
