import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const int signalingPort = 8080;

enum SignalingMessageType { offer, answer, candidate }

class SignalingMessage {
  const SignalingMessage._({
    required this.type,
    this.sdp,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  factory SignalingMessage.description(SignalingMessageType type, String sdp) {
    if (type != SignalingMessageType.offer &&
        type != SignalingMessageType.answer) {
      throw ArgumentError('Una descripción SDP no puede ser de ese tipo.');
    }
    return SignalingMessage._(type: type, sdp: sdp);
  }

  factory SignalingMessage.candidate({
    required String candidate,
    required String? sdpMid,
    required int? sdpMLineIndex,
  }) {
    return SignalingMessage._(
      type: SignalingMessageType.candidate,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
    );
  }

  factory SignalingMessage.fromJson(Map<String, Object?> json) {
    final typeName = json['type'];
    final type = SignalingMessageType.values
        .where((element) => element.name == typeName);

    if (type.isEmpty) {
      throw const FormatException('Tipo de señalización desconocido.');
    }

    return switch (type.first) {
      SignalingMessageType.offer => SignalingMessage.description(
          SignalingMessageType.offer,
          _requiredString(json, 'sdp'),
        ),
      SignalingMessageType.answer => SignalingMessage.description(
          SignalingMessageType.answer,
          _requiredString(json, 'sdp'),
        ),
      SignalingMessageType.candidate => SignalingMessage.candidate(
          candidate: _requiredString(json, 'candidate'),
          sdpMid: json['sdpMid'] as String?,
          sdpMLineIndex: (json['sdpMLineIndex'] as num?)?.toInt(),
        ),
    };
  }

  final SignalingMessageType type;
  final String? sdp;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  Map<String, Object?> toJson() {
    return switch (type) {
      SignalingMessageType.offer || SignalingMessageType.answer => {
          'type': type.name,
          'sdp': sdp,
        },
      SignalingMessageType.candidate => {
          'type': type.name,
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
        },
    };
  }

  String encode() => '${jsonEncode(toJson())}\n';

  static SignalingMessage decode(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Mensaje de señalización no válido.');
    }
    return SignalingMessage.fromJson(decoded);
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Falta el campo "$key".');
    }
    return value;
  }
}

class AndroidPermissions {
  const AndroidPermissions._();

  static Future<void> requestCameraMode() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      throw const CameraPermissionException(
        'Se necesita el permiso de cámara para transmitir video.',
      );
    }
  }

  static Future<void> requestLocalNetwork() async {
    final info = await DeviceInfoPlugin().androidInfo;
    final sdkInt = info.version.sdkInt;

    // Hasta Android 16, INTERNET permite los sockets TCP de la LAN. Android 17
    // exige ACCESS_LOCAL_NETWORK cuando la app está actualizada para ese SDK.
    if (sdkInt >= 37) {
      final localStatus = await Permission.accessLocalNetwork.request();
      if (!localStatus.isGranted) {
        throw const LocalNetworkPermissionException(
          'Permiso de red local denegado. Actívalo en los ajustes de la app.',
        );
      }
    }
  }

  static Future<bool> get canOpenLocalNetworkSettings async {
    return openAppSettings();
  }
}

class CameraPermissionException implements Exception {
  const CameraPermissionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalNetworkPermissionException implements Exception {
  const LocalNetworkPermissionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Canal TCP local para intercambiar SDP y candidatos ICE.
///
/// Usa JSON delimitado por saltos de línea porque una lectura de Socket puede
/// contener varios mensajes o solo una parte de uno.
class StreamingService {
  StreamingService();

  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription<String>? _subscription;
  final _pendingLines = StringBuffer();
  bool _disposed = false;
  bool _isServer = false;

  final _messageController = StreamController<SignalingMessage>.broadcast();
  final _connectionController = StreamController<Socket>.broadcast();
  final _disconnectionController = StreamController<Socket>.broadcast();
  final _errorController = StreamController<Object>.broadcast();

  Stream<SignalingMessage> get messages => _messageController.stream;
  Stream<Socket> get connections => _connectionController.stream;
  Stream<Socket> get disconnections => _disconnectionController.stream;
  Stream<Object> get errors => _errorController.stream;

  bool get isConnected => _socket != null && !_disposed;

  Socket? get currentSocket => _socket;

  bool get isServerRunning => _isServer && _server != null && !_disposed;

  bool isCurrentSocket(Socket? socket) => identical(_socket, socket);

  /// Devuelve primero las direcciones de interfaces Wi-Fi y, después, otras
  /// interfaces privadas. Así se evita mostrar una IP de VPN o de datos móviles.
  Future<List<String>> getLocalIPv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final wifiAddresses = <String>[];
      final otherPrivateAddresses = <String>[];

      for (final interface in interfaces) {
        final interfaceName = interface.name.toLowerCase();
        if (_isVirtualInterface(interfaceName)) continue;

        for (final address in interface.addresses) {
          final value = address.address;
          if (value.isEmpty || address.isLoopback) continue;
          if (!_isPrivateIPv4(value)) continue;

          final destination = _isWifiInterface(interfaceName)
              ? wifiAddresses
              : otherPrivateAddresses;
          if (!destination.contains(value)) destination.add(value);
        }
      }

      return [...wifiAddresses, ...otherPrivateAddresses];
    } on Object {
      return const [];
    }
  }

  Future<String?> getLocalIPv4Address() async {
    final addresses = await getLocalIPv4Addresses();
    return addresses.isEmpty ? null : addresses.first;
  }

  static bool _isWifiInterface(String name) {
    return name.contains('wlan') ||
        name.contains('wifi') ||
        name.contains('ath') ||
        name == 'ap0' ||
        name.startsWith('ap');
  }

  static bool _isVirtualInterface(String name) {
    return name == 'lo' ||
        name.contains('tun') ||
        name.contains('tap') ||
        name.contains('ppp') ||
        name.contains('vpn') ||
        name.contains('rmnet') ||
        name.contains('ccmni') ||
        name.contains('usb') ||
        name.contains('docker') ||
        name.contains('emulator') ||
        name.contains('vbox');
  }

  static bool _isPrivateIPv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == null || second == null || first == 0 || first > 255) {
      return false;
    }
    if (first == 10) return true;
    if (first == 192 && second == 168) return true;
    return first == 172 && second >= 16 && second <= 31;
  }

  Future<void> startServer() async {
    await _closeClient();
    _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      signalingPort,
    );
    _isServer = true;
    _server!.listen(
      (socket) {
        unawaited(_acceptSocket(socket));
      },
      onError: (Object error) {
        if (!_disposed) _errorController.add(error);
      },
    );
  }

  Future<void> _acceptSocket(Socket socket) async {
    await _closeClient();
    _socket = socket;
    _pendingLines.clear();
    _subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim().isEmpty) return;
        try {
          _messageController.add(SignalingMessage.decode(line));
        } on Object catch (error) {
          if (!_disposed) {
            _errorController.add(FormatException('Señal inválida: $error'));
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_disposed) _errorController.add(error);
        unawaited(_handleClientClosed(socket));
      },
      onDone: () => unawaited(_handleClientClosed(socket)),
      cancelOnError: false,
    );
    if (!_disposed) _connectionController.add(socket);
  }

  Future<void> connect(String host) async {
    await _closeClient();
    final normalizedHost = normalizeHost(host);
    _isServer = false;
    final socket = await Socket.connect(
      normalizedHost,
      signalingPort,
      timeout: const Duration(seconds: 10),
    );
    _socket = socket;
    _pendingLines.clear();
    _subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim().isEmpty) return;
        try {
          _messageController.add(SignalingMessage.decode(line));
        } on Object catch (error) {
          if (!_disposed) {
            _errorController.add(FormatException('Señal inválida: $error'));
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_disposed) _errorController.add(error);
        unawaited(_handleClientClosed(socket));
      },
      onDone: () => unawaited(_handleClientClosed(socket)),
      cancelOnError: false,
    );
  }

  void send(SignalingMessage message) {
    final socket = _socket;
    if (socket == null) {
      throw const SocketException('No existe una conexión de señalización.');
    }
    socket.write(message.encode());
  }

  Future<void> _handleClientClosed(Socket socket) async {
    if (!identical(_socket, socket)) return;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    if (!_disposed) _disconnectionController.add(socket);
  }

  Future<void> _closeClient() async {
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    _pendingLines.clear();
    if (socket != null) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    await _closeClient();
    await _server?.close();
    _server = null;
    _isServer = false;
  }

  Future<void> reset() async {
    if (_disposed) return;
    await _closeClient();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await _closeClient();
    await _server?.close();
    _server = null;
    _isServer = false;
    _disposed = true;
    await _messageController.close();
    await _connectionController.close();
    await _disconnectionController.close();
    await _errorController.close();
  }

  static String normalizeHost(String value) {
    var host = value.trim();
    if (host.startsWith('http://') || host.startsWith('https://')) {
      host = Uri.parse(host).host;
    }
    host = host.replaceAll(RegExp(r'\s'), '');
    if (host.isEmpty) {
      throw const FormatException('La dirección de la cámara está vacía.');
    }
    return host;
  }
}
