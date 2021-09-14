class LatLng {
  final double latitude;
  final double longitude;


  LatLng({required this.latitude, required this.longitude});

  @override
  bool operator ==(Object other) {
    LatLng obj = other as LatLng;
    return latitude == obj.latitude && longitude == obj.longitude;
  }

  @override
  int get hashCode => latitude.hashCode * longitude.hashCode;
}
