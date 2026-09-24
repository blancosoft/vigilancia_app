import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilancia_app/main.dart';

void main() {
  testWidgets('Muestra las dos formas de uso', (tester) async {
    await tester.pumpWidget(const VigilanciaApp());

    expect(find.text('Vigilancia Wi-Fi'), findsOneWidget);
    expect(find.text('Activar en el teléfono cámara'), findsOneWidget);

    await tester.drag(
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conectar cámaras'), findsOneWidget);
    expect(find.text('IP del teléfono cámara 1'), findsOneWidget);
  });
}
