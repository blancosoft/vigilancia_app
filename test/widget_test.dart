import 'package:flutter_test/flutter_test.dart';
import 'package:vigilancia_app/main.dart';

void main() {
  testWidgets('Muestra las dos formas de uso', (tester) async {
    await tester.pumpWidget(const VigilanciaApp());

    expect(find.text('Vigilancia Wi-Fi'), findsOneWidget);
    expect(find.text('Activar en el teléfono cámara'), findsOneWidget);
    expect(find.text('Conectar como visor'), findsOneWidget);
    expect(find.text('IP del teléfono cámara'), findsOneWidget);
  });
}
