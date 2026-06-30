import 'package:flutter/material.dart';

import '../../theme/fretix_colors.dart';

class BuscandoChoferScreen extends StatelessWidget {
  const BuscandoChoferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: FretixColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      color:       FretixColors.accent,
                      strokeWidth: 3,
                    ),
                  ),
                  SizedBox(height: 32),
                  Text(
                    'Buscando chofer...',
                    style: TextStyle(
                      color:      FretixColors.textPrimary,
                      fontSize:   22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 10),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 48),
                    child: Text(
                      'Estamos conectándote con el chofer más cercano. Esto demora menos de un minuto.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color:    FretixColors.textSecondary,
                        fontSize: 14,
                        height:   1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
