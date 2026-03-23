import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:better_networking/better_networking.dart';

/// Manages a single WebSocket connection lifecycle.
class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  bool get isConnected => _channel != null;

  /// Opens a WebSocket connection to [url] with optional [headers].
  ///
  /// Returns a [Stream] of [WebSocketMessage] for incoming frames, or
  /// `null`/error if the connection fails.
  Stream<WebSocketMessage> connect(
    String url, {
    Map<String, String> headers = const {},
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) throw ArgumentError('Invalid WebSocket URL: $url');

    _channel = WebSocketChannel.connect(uri, protocols: []); // TODO: pass custom headers via subprotocols or proxy layer

    final controller = StreamController<WebSocketMessage>.broadcast();

    _subscription = _channel!.stream.listen(
      (data) {
        final isText = data is String;
        final payload = isText ? data as String : '[binary data]';
        controller.add(WebSocketMessage(
          payload: payload,
          isSent: false,
          timestamp: DateTime.now(),
          type: isText ? 'text' : 'binary',
          sizeBytes: isText ? (data as String).length : null,
        ));
      },
      onDone: controller.close,
      onError: (e) => controller.addError(e),
    );

    return controller.stream;
  }

  /// Sends [payload] as a text frame on the active channel.
  void sendMessage(String payload) {
    if (_channel == null) throw StateError('Not connected');
    _channel!.sink.add(payload);
  }

  /// Closes the WebSocket connection gracefully.
  Future<void> disconnect() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
  }
}
