import 'package:google_maps_flutter/google_maps_flutter.dart';

class CotizacionArgs {
  final LatLng origen;
  final LatLng destino;
  final String origenLabel;
  final String destinoLabel;

  const CotizacionArgs({
    required this.origen,
    required this.destino,
    required this.origenLabel,
    required this.destinoLabel,
  });
}
