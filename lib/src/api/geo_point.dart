class LatLng {
  final double latitude;
  final double longitude;

  LatLng({
    required this.latitude,
    required this.longitude,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is LatLng &&
        latitude == other.latitude &&
        longitude == other.longitude;
  }

  @override
  int get hashCode => latitude.hashCode ^ longitude.hashCode;
}
