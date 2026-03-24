import 'dart:convert';
import 'dart:typed_data';

/// A single message in a WebSocket session (sent or received).
class WebSocketMessage {
  const WebSocketMessage({
    this.textPayload,
    this.binaryPayload,
    required this.isSent,
    required this.timestamp,
    this.type = 'text',
    this.sizeBytes,
  }) : assert(
         (textPayload != null && binaryPayload == null) ||
             (textPayload == null && binaryPayload != null) ||
             (type == 'error' || type == 'system'),
         'Exactly one payload form should be set for regular messages.',
       );

  /// Raw text payload for text/system/error messages.
  final String? textPayload;

  /// Raw binary payload for binary messages.
  final Uint8List? binaryPayload;

  /// `true` = ↑ sent by client, `false` = ↓ received from server.
  final bool isSent;

  final DateTime timestamp;

  /// 'text' | 'binary'
  final String type;

  /// Byte size of the payload, if known.
  final int? sizeBytes;

  bool get isBinary => type == 'binary';

  /// Backward-compatible payload string view.
  ///
  /// For binary frames this is base64, generated on demand for UI/debug only.
  String get payload {
    if (textPayload != null) return textPayload!;
    if (binaryPayload == null) return '';
    return base64Encode(binaryPayload!);
  }

  WebSocketMessage copyWith({
    String? textPayload,
    Uint8List? binaryPayload,
    bool? isSent,
    DateTime? timestamp,
    String? type,
    int? sizeBytes,
  }) {
    return WebSocketMessage(
      textPayload: textPayload ?? this.textPayload,
      binaryPayload: binaryPayload ?? this.binaryPayload,
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
          other.textPayload == textPayload &&
          _bytesEqual(other.binaryPayload, binaryPayload) &&
          other.isSent == isSent &&
          other.timestamp == timestamp &&
          other.type == type;

  @override
  int get hashCode =>
      Object.hash(textPayload, _bytesHash(binaryPayload), isSent, timestamp, type);

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.lengthInBytes != b.lengthInBytes) {
      return false;
    }
    for (var i = 0; i < a.lengthInBytes; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _bytesHash(Uint8List? bytes) {
    if (bytes == null) return 0;
    var hash = 17;
    for (final b in bytes) {
      hash = 37 * hash + b;
    }
    return hash;
  }
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
