import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/streaming_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const _configuration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
    'sdpSemantics': 'unified-plan',
  };

  final _localRenderer = RTCVideoRenderer();
  final _streamingService = StreamingService();
  final _pendingCandidates = <RTCIceCandidate>[];

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  StreamSubscription<SignalingMessage>? _messageSubscription;
  StreamSubscription<Socket>? _connectionSubscription;
  StreamSubscription<Socket>? _disconnectionSubscription;
  StreamSubscription<Object>? _errorSubscription;
  bool _remoteDescriptionSet = false;
  Future<void> _messageQueue = Future<void>.value();
  int _sessionId = 0;
  bool _starting = true;
  String _status = 'Preparando cámara…';
  String? _localIp;
  Object? _error;
  bool _permissionNeedsSettings = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await AndroidPermissions.requestCameraMode();
      await AndroidPermissions.requestLocalNetwork();
      if (!mounted) return;

      await _localRenderer.initialize();
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 640},
          'height': {'ideal': 360},
          'frameRate': {'ideal': 15, 'max': 15},
        },
      });
      if (!mounted) {
        await _stopLocalStream();
        return;
      }
      _localRenderer.srcObject = _localStream;
      _localIp = await _streamingService.getLocalIPv4Address();

      _messageSubscription = _streamingService.messages.listen(_enqueueMessage);
      _connectionSubscription = _streamingService.connections.listen(
        _handleConnection,
      );
      _disconnectionSubscription = _streamingService.disconnections.listen(
        (_) => _handleViewerDisconnected(),
      );
      _errorSubscription = _streamingService.errors.listen((error) {
        if (mounted) {
          _showError('Error de red local: $error', needsSettings: true);
        }
      });

      await _streamingService.startServer();
      if (mounted) {
        setState(() {
          _starting = false;
          _status = 'Esperando un visor en la misma Wi-Fi';
          _error = null;
        });
      }
    } on CameraPermissionException catch (error) {
      _showError(error.message, needsSettings: true);
    } on LocalNetworkPermissionException catch (error) {
      _showError(error.message, needsSettings: true);
    } on Object catch (error) {
      _showError('No se pudo iniciar la cámara: $error');
    }
  }

  Future<void> _handleConnection(Socket socket) async {
    if (!identical(_streamingService.currentSocket, socket)) return;
    _sessionId++;
    _messageQueue = Future<void>.value();
    await _resetPeerConnection();
    if (!mounted) return;

    final stream = _localStream;
    if (stream == null) {
      _showError('La cámara no está lista.');
      return;
    }

    try {
      final peer = await createPeerConnection(_configuration);
      if (!mounted) {
        await peer.close();
        return;
      }

      _peerConnection = peer;
      _remoteDescriptionSet = false;
      _pendingCandidates.clear();

      for (final track in stream.getVideoTracks()) {
        final sender = await peer.addTrack(track, stream);
        final parameters = sender.parameters;
        if (parameters.encodings != null && parameters.encodings!.isNotEmpty) {
          parameters.encodings!.first.maxBitrate = 500000;
          parameters.encodings!.first.maxFramerate = 15;
          await sender.setParameters(parameters);
        }
      }

      peer.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        try {
          _streamingService.send(
            SignalingMessage.candidate(
              candidate: candidate.candidate!,
              sdpMid: candidate.sdpMid,
              sdpMLineIndex: candidate.sdpMLineIndex,
            ),
          );
        } on Object {
          // El visor puede desconectarse mientras se genera el candidato.
        }
      };
      peer.onIceConnectionState = (state) {
        if (!mounted || !identical(_peerConnection, peer)) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _setStatus('Visor conectado');
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _showError('No se pudo establecer la conexión de video.');
        }
      };
      peer.onConnectionState = (state) {
        if (!mounted || !identical(_peerConnection, peer)) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _setStatus('Visor conectado');
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _showError('La conexión WebRTC falló.');
        }
      };

      final offer = await peer.createOffer({
        'offerToReceiveVideo': true,
        'offerToReceiveAudio': false,
      });
      await peer.setLocalDescription(offer);
      final localDescription = await peer.getLocalDescription();
      _streamingService.send(
        SignalingMessage.description(
          SignalingMessageType.offer,
          localDescription?.sdp ?? offer.sdp!,
        ),
      );
      _setStatus('Negociando con el visor…');
    } on Object catch (error) {
      _showError('No se pudo iniciar la negociación: $error');
    }
  }

  void _enqueueMessage(SignalingMessage message) {
    final session = _sessionId;
    _messageQueue = _messageQueue.then((_) async {
      if (!mounted || session != _sessionId) return;
      await _handleMessage(message);
    });
  }

  Future<void> _handleMessage(SignalingMessage message) async {
    final peer = _peerConnection;
    if (peer == null) return;

    try {
      switch (message.type) {
        case SignalingMessageType.answer:
          await peer.setRemoteDescription(
            RTCSessionDescription(message.sdp!, 'answer'),
          );
          _remoteDescriptionSet = true;
          await _flushPendingCandidates();
        case SignalingMessageType.candidate:
          final candidate = RTCIceCandidate(
            message.candidate,
            message.sdpMid,
            message.sdpMLineIndex,
          );
          if (_remoteDescriptionSet) {
            await peer.addCandidate(candidate);
          } else {
            _pendingCandidates.add(candidate);
          }
        case SignalingMessageType.offer:
          throw const FormatException('El visor no debe enviar una oferta.');
      }
    } on Object catch (error) {
      if (mounted) {
        _showError('Error de señalización: $error', needsSettings: true);
      }
    }
  }

  Future<void> _flushPendingCandidates() async {
    final peer = _peerConnection;
    if (peer == null) return;
    for (final candidate in _pendingCandidates) {
      await peer.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  void _handleViewerDisconnected() {
    if (!mounted) return;
    _sessionId++;
    _messageQueue = Future<void>.value();
    unawaited(_resetPeerConnection());
    setState(() {
      _status = 'Visor desconectado. Esperando otra conexión…';
    });
  }

  Future<void> _resetPeerConnection() async {
    final peer = _peerConnection;
    _peerConnection = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    try {
      await peer?.close();
      await peer?.dispose();
    } on Object {
      // Un PeerConnection ya cerrado por Android puede lanzar al cerrarlo otra vez.
    }
  }

  Future<void> _stopLocalStream() async {
    final stream = _localStream;
    _localStream = null;
    for (final track in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      track.stop();
    }
    try {
      await stream?.dispose();
    } on Object {
      // La pista ya fue liberada; no es necesario mostrar otro error al salir.
    }
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
      _error = null;
      _permissionNeedsSettings = false;
    });
  }

  void _showError(String value, {bool needsSettings = false}) {
    if (!mounted) return;
    setState(() {
      _starting = false;
      _status = 'Error';
      _error = value;
      _permissionNeedsSettings = needsSettings;
    });
  }

  void _openSettings() {
    openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Teléfono cámara')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _localStream == null
                  ? Center(
                      child: _starting
                          ? const CircularProgressIndicator()
                          : const Icon(Icons.videocam_off, size: 64),
                    )
                  : RTCVideoView(
                      _localRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
            ),
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_localIp != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      'En el visor escribe: $_localIp',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Text(
                      'Puerto TCP: $signalingPort',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    if (_permissionNeedsSettings) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Abrir permisos de la app'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_messageSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_disconnectionSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_streamingService.dispose());
    unawaited(_resetPeerConnection());
    unawaited(_stopLocalStream());
    _localRenderer.dispose();
    super.dispose();
  }
}
