import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/streaming_service.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({required this.host, super.key});

  final String host;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  static const _configuration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
    'sdpSemantics': 'unified-plan',
  };

  final _remoteRenderer = RTCVideoRenderer();
  StreamingService _streamingService = StreamingService();
  final _pendingCandidates = <RTCIceCandidate>[];

  RTCPeerConnection? _peerConnection;
  StreamSubscription<SignalingMessage>? _messageSubscription;
  StreamSubscription<Socket>? _disconnectionSubscription;
  StreamSubscription<Object>? _errorSubscription;
  bool _remoteDescriptionSet = false;
  Future<void> _messageQueue = Future<void>.value();
  int _sessionId = 0;
  bool _rendererInitialized = false;
  bool _connecting = true;
  String _status = 'Conectando con la cámara…';
  String? _error;
  bool _needsSettings = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await AndroidPermissions.requestLocalNetwork();
      if (!mounted) return;

      if (!_rendererInitialized) {
        await _remoteRenderer.initialize();
        _rendererInitialized = true;
      }
      final peer = await createPeerConnection(_configuration);
      if (!mounted) {
        await peer.close();
        return;
      }

      _peerConnection = peer;
      _registerPeerConnection(peer);
      _messageSubscription = _streamingService.messages.listen(_enqueueMessage);
      _disconnectionSubscription = _streamingService.disconnections.listen((_) {
        if (mounted) {
          _showError('El teléfono cámara cerró la conexión.');
        }
      });
      _errorSubscription = _streamingService.errors.listen((error) {
        if (mounted) {
          _showError('Error de red local: $error', needsSettings: true);
        }
      });

      await _streamingService.connect(widget.host);
      if (mounted) {
        _setStatus('Conectado al teléfono cámara');
      }
    } on LocalNetworkPermissionException catch (error) {
      _showError(error.message, needsSettings: true);
    } on TimeoutException {
      _showError(
        'La conexión agotó el tiempo. Comprueba la IP, que ambos teléfonos estén en la misma Wi-Fi y que no haya VPN.',
      );
    } on SocketException catch (error) {
      _showError('No se pudo conectar: ${error.message}');
    } on Object catch (error) {
      _showError('No se pudo iniciar el visor: $error');
    }
  }

  void _registerPeerConnection(RTCPeerConnection peer) {
    peer.onAddStream = (stream) {
      if (!mounted) return;
      setState(() {
        _remoteRenderer.srcObject = stream;
        _status = 'Transmitiendo video';
        _error = null;
        _connecting = false;
      });
    };

    peer.onTrack = (event) {
      if (!mounted || event.streams.isEmpty) return;
      setState(() {
        _remoteRenderer.srcObject = event.streams.first;
        _status = 'Transmitiendo video';
        _error = null;
        _connecting = false;
      });
    };

    // onAddTrack es el respaldo para versiones del plugin que no rellenan
    // event.streams, y entrega el MediaStream nativo que sí puede renderizarse.
    peer.onAddTrack = (stream, track) {
      if (!mounted || track.kind != 'video') return;
      setState(() {
        _remoteRenderer.srcObject = stream;
        _status = 'Transmitiendo video';
        _error = null;
        _connecting = false;
      });
    };

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
        // La cámara puede desconectarse mientras se genera un candidato.
      }
    };

    peer.onIceConnectionState = (state) {
      if (!mounted || !identical(_peerConnection, peer)) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _setStatus('Video conectado');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _showError('No se pudo conectar con la cámara. Revisa la red Wi-Fi.');
      }
    };

    peer.onConnectionState = (state) {
      if (!mounted || !identical(_peerConnection, peer)) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus('Video conectado');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _showError('La conexión WebRTC falló.');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _setStatus('Conexión interrumpida');
      }
    };
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
        case SignalingMessageType.offer:
          await peer.setRemoteDescription(
            RTCSessionDescription(message.sdp!, 'offer'),
          );
          _remoteDescriptionSet = true;
          await _flushPendingCandidates();

          final answer = await peer.createAnswer();
          await peer.setLocalDescription(answer);
          final localDescription = await peer.getLocalDescription();
          _streamingService.send(
            SignalingMessage.description(
              SignalingMessageType.answer,
              localDescription?.sdp ?? answer.sdp!,
            ),
          );
        case SignalingMessageType.answer:
          throw const FormatException('La cámara no debe enviar una respuesta.');
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
      }
    } on Object catch (error) {
      if (mounted) _showError('Error de señalización: $error');
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

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
      _error = null;
      _needsSettings = false;
      _connecting = false;
    });
  }

  void _showError(String value, {bool needsSettings = false}) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _status = 'Error';
      _error = value;
      _needsSettings = needsSettings;
    });
  }

  Future<void> _retry() async {
    _sessionId++;
    _messageQueue = Future<void>.value();
    await _messageSubscription?.cancel();
    await _disconnectionSubscription?.cancel();
    await _errorSubscription?.cancel();
    _messageSubscription = null;
    _disconnectionSubscription = null;
    _errorSubscription = null;
    await _streamingService.close();
    _streamingService = StreamingService();
    final peer = _peerConnection;
    _peerConnection = null;
    try {
      await peer?.close();
      await peer?.dispose();
    } on Object {
      // Puede haber sido cerrado por el sistema al perder la conexión.
    }
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _remoteRenderer.srcObject = null;
    if (!mounted) return;
    setState(() {
      _connecting = true;
      _status = 'Conectando…';
      _error = null;
      _needsSettings = false;
    });

    await _initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Visor · ${widget.host}'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_remoteRenderer.srcObject == null)
              ColoredBox(
                color: Colors.black,
                child: Center(
                  child: _connecting && _error == null
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                        )
                      : const Icon(
                          Icons.videocam_off,
                          color: Colors.white54,
                          size: 72,
                        ),
                ),
              )
            else
              RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Card(
                color: Colors.black.withValues(alpha: 0.72),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reintentar'),
                        ),
                        if (_needsSettings) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: openAppSettings,
                            icon: const Icon(Icons.settings),
                            label: const Text('Abrir permisos de la app'),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _closePeer(RTCPeerConnection? peer) async {
    if (peer == null) return;
    try {
      await peer.close();
      await peer.dispose();
    } on Object {
      // Puede haber sido cerrado por el sistema al perder la conexión.
    }
  }

  @override
  void dispose() {
    unawaited(_messageSubscription?.cancel());
    unawaited(_disconnectionSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_streamingService.dispose());
    final peer = _peerConnection;
    _peerConnection = null;
    unawaited(_closePeer(peer));
    _remoteRenderer.dispose();
    super.dispose();
  }
}
