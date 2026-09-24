import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/streaming_service.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({required this.hosts, super.key});

  final List<String> hosts;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final List<_CameraSession> _sessions;
  bool _requestingPermission = true;
  String? _permissionError;
  int? _expandedIndex;

  @override
  void initState() {
    super.initState();
    _sessions = widget.hosts
        .map((host) => _CameraSession(host: host, onChanged: _onSessionChanged))
        .toList(growable: false);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await AndroidPermissions.requestLocalNetwork();
      if (!mounted) return;
      setState(() {
        _requestingPermission = false;
        _permissionError = null;
      });
      await Future.wait(_sessions.map((session) => session.connect()));
    } on LocalNetworkPermissionException catch (error) {
      if (mounted) {
        setState(() {
          _requestingPermission = false;
          _permissionError = error.message;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _requestingPermission = false;
          _permissionError = 'No se pudo iniciar el visor: $error';
        });
      }
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _expandCamera(int index) {
    setState(() => _expandedIndex = index);
  }

  void _collapseCamera() {
    setState(() => _expandedIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    final expandedIndex = _expandedIndex;

    return PopScope<void>(
      canPop: expandedIndex == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && expandedIndex != null) {
          _collapseCamera();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(
            expandedIndex == null
                ? 'Visor multicámara'
                : 'Cámara ${expandedIndex + 1} · ${_sessions[expandedIndex].host}',
          ),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: expandedIndex == null
              ? null
              : IconButton(
                  onPressed: _collapseCamera,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Volver a la cuadrícula',
                ),
        ),
        body: SafeArea(
          child: _permissionError != null
              ? _PermissionErrorView(
                  message: _permissionError!,
                  onRetry: () {
                    setState(() {
                      _requestingPermission = true;
                      _permissionError = null;
                    });
                    unawaited(_initialize());
                  },
                )
              : expandedIndex != null
                  ? _ExpandedCameraView(
                      session: _sessions[expandedIndex],
                      onCollapse: _collapseCamera,
                    )
                  : _CameraGrid(
                      sessions: _sessions,
                      requestingPermission: _requestingPermission,
                      onTap: _expandCamera,
                    ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      unawaited(session.dispose());
    }
    super.dispose();
  }
}

class _CameraGrid extends StatelessWidget {
  const _CameraGrid({
    required this.sessions,
    required this.requestingPermission,
    required this.onTap,
  });

  final List<_CameraSession> sessions;
  final bool requestingPermission;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    if (requestingPermission) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Solicitando permiso de red…',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    if (sessions.isEmpty) {
      return const Center(
        child: Text(
          'No hay cámaras configuradas.',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    final columns = sessions.length == 1 ? 1 : 2;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.builder(
        itemCount: sessions.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: columns == 1 ? 16 / 10 : 0.78,
        ),
        itemBuilder: (context, index) {
          return _CameraTile(
            index: index,
            session: sessions[index],
            onTap: () => onTap(index),
          );
        },
      ),
    );
  }
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({
    required this.index,
    required this.session,
    required this.onTap,
  });

  final int index;
  final _CameraSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ampliar cámara ${index + 1}',
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color: const Color(0xFF171717),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (session.hasVideo)
                RTCVideoView(
                  session.renderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                )
              else
                _CameraPlaceholder(session: session),
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: _TileLabel(
                        text: 'Cámara ${index + 1}',
                        subtitle: session.host,
                      ),
                    ),
                    IconButton(
                      onPressed: () => unawaited(session.retry()),
                      tooltip: 'Reconectar cámara ${index + 1}',
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: _TileStatus(session: session),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpandedCameraView extends StatelessWidget {
  const _ExpandedCameraView({required this.session, required this.onCollapse});

  final _CameraSession session;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (session.hasVideo)
          RTCVideoView(
            session.renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          )
        else
          _CameraPlaceholder(session: session),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Card(
            color: Colors.black.withValues(alpha: 0.72),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Cámara · ${session.host}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          session.status,
                          style: TextStyle(
                            color: session.hasVideo
                                ? Colors.greenAccent
                                : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => unawaited(session.retry()),
                    tooltip: 'Reconectar',
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  IconButton(
                    onPressed: onCollapse,
                    tooltip: 'Volver a la cuadrícula',
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({required this.session});

  final _CameraSession session;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF171717),
      child: Center(
        child: session.isConnecting
            ? const CircularProgressIndicator(color: Colors.white)
            : Icon(
                session.error == null
                    ? Icons.videocam_off
                    : Icons.warning_amber,
                color: session.error == null ? Colors.white54 : Colors.amber,
                size: 42,
              ),
      ),
    );
  }
}

class _TileLabel extends StatelessWidget {
  const _TileLabel({required this.text, required this.subtitle});

  final String text;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _TileStatus extends StatelessWidget {
  const _TileStatus({required this.session});

  final _CameraSession session;

  @override
  Widget build(BuildContext context) {
    final text = session.error ?? session.status;
    final color = session.hasVideo
        ? Colors.greenAccent
        : session.error == null
            ? Colors.white70
            : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}

class _PermissionErrorView extends StatelessWidget {
  const _PermissionErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          color: const Color(0xFF171717),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, color: Colors.amber, size: 48),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
                TextButton.icon(
                  onPressed: openAppSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Abrir permisos de la app'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraSession {
  _CameraSession({required this.host, required this.onChanged});

  static const _configuration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
    'sdpSemantics': 'unified-plan',
  };

  final String host;
  final VoidCallback onChanged;
  StreamingService _streamingService = StreamingService();
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];

  Future<void> _operation = Future<void>.value();
  RTCPeerConnection? _peerConnection;
  StreamSubscription<SignalingMessage>? _messageSubscription;
  StreamSubscription<Socket>? _disconnectionSubscription;
  StreamSubscription<Object>? _errorSubscription;
  Future<void> _messageQueue = Future<void>.value();
  int _sessionId = 0;
  bool _rendererInitialized = false;
  bool _remoteDescriptionSet = false;
  bool _isConnecting = false;
  bool _closed = false;
  String _status = 'Esperando conexión';
  String? _error;

  bool get hasVideo => renderer.srcObject != null;
  bool get isConnecting => _isConnecting;
  String get status => _status;
  String? get error => _error;

  Future<void> connect() {
    _operation = _operation.then((_) => _connectOnce());
    return _operation;
  }

  Future<void> _connectOnce() async {
    if (_closed) return;
    _isConnecting = true;
    _error = null;
    _status = 'Conectando…';
    _notify();

    final session = _sessionId;
    try {
      if (!_rendererInitialized) {
        await renderer.initialize();
        _rendererInitialized = true;
      }
      if (!_isCurrent(session)) return;

      final peer = await createPeerConnection(_configuration);
      if (!_isCurrent(session)) {
        await _closePeer(peer);
        return;
      }
      _peerConnection = peer;
      _registerPeerConnection(peer, session);
      _messageSubscription = _streamingService.messages.listen((message) {
        if (_isCurrent(session)) _enqueueMessage(message, session, peer);
      });
      _disconnectionSubscription =
          _streamingService.disconnections.listen((_) {
        if (_isCurrent(session)) {
          _setError('La cámara cerró la conexión');
        }
      });
      _errorSubscription = _streamingService.errors.listen((error) {
        if (_isCurrent(session)) {
          _setError('Error de red: $error');
        }
      });

      await _streamingService.connect(host);
      if (!_isCurrent(session)) return;
      _isConnecting = false;
      _status = 'Conectado al teléfono cámara';
      _notify();
    } on TimeoutException {
      if (_isCurrent(session)) _setError('Tiempo de conexión agotado');
    } on SocketException catch (error) {
      if (_isCurrent(session)) {
        _setError('No se pudo conectar: ${error.message}');
      }
    } on Object catch (error) {
      if (_isCurrent(session)) _setError('Error: $error');
    }
  }

  bool _isCurrent(int session) => !_closed && session == _sessionId;

  void _registerPeerConnection(RTCPeerConnection peer, int session) {
    void setStream(MediaStream stream) {
      if (_isCurrent(session) && identical(_peerConnection, peer)) {
        _setVideoStream(stream);
      }
    }

    peer.onAddStream = setStream;
    peer.onTrack = (event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      setStream(event.streams.first);
    };
    peer.onAddTrack = (stream, track) {
      if (track.kind == 'video') setStream(stream);
    };
    peer.onRemoveStream = (stream) {
      if (_isCurrent(session) && identical(_peerConnection, peer)) {
        renderer.srcObject = null;
        _setError('La cámara dejó de enviar video');
      }
    };
    peer.onIceCandidate = (candidate) {
      if (!_isCurrent(session) ||
          !identical(_peerConnection, peer) ||
          candidate.candidate == null) {
        return;
      }
      try {
        _streamingService.send(
          SignalingMessage.candidate(
            candidate: candidate.candidate!,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        );
      } on Object {
        // La conexión puede cerrarse mientras ICE termina de trabajar.
      }
    };
    peer.onIceConnectionState = (state) {
      if (!_isCurrent(session) || !identical(_peerConnection, peer)) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _setStatus('Video conectado');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _setError('La conexión de video falló');
      }
    };
    peer.onConnectionState = (state) {
      if (!_isCurrent(session) || !identical(_peerConnection, peer)) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus('Video conectado');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        renderer.srcObject = null;
        _setError('Conexión con la cámara interrumpida');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        renderer.srcObject = null;
        _setError('La conexión WebRTC falló');
      }
    };
  }

  void _setVideoStream(MediaStream stream) {
    if (_closed) return;
    renderer.srcObject = stream;
    _isConnecting = false;
    _status = 'Transmitiendo video';
    _error = null;
    _notify();
  }

  void _enqueueMessage(
    SignalingMessage message,
    int session,
    RTCPeerConnection peer,
  ) {
    _messageQueue = _messageQueue.then((_) async {
      if (!_isCurrent(session) || !identical(_peerConnection, peer)) return;
      await _handleMessage(message, session, peer);
    });
  }

  Future<void> _handleMessage(
    SignalingMessage message,
    int session,
    RTCPeerConnection peer,
  ) async {
    if (!_isCurrent(session) || !identical(_peerConnection, peer)) return;

    try {
      switch (message.type) {
        case SignalingMessageType.offer:
          await peer.setRemoteDescription(
            RTCSessionDescription(message.sdp!, 'offer'),
          );
          _remoteDescriptionSet = true;
          if (!_isCurrent(session) || !identical(_peerConnection, peer)) {
            return;
          }
          await _flushPendingCandidates(peer);
          if (!_isCurrent(session) || !identical(_peerConnection, peer)) {
            return;
          }
          final answer = await peer.createAnswer();
          await peer.setLocalDescription(answer);
          if (!_isCurrent(session) || !identical(_peerConnection, peer)) {
            return;
          }
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
      _setError('Error de señalización: $error');
    }
  }

  Future<void> _flushPendingCandidates(RTCPeerConnection peer) async {
    for (final candidate in _pendingCandidates) {
      await peer.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> retry() async {
    if (_closed) return;
    _sessionId++;
    _messageQueue = Future<void>.value();
    _isConnecting = true;
    _error = null;
    _status = 'Reconectando…';
    _notify();
    await _cleanupConnection();
    if (_closed) return;
    await connect();
  }

  Future<void> _cleanupConnection() async {
    await _messageSubscription?.cancel();
    await _disconnectionSubscription?.cancel();
    await _errorSubscription?.cancel();
    _messageSubscription = null;
    _disconnectionSubscription = null;
    _errorSubscription = null;
    final service = _streamingService;
    _streamingService = StreamingService();
    await service.close();
    final peer = _peerConnection;
    _peerConnection = null;
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    renderer.srcObject = null;
    await _closePeer(peer);
  }

  void _setStatus(String value) {
    if (_closed) return;
    _isConnecting = false;
    _status = value;
    _error = null;
    _notify();
  }

  void _setError(String value) {
    if (_closed) return;
    _isConnecting = false;
    _status = 'Error';
    _error = value;
    _notify();
  }

  void _notify() => onChanged();

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _sessionId++;
    await _cleanupConnection();
    await _operation;
    await _streamingService.dispose();
    await renderer.dispose();
  }

  Future<void> _closePeer(RTCPeerConnection? peer) async {
    if (peer == null) return;
    try {
      await peer.close();
      await peer.dispose();
    } on Object {
      // Puede haber sido cerrado por Android al perder la conexión.
    }
  }
}
