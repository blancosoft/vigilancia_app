import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/camera_screen.dart';
import 'screens/viewer_screen.dart';

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
  final _hostController = TextEditingController();

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  void _openViewer() {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Escribe la IP mostrada en el teléfono cámara.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ViewerScreen(host: host),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vigilancia Wi-Fi')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.videocam_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
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
            const SizedBox(height: 12),
            TextField(
              controller: _hostController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _openViewer(),
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
              decoration: const InputDecoration(
                labelText: 'IP del teléfono cámara',
                hintText: '192.168.1.25',
                prefixIcon: Icon(Icons.router_outlined),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _openViewer,
              icon: const Icon(Icons.link),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Conectar como visor'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
