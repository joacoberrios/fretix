import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../models/cotizacion_args.dart';
import '../../router/app_router.dart';
import '../../theme/fretix_colors.dart';

const _kApiKey = 'AIzaSyA5-F6OPZbVB35PnuDx7FH29R5Cd9ZZ45U';

// ── Llama a New Places API v1 (soporta CORS desde browser).
// Documentación: https://developers.google.com/maps/documentation/places/web-service/place-autocomplete
Future<List<_PlaceSuggestion>> _autocomplete(String input) async {
  if (input.trim().length < 3) return [];

  final uri = Uri.parse('https://places.googleapis.com/v1/places:autocomplete');
  final resp = await http.post(
    uri,
    headers: {
      'Content-Type':    'application/json',
      'X-Goog-Api-Key':  _kApiKey,
      'X-Goog-FieldMask': 'suggestions.placePrediction.placeId,suggestions.placePrediction.text',
    },
    body: jsonEncode({
      'input':              input,
      'languageCode':       'es',
      'regionCode':         'AR',
      'includedRegionCodes': ['ar'],
    }),
  );

  if (resp.statusCode != 200) return [];
  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final suggestions = (data['suggestions'] as List<dynamic>?) ?? [];
  return suggestions
      .whereType<Map<String, dynamic>>()
      .where((s) => s['placePrediction'] != null)
      .map((s) {
        final pred = s['placePrediction'] as Map<String, dynamic>;
        return _PlaceSuggestion(
          placeId: pred['placeId'] as String,
          text:    (pred['text'] as Map<String, dynamic>?)?['text'] as String? ?? '',
        );
      })
      .toList();
}

// ── Resuelve coordenadas desde placeId usando New Places API v1.
Future<LatLng?> _resolveCoords(String placeId) async {
  final uri = Uri.parse(
    'https://places.googleapis.com/v1/places/$placeId',
  );
  final resp = await http.get(
    uri,
    headers: {
      'X-Goog-Api-Key':  _kApiKey,
      'X-Goog-FieldMask': 'location',
    },
  );
  if (resp.statusCode != 200) return null;
  final data     = jsonDecode(resp.body) as Map<String, dynamic>;
  final location = data['location'] as Map<String, dynamic>?;
  if (location == null) return null;
  return LatLng(
    (location['latitude']  as num).toDouble(),
    (location['longitude'] as num).toDouble(),
  );
}

class _PlaceSuggestion {
  final String placeId;
  final String text;
  const _PlaceSuggestion({required this.placeId, required this.text});
}

// ══════════════════════════════════════════════════════════════════════════════
// SearchLocationScreen
// ══════════════════════════════════════════════════════════════════════════════

class SearchLocationScreen extends StatefulWidget {
  const SearchLocationScreen({super.key});

  @override
  State<SearchLocationScreen> createState() => _SearchLocationScreenState();
}

class _SearchLocationScreenState extends State<SearchLocationScreen> {
  final _origenCtrl  = TextEditingController();
  final _destinoCtrl = TextEditingController();
  final _origenFocus  = FocusNode();
  final _destinoFocus = FocusNode();

  // 'origin' | 'destination'
  String _activeField = 'origin';

  LatLng? _origenLatLng;
  LatLng? _destinoLatLng;

  List<_PlaceSuggestion> _suggestions = [];
  bool   _isSuggesting = false;
  bool   _isResolvingCoords = false;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _origenFocus.addListener(_onFocusChange);
    _destinoFocus.addListener(_onFocusChange);
    // Foco inicial en origen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _origenFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _origenCtrl.dispose();
    _destinoCtrl.dispose();
    _origenFocus.dispose();
    _destinoFocus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_origenFocus.hasFocus) {
      setState(() { _activeField = 'origin'; _suggestions = []; });
    } else if (_destinoFocus.hasFocus) {
      setState(() { _activeField = 'destination'; _suggestions = []; });
    }
  }

  void _onTextChanged(String text) {
    // Limpiar coords cuando el usuario edita el campo
    if (_activeField == 'origin')      _origenLatLng  = null;
    if (_activeField == 'destination') _destinoLatLng = null;

    _debounce?.cancel();
    if (text.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _isSuggesting = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await _autocomplete(text);
      if (mounted) setState(() { _suggestions = results; _isSuggesting = false; });
    });
  }

  Future<void> _onSuggestionTapped(_PlaceSuggestion s) async {
    setState(() { _isResolvingCoords = true; _suggestions = []; });
    final coords = await _resolveCoords(s.placeId);
    if (!mounted) return;

    if (coords == null) {
      setState(() => _isResolvingCoords = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No se pudo obtener la ubicación. Intentá de nuevo.'),
        backgroundColor: FretixColors.danger,
      ));
      return;
    }

    if (_activeField == 'origin') {
      _origenCtrl.text  = s.text;
      _origenLatLng     = coords;
      setState(() => _isResolvingCoords = false);
      // Avanzar al destino
      _destinoFocus.requestFocus();
    } else {
      _destinoCtrl.text = s.text;
      _destinoLatLng    = coords;
      setState(() => _isResolvingCoords = false);
    }
  }

  bool get _listoPara => _origenLatLng != null && _destinoLatLng != null;

  void _irACotizar() {
    if (!_listoPara) return;
    final args = CotizacionArgs(
      origen:       _origenLatLng!,
      destino:      _destinoLatLng!,
      origenLabel:  _origenCtrl.text.trim(),
      destinoLabel: _destinoCtrl.text.trim(),
    );
    Navigator.of(context).pushReplacementNamed(AppRouter.cotizacion, arguments: args);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: FretixColors.textSecondary, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    '¿A dónde vamos?',
                    style: TextStyle(
                      color:      FretixColors.textPrimary,
                      fontSize:   18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Campos de búsqueda
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  _LocationField(
                    controller:  _origenCtrl,
                    focusNode:   _origenFocus,
                    placeholder: 'Origen',
                    icon:        Icons.trip_origin_rounded,
                    iconColor:   FretixColors.accent,
                    isActive:    _activeField == 'origin',
                    hasValue:    _origenLatLng != null,
                    onChanged:   _onTextChanged,
                  ),
                  _RouteLine(),
                  _LocationField(
                    controller:  _destinoCtrl,
                    focusNode:   _destinoFocus,
                    placeholder: 'Destino',
                    icon:        Icons.location_on_rounded,
                    iconColor:   FretixColors.textSecondary,
                    isActive:    _activeField == 'destination',
                    hasValue:    _destinoLatLng != null,
                    onChanged:   _onTextChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // ── Lista de sugerencias
            Expanded(
              child: _isResolvingCoords
                  ? const Center(
                      child: CircularProgressIndicator(
                        color:       FretixColors.accent,
                        strokeWidth: 2.5,
                      ),
                    )
                  : _isSuggesting
                      ? const Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              color:       FretixColors.accent,
                              strokeWidth: 2,
                            ),
                          ),
                        )
                      : _suggestions.isNotEmpty
                          ? ListView.separated(
                              padding:          const EdgeInsets.symmetric(horizontal: 20),
                              itemCount:        _suggestions.length,
                              separatorBuilder: (_, __) => const Divider(
                                color: FretixColors.surfaceBorder,
                                height: 1,
                              ),
                              itemBuilder: (_, i) {
                                final s = _suggestions[i];
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                  leading: const Icon(
                                    Icons.place_outlined,
                                    color: FretixColors.textMuted,
                                    size:  20,
                                  ),
                                  title: Text(
                                    s.text,
                                    style: const TextStyle(
                                      color:    FretixColors.textPrimary,
                                      fontSize: 14,
                                    ),
                                  ),
                                  onTap: () => _onSuggestionTapped(s),
                                );
                              },
                            )
                          : const SizedBox.shrink(),
            ),

            // ── Botón "Ver precios"
            if (_listoPara)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: SizedBox(
                  width:  double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _irACotizar,
                    child: const Text(
                      'Ver precios',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _LocationField
// ═══════════════════════════════════════════════════════════════════════════════

class _LocationField extends StatelessWidget {
  const _LocationField({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.icon,
    required this.iconColor,
    required this.isActive,
    required this.hasValue,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode             focusNode;
  final String                placeholder;
  final IconData              icon;
  final Color                 iconColor;
  final bool                  isActive;
  final bool                  hasValue;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration:    const Duration(milliseconds: 150),
      decoration:  BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? FretixColors.accent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(icon, color: hasValue ? FretixColors.accent : iconColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode:  focusNode,
              onChanged:  onChanged,
              style: const TextStyle(
                color:    FretixColors.textPrimary,
                fontSize: 15,
              ),
              decoration: InputDecoration(
                hintText:        placeholder,
                hintStyle: const TextStyle(
                  color:    FretixColors.textMuted,
                  fontSize: 15,
                ),
                border:         InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.close_rounded, color: FretixColors.textMuted, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Línea de conexión entre los dos campos
class _RouteLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 23),
      child: SizedBox(
        height: 8,
        child: VerticalDivider(
          color: FretixColors.surfaceBorder,
          thickness: 1.5,
          width: 1.5,
        ),
      ),
    );
  }
}
