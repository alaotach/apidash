import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  });

  final WebSocketConnectionState connectionState;
  final List<WebSocketMessage> messages;
  final String? error;
  final DateTime? connectedAt;

  bool get isConnected =>
      connectionState == WebSocketConnectionState.connected;

  WebSocketSessionState copyWith({
    WebSocketConnectionState? connectionState,
    List<WebSocketMessage>? messages,
    String? error,
    DateTime? connectedAt,
  }) {
    return WebSocketSessionState(
      connectionState: connectionState ?? this.connectionState,
      messages: messages ?? this.messages,
      error: error,
      connectedAt: connectedAt ?? this.connectedAt,
    );
  }
}

class WebSocketNotifier extends StateNotifier<WebSocketSessionState> {
  WebSocketNotifier() : super(const WebSocketSessionState());


  final _service = WebSocketService();
  StreamSubscription<WebSocketMessage>? _sub;

  Future<void> connect(String url, {Map<String, String> headers = const {}}) async {
    state = state.copyWith(
      connectionState: WebSocketConnectionState.connecting,
      messages: [],
      error: null,
    );
    try {
      final stream = _service.connect(url, headers: headers);
      state = state.copyWith(
        connectionState: WebSocketConnectionState.connected,
        connectedAt: DateTime.now(),
      );
      _sub = stream.listen(
        (msg) {
          state = state.copyWith(
            messages: [...state.messages, msg],
          );
        },
        onDone: () {
          state = state.copyWith(
            connectionState: WebSocketConnectionState.disconnected,
          );
        },
        onError: (e) {
          state = WebSocketSessionState(
            connectionState: WebSocketConnectionState.disconnected,
            messages: state.messages,
            error: e.toString(),
          );
        },
      );
    } catch (e) {
      state = WebSocketSessionState(
        connectionState: WebSocketConnectionState.disconnected,
        error: e.toString(),
      );
    }
  }

  void sendMessage(String payload) {
    if (!state.isConnected) return;
    try {
      _service.sendMessage(payload);
      final msg = WebSocketMessage(
        payload: payload,
        isSent: true,
        timestamp: DateTime.now(),
        type: 'text',
        sizeBytes: payload.length,
      );
      state = state.copyWith(messages: [...state.messages, msg]);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _service.disconnect();
    state = state.copyWith(
      connectionState: WebSocketConnectionState.disconnected,
    );
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
