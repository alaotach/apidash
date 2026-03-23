/// A single message in a WebSocket session (sent or received).
class WebSocketMessage {
  const WebSocketMessage({
    required this.payload,
    required this.isSent,
    required this.timestamp,
    this.type = 'text',
    this.sizeBytes,
  });

  /// Raw payload (text or base64 for binary).
  final String payload;

  /// `true` = ↑ sent by client, `false` = ↓ received from server.
  final bool isSent;

  final DateTime timestamp;

  /// 'text' | 'binary'
  final String type;

  /// Byte size of the payload, if known.
  final int? sizeBytes;

  WebSocketMessage copyWith({
    String? payload,
    bool? isSent,
    DateTime? timestamp,
    String? type,
    int? sizeBytes,
  }) {
    return WebSocketMessage(
      payload: payload ?? this.payload,
      isSent: isSent ?? this.isSent,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      sizeBytes: sizeBytes ?? this.sizeBytes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebSocketMessage &&
          other.payload == payload &&
          other.isSent == isSent &&
          other.timestamp == timestamp &&
          other.type == type;

  @override
  int get hashCode =>
      Object.hash(payload, isSent, timestamp, type);
}

/// Model representing the configuration and session history for a WebSocket
/// request in API Dash.
class WebSocketRequestModel {
  const WebSocketRequestModel({
    this.url = '',
    this.headers = const {},
    this.messageHistory = const [],
    this.connectionDurationMs,
  });

  /// Endpoint URL, e.g. `ws://echo.websocket.org` or `wss://...`.
  final String url;

  /// Custom headers sent during the upgrade handshake.
  final Map<String, String> headers;

  /// Chronological log of all sent/received messages in this session.
  final List<WebSocketMessage> messageHistory;

  /// Total connection duration in milliseconds, populated on disconnect.
  final int? connectionDurationMs;

  WebSocketRequestModel copyWith({
    String? url,
    Map<String, String>? headers,
    List<WebSocketMessage>? messageHistory,
    int? connectionDurationMs,
  }) {
    return WebSocketRequestModel(
      url: url ?? this.url,
      headers: headers ?? this.headers,
      messageHistory: messageHistory ?? this.messageHistory,
      connectionDurationMs: connectionDurationMs ?? this.connectionDurationMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebSocketRequestModel &&
          other.url == url &&
          other.headers == headers;

  @override
  int get hashCode => Object.hash(url, headers);
}
