import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/legacy.dart';
import 'package:better_networking/better_networking.dart';
import '../services/websocket_service.dart';

enum WebSocketConnectionState { disconnected, connecting, connected }

/// Holds the live connection state and message log for the active WebSocket session.
class WebSocketSessionState {
  const WebSocketSessionState({
    this.connectionState = WebSocketConnectionState.disconnected,
    this.messages = const [],
    this.error,
    this.connectedAt,
    this.connectedUrl,
    this.requestHeaders = const {},
    this.connectLatencyMs,
    this.handshakeRequestLine,
    this.handshakeResponseLine,
    this.negotiatedSubprotocol,
    List<String>? negotiatedExtensions = const [],
  }) : _negotiatedExtensions = negotiatedExtensions;

  final WebSocketConnectionState connectionState;
  final List<WebSocketMessage> messages;
  final String? error;
  final DateTime? connectedAt;
  final String? connectedUrl;
  final Map<String, String> requestHeaders;
  final int? connectLatencyMs;
  final String? handshakeRequestLine;
  final String? handshakeResponseLine;
  final String? negotiatedSubprotocol;
  final List<String>? _negotiatedExtensions;

  List<String> get negotiatedExtensions => _negotiatedExtensions ?? const [];

  bool get isConnected =>
      connectionState == WebSocketConnectionState.connected;

  WebSocketSessionState copyWith({
    WebSocketConnectionState? connectionState,
    List<WebSocketMessage>? messages,
    String? error,
    DateTime? connectedAt,
    String? connectedUrl,
    Map<String, String>? requestHeaders,
    int? connectLatencyMs,
    String? handshakeRequestLine,
    String? handshakeResponseLine,
    String? negotiatedSubprotocol,
    List<String>? negotiatedExtensions,
  }) {
    return WebSocketSessionState(
      connectionState: connectionState ?? this.connectionState,
      messages: messages ?? this.messages,
      error: error,
      connectedAt: connectedAt ?? this.connectedAt,
      connectedUrl: connectedUrl ?? this.connectedUrl,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      connectLatencyMs: connectLatencyMs ?? this.connectLatencyMs,
      handshakeRequestLine: handshakeRequestLine ?? this.handshakeRequestLine,
      handshakeResponseLine: handshakeResponseLine ?? this.handshakeResponseLine,
      negotiatedSubprotocol:
          negotiatedSubprotocol ?? this.negotiatedSubprotocol,
      negotiatedExtensions: negotiatedExtensions ?? _negotiatedExtensions,
    );
  }
}

class WebSocketNotifier extends StateNotifier<WebSocketSessionState> {
  WebSocketNotifier() : super(const WebSocketSessionState());

  final _service = WebSocketService();
  StreamSubscription<WebSocketMessage>? _sub;

  Future<void> connect(String url, {Map<String, String> headers = const {}}) async {
    final stopwatch = Stopwatch()..start();
    if (state.connectionState == WebSocketConnectionState.connected ||
        state.messages.isNotEmpty) {
      _appendSystemMessage('Reconnecting...');
    }
    state = state.copyWith(
      connectionState: WebSocketConnectionState.connecting,
      messages: [],
      error: null,
    );
    try {
      final stream = _service.connect(url, headers: headers);
      stopwatch.stop();
      state = state.copyWith(
        connectionState: WebSocketConnectionState.connected,
        connectedAt: DateTime.now(),
        connectedUrl: url,
        requestHeaders: headers,
        connectLatencyMs: stopwatch.elapsedMilliseconds,
        handshakeRequestLine: _buildRequestLine(url),
        handshakeResponseLine: '101 Switching Protocols',
        negotiatedSubprotocol: null,
        negotiatedExtensions: const [],
      );
      _appendSystemMessage('Connected to $url');
      _sub = stream.listen(
        (msg) {
          state = state.copyWith(
            messages: [...state.messages, msg],
          );
        },
        onDone: () {
          _appendSystemMessage('Connection closed by remote host.');
          state = state.copyWith(
            connectionState: WebSocketConnectionState.disconnected,
          );
        },
        onError: (e) {
          _appendErrorMessage(e.toString());
          state = state.copyWith(
            connectionState: WebSocketConnectionState.disconnected,
            error: e.toString(),
          );
        },
      );
    } catch (e) {
      state = WebSocketSessionState(
        connectionState: WebSocketConnectionState.disconnected,
        error: e.toString(),
        connectedUrl: url,
        requestHeaders: headers,
        handshakeRequestLine: _buildRequestLine(url),
      );
    }
  }

  void sendMessage(String payload) {
    sendText(payload);
  }

  void sendText(String payload) {
    if (!state.isConnected) return;
    try {
      _service.sendMessage(payload);
      final msg = WebSocketMessage(
        textPayload: payload,
        isSent: true,
        timestamp: DateTime.now(),
        type: 'text',
        sizeBytes: payload.length,
      );
      state = state.copyWith(messages: [...state.messages, msg]);
    } catch (e) {
      _appendErrorMessage(e.toString());
      state = state.copyWith(error: e.toString());
    }
  }

  void sendBinary(Uint8List bytes) {
    if (!state.isConnected) return;
    try {
      _service.sendBinaryMessage(bytes);
      final msg = WebSocketMessage(
        binaryPayload: bytes,
        isSent: true,
        timestamp: DateTime.now(),
        type: 'binary',
        sizeBytes: bytes.length,
      );
      state = state.copyWith(messages: [...state.messages, msg]);
    } catch (e) {
      _appendErrorMessage(e.toString());
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    await _service.disconnect();
    _appendSystemMessage('Disconnected.');
    state = state.copyWith(
      connectionState: WebSocketConnectionState.disconnected,
    );
  }

  Future<void> simulateDropConnection() async {
    if (!state.isConnected) return;
    await _sub?.cancel();
    _sub = null;
    await _service.disconnect();
    _appendErrorMessage('Simulated network drop.');
    state = state.copyWith(
      connectionState: WebSocketConnectionState.disconnected,
      error: 'Simulated network drop',
    );
  }

  void clearMessages() {
    state = state.copyWith(messages: const []);
  }

  void _appendErrorMessage(String error) {
    final next = WebSocketMessage(
      textPayload: error,
      isSent: false,
      timestamp: DateTime.now(),
      type: 'error',
      sizeBytes: error.length,
    );
    state = state.copyWith(messages: [...state.messages, next]);
  }

  void _appendSystemMessage(String text) {
    final next = WebSocketMessage(
      textPayload: text,
      isSent: false,
      timestamp: DateTime.now(),
      type: 'system',
      sizeBytes: text.length,
    );
    state = state.copyWith(messages: [...state.messages, next]);
  }

  String _buildRequestLine(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return 'GET / HTTP/1.1';
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return 'GET $path$query HTTP/1.1';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _service.disconnect();
    super.dispose();
  }
}

final webSocketNotifierProvider =
    StateNotifierProvider.autoDispose<WebSocketNotifier, WebSocketSessionState>(
  (ref) => WebSocketNotifier(),
);
