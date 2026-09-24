import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/camera_screen.dart';
import 'screens/viewer_screen.dart';
import 'services/streaming_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VigilanciaApp());
}

class VigilanciaApp extends StatelessWidget {
  const VigilanciaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vigilancia Wi-Fi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F3F5),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _hostControllers = List<TextEditingController>.generate(
    4,
    (_) => TextEditingController(),
  );

  @override
  void dispose() {
    for (final controller in _hostControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _openViewer() {
    final hosts = <String>[];
    for (final controller in _hostControllers) {
      final value = controller.text.trim();
      if (value.isEmpty) continue;
      final host = StreamingService.normalizeHost(value);
      if (!hosts.contains(host)) hosts.add(host);
    }

    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Escribe al menos una IP de un teléfono cámara.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ViewerScreen(hosts: hosts),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F5),
      appBar: AppBar(title: const Text('Vigilancia Wi-Fi')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: SizedBox(
                width: 180,
                height: 180,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Image.asset(
                        'icon.png',
                        width: 172,
                        height: 172,
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.high,
                        semanticLabel: 'Icono de vigilancia',
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Cámara de vigilancia local',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Los dos teléfonos deben estar conectados a la misma red Wi-Fi, sin Mobile Data, VPN ni aislamiento de clientes.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CameraScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.videocam),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Activar en el teléfono cámara'),
              ),
            ),
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 20),
            Text(
              'Ver desde otro teléfono',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Escribe entre una y cuatro IPs. Deja vacíos los campos que no uses.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < _hostControllers.length; index++) ...[
              TextField(
                controller: _hostControllers[index],
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: index == 3
                    ? TextInputAction.go
                    : TextInputAction.next,
                onSubmitted: index == 3 ? (_) => _openViewer() : null,
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                decoration: InputDecoration(
                  labelText: 'IP del teléfono cámara ${index + 1}',
                  hintText: '192.168.1.${25 + index}',
                  prefixIcon: const Icon(Icons.router_outlined),
                ),
              ),
              if (index != _hostControllers.length - 1)
                const SizedBox(height: 10),
            ],
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _openViewer,
              icon: const Icon(Icons.grid_view),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Conectar cámaras'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
