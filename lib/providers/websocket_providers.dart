import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_riverpod/legacy.dart';
import 'package:better_networking/better_networking.dart';
import '../services/websocket_service.dart';

enum WebSocketConnectionState { disconnected, connecting, connected }

enum WebSocketReconnectPolicy { off, immediate, exponential, exponentialJitter }

class WebSocketConnectionOptions {
  const WebSocketConnectionOptions({
    this.headers = const {},
    this.subprotocols = const [],
    this.origin,
    this.maxFrameBytes,
    this.truncateFrames = true,
    this.reconnectPolicy = WebSocketReconnectPolicy.off,
    this.maxReconnectAttempts = 8,
    this.keepAliveIntervalSec = 0,
  });

  final Map<String, String> headers;
  final List<String> subprotocols;
  final String? origin;
  final int? maxFrameBytes;
  final bool truncateFrames;
  final WebSocketReconnectPolicy reconnectPolicy;
  final int maxReconnectAttempts;
  final int keepAliveIntervalSec;

  WebSocketConnectionOptions copyWith({
    Map<String, String>? headers,
    List<String>? subprotocols,
    String? origin,
    int? maxFrameBytes,
    bool? truncateFrames,
    WebSocketReconnectPolicy? reconnectPolicy,
    int? maxReconnectAttempts,
    int? keepAliveIntervalSec,
  }) {
    return WebSocketConnectionOptions(
      headers: headers ?? this.headers,
      subprotocols: subprotocols ?? this.subprotocols,
      origin: origin ?? this.origin,
      maxFrameBytes: maxFrameBytes ?? this.maxFrameBytes,
      truncateFrames: truncateFrames ?? this.truncateFrames,
      reconnectPolicy: reconnectPolicy ?? this.reconnectPolicy,
      maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
      keepAliveIntervalSec: keepAliveIntervalSec ?? this.keepAliveIntervalSec,
    );
  }
}

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
    this.compressionEnabled,
    this.lastPongRttMs,
    this.reconnectAttempts = 0,
    this.reconnectScheduledInMs,
    this.droppedFrames = 0,
    this.outOfOrderFrames = 0,
    this.sequenceGapEvents = 0,
    this.queueDepth = 0,
    this.rollingMessagesPerSec,
    this.rollingBytesPerSec,
    this.tlsSubject,
    this.tlsIssuer,
    this.tlsSha1,
    this.tlsValidFrom,
    this.tlsValidTo,
    this.frameCount = 0,
    this.continuationFrameCount = 0,
    this.fragmentedMessageCount = 0,
    this.compressedFrameCount = 0,
    this.pingFrameCount = 0,
    this.pongFrameCount = 0,
    this.closeFrameCount = 0,
    this.compressedPayloadBytes = 0,
    this.decompressedPayloadBytes = 0,
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
  final bool? compressionEnabled;
  final int? lastPongRttMs;
  final int reconnectAttempts;
  final int? reconnectScheduledInMs;
  final int droppedFrames;
  final int outOfOrderFrames;
  final int sequenceGapEvents;
  final int queueDepth;
  final double? rollingMessagesPerSec;
  final double? rollingBytesPerSec;
  final String? tlsSubject;
  final String? tlsIssuer;
  final String? tlsSha1;
  final DateTime? tlsValidFrom;
  final DateTime? tlsValidTo;
  final int frameCount;
  final int continuationFrameCount;
  final int fragmentedMessageCount;
  final int compressedFrameCount;
  final int pingFrameCount;
  final int pongFrameCount;
  final int closeFrameCount;
  final int compressedPayloadBytes;
  final int decompressedPayloadBytes;

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
    bool? compressionEnabled,
    int? lastPongRttMs,
    int? reconnectAttempts,
    int? reconnectScheduledInMs,
    int? droppedFrames,
    int? outOfOrderFrames,
    int? sequenceGapEvents,
    int? queueDepth,
    double? rollingMessagesPerSec,
    double? rollingBytesPerSec,
    String? tlsSubject,
    String? tlsIssuer,
    String? tlsSha1,
    DateTime? tlsValidFrom,
    DateTime? tlsValidTo,
    int? frameCount,
    int? continuationFrameCount,
    int? fragmentedMessageCount,
    int? compressedFrameCount,
    int? pingFrameCount,
    int? pongFrameCount,
    int? closeFrameCount,
    int? compressedPayloadBytes,
    int? decompressedPayloadBytes,
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
      compressionEnabled: compressionEnabled ?? this.compressionEnabled,
      lastPongRttMs: lastPongRttMs ?? this.lastPongRttMs,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      reconnectScheduledInMs:
          reconnectScheduledInMs ?? this.reconnectScheduledInMs,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      outOfOrderFrames: outOfOrderFrames ?? this.outOfOrderFrames,
      sequenceGapEvents: sequenceGapEvents ?? this.sequenceGapEvents,
      queueDepth: queueDepth ?? this.queueDepth,
      rollingMessagesPerSec:
          rollingMessagesPerSec ?? this.rollingMessagesPerSec,
      rollingBytesPerSec: rollingBytesPerSec ?? this.rollingBytesPerSec,
        tlsSubject: tlsSubject ?? this.tlsSubject,
        tlsIssuer: tlsIssuer ?? this.tlsIssuer,
        tlsSha1: tlsSha1 ?? this.tlsSha1,
        tlsValidFrom: tlsValidFrom ?? this.tlsValidFrom,
        tlsValidTo: tlsValidTo ?? this.tlsValidTo,
        frameCount: frameCount ?? this.frameCount,
        continuationFrameCount:
          continuationFrameCount ?? this.continuationFrameCount,
        fragmentedMessageCount:
          fragmentedMessageCount ?? this.fragmentedMessageCount,
        compressedFrameCount: compressedFrameCount ?? this.compressedFrameCount,
        pingFrameCount: pingFrameCount ?? this.pingFrameCount,
        pongFrameCount: pongFrameCount ?? this.pongFrameCount,
        closeFrameCount: closeFrameCount ?? this.closeFrameCount,
        compressedPayloadBytes:
          compressedPayloadBytes ?? this.compressedPayloadBytes,
        decompressedPayloadBytes:
          decompressedPayloadBytes ?? this.decompressedPayloadBytes,
    );
  }
}

class WebSocketNotifier extends StateNotifier<WebSocketSessionState> {
  WebSocketNotifier() : super(const WebSocketSessionState());

  final _service = WebSocketService();
  StreamSubscription<WebSocketMessage>? _sub;
  Timer? _reconnectTimer;
  Timer? _keepAliveTimer;
  DateTime? _lastPingSentAt;
  String? _lastConnectedUrl;
  WebSocketConnectionOptions _lastOptions = const WebSocketConnectionOptions();
  final _random = Random();
  int _expectedSequence = -1;
  String _sequenceStreamKey = '';

  Future<void> connect(
    String url, {
    WebSocketConnectionOptions options = const WebSocketConnectionOptions(),
  }) async {
    final stopwatch = Stopwatch()..start();
    _reconnectTimer?.cancel();
    _lastConnectedUrl = url;
    _lastOptions = options;

    final headers = {
      ...options.headers,
      if (options.origin != null && options.origin!.isNotEmpty)
        'origin': options.origin!,
    };
    final requestedExtensionsHeader = headers.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'sec-websocket-extensions',
          orElse: () => const MapEntry('', ''),
        )
        .value;
    final requestedExtensions = requestedExtensionsHeader
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final compressionRequested = requestedExtensions
        .any((e) => e.toLowerCase().contains('permessage-deflate'));

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
      final stream = _service.connect(
        url,
        headers: headers,
        protocols: options.subprotocols,
        maxFrameBytes: options.maxFrameBytes,
        truncateFrames: options.truncateFrames,
        onDiagnostics: (diag) {
          state = state.copyWith(
            negotiatedExtensions: diag.negotiatedExtensions,
            negotiatedSubprotocol:
                diag.negotiatedSubprotocol ?? state.negotiatedSubprotocol,
            compressionEnabled: diag.compressedFrames > 0 ||
                diag.negotiatedExtensions
                    .join(',')
                    .toLowerCase()
                    .contains('permessage-deflate'),
            tlsSubject: diag.tlsSubject,
            tlsIssuer: diag.tlsIssuer,
            tlsSha1: diag.tlsSha1,
            tlsValidFrom: diag.tlsValidFrom,
            tlsValidTo: diag.tlsValidTo,
            frameCount: diag.totalFrames,
            continuationFrameCount: diag.continuationFrames,
            fragmentedMessageCount: diag.fragmentedMessages,
            compressedFrameCount: diag.compressedFrames,
            pingFrameCount: diag.pingFrames,
            pongFrameCount: diag.pongFrames,
            closeFrameCount: diag.closeFrames,
            compressedPayloadBytes: diag.compressedPayloadBytes,
            decompressedPayloadBytes: diag.decompressedPayloadBytes,
          );
        },
      );
      stopwatch.stop();
      state = state.copyWith(
        connectionState: WebSocketConnectionState.connected,
        connectedAt: DateTime.now(),
        connectedUrl: url,
        requestHeaders: headers,
        connectLatencyMs: stopwatch.elapsedMilliseconds,
        handshakeRequestLine: _buildRequestLine(url),
        handshakeResponseLine: '101 Switching Protocols',
        negotiatedSubprotocol:
            options.subprotocols.isEmpty ? null : options.subprotocols.first,
        negotiatedExtensions: requestedExtensions,
        compressionEnabled: compressionRequested,
        reconnectAttempts: 0,
        reconnectScheduledInMs: null,
      );
      _appendSystemMessage('Connected to $url');
      _configureKeepAlive(options.keepAliveIntervalSec);
      _sub = stream.listen(
        (msg) {
          final droppedFrames = state.droppedFrames + (msg.isTruncated ? 1 : 0);
          final (outOfOrderFrames, sequenceGapEvents) = _updateSequenceStats(msg);
          final rolling = _rollingRatesWith(msg);
          state = state.copyWith(
            messages: [...state.messages, msg],
            droppedFrames: droppedFrames,
            outOfOrderFrames: outOfOrderFrames,
            sequenceGapEvents: sequenceGapEvents,
            rollingMessagesPerSec: rolling.$1,
            rollingBytesPerSec: rolling.$2,
          );

          _updatePongRttIfPresent(msg);
        },
        onDone: () {
          _keepAliveTimer?.cancel();
          _appendSystemMessage('Connection closed by remote host.');
          state = state.copyWith(
            connectionState: WebSocketConnectionState.disconnected,
          );
          _scheduleReconnectIfNeeded();
        },
        onError: (e) {
          _keepAliveTimer?.cancel();
          _appendErrorMessage(e.toString());
          state = state.copyWith(
            connectionState: WebSocketConnectionState.disconnected,
            error: e.toString(),
          );
          _scheduleReconnectIfNeeded();
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
      _scheduleReconnectIfNeeded();
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
      if (payload == '__ping__') {
        _lastPingSentAt = DateTime.now();
      }
    } catch (e) {
      _appendErrorMessage(e.toString());
      state = state.copyWith(error: e.toString());
    }
  }

  void ping() {
    if (!state.isConnected) return;
    _lastPingSentAt = DateTime.now();
    sendText('__ping__');
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
    _reconnectTimer?.cancel();
    _keepAliveTimer?.cancel();
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
    _keepAliveTimer?.cancel();
    _appendErrorMessage('Simulated network drop.');
    state = state.copyWith(
      connectionState: WebSocketConnectionState.disconnected,
      error: 'Simulated network drop',
    );
    _scheduleReconnectIfNeeded();
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
    _reconnectTimer?.cancel();
    _keepAliveTimer?.cancel();
    _sub?.cancel();
    _service.disconnect();
    super.dispose();
  }

  void _updatePongRttIfPresent(WebSocketMessage msg) {
    final text = msg.textPayload?.trim().toLowerCase();
    if (text == null) return;
    final looksLikePong = text == 'pong' || text.contains('"pong"');
    if (!looksLikePong || _lastPingSentAt == null) return;
    final rtt = DateTime.now().difference(_lastPingSentAt!).inMilliseconds;
    state = state.copyWith(lastPongRttMs: rtt);
  }

  (double, double) _rollingRatesWith(WebSocketMessage next) {
    final now = DateTime.now();
    const window = Duration(seconds: 10);
    final recent = [
      ...state.messages,
      next,
    ].where((m) => now.difference(m.timestamp) <= window).toList(growable: false);
    if (recent.isEmpty) {
      return (0, 0);
    }
    final msgPerSec = recent.length / window.inSeconds;
    final bytes = recent.fold<int>(
      0,
      (sum, m) => sum +
          (m.originalSizeBytes ??
              m.sizeBytes ??
              m.binaryPayload?.lengthInBytes ??
              (m.textPayload ?? '').length),
    );
    final bytesPerSec = bytes / window.inSeconds;
    return (msgPerSec, bytesPerSec);
  }

  (int, int) _updateSequenceStats(WebSocketMessage msg) {
    var outOfOrder = state.outOfOrderFrames;
    var gaps = state.sequenceGapEvents;
    if (msg.type != 'binary') {
      return (outOfOrder, gaps);
    }
    final text = msg.textPayload ?? '';
    final seq = _extractSequence(text);
    final stream = _extractStream(text);
    if (seq == null) {
      return (outOfOrder, gaps);
    }
    if (_sequenceStreamKey != stream) {
      _sequenceStreamKey = stream;
      _expectedSequence = seq + 1;
      return (outOfOrder, gaps);
    }
    if (_expectedSequence != -1 && seq > _expectedSequence) {
      gaps += 1;
      _expectedSequence = seq + 1;
      return (outOfOrder, gaps);
    }
    if (_expectedSequence != -1 && seq < _expectedSequence) {
      outOfOrder += 1;
      return (outOfOrder, gaps);
    }
    _expectedSequence = seq + 1;
    return (outOfOrder, gaps);
  }

  int? _extractSequence(String text) {
    final m = RegExp(r'"(?:sequence|seq)"\s*:\s*(\d+)').firstMatch(text);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String _extractStream(String text) {
    final m = RegExp(r'"(?:symbol|stream|channel)"\s*:\s*"([^"]+)"')
        .firstMatch(text);
    return m?.group(1) ?? '';
  }

  void _scheduleReconnectIfNeeded() {
    final options = _lastOptions;
    final url = _lastConnectedUrl;
    if (url == null || options.reconnectPolicy == WebSocketReconnectPolicy.off) {
      return;
    }

    final nextAttempt = state.reconnectAttempts + 1;
    if (nextAttempt > options.maxReconnectAttempts) {
      _appendSystemMessage('Reconnect stopped: max attempts reached.');
      return;
    }

    final delayMs = switch (options.reconnectPolicy) {
      WebSocketReconnectPolicy.off => 0,
      WebSocketReconnectPolicy.immediate => 0,
      WebSocketReconnectPolicy.exponential => min(30000, 500 * (1 << (nextAttempt - 1))),
      WebSocketReconnectPolicy.exponentialJitter =>
        min(30000, 500 * (1 << (nextAttempt - 1))) + _random.nextInt(300),
    };

    state = state.copyWith(
      reconnectAttempts: nextAttempt,
      reconnectScheduledInMs: delayMs,
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      connect(url, options: options);
    });
  }

  void _configureKeepAlive(int intervalSec) {
    _keepAliveTimer?.cancel();
    if (intervalSec <= 0) return;
    _keepAliveTimer = Timer.periodic(Duration(seconds: intervalSec), (_) {
      if (!state.isConnected) return;
      ping();
    });
  }
}

final webSocketNotifierProvider =
    StateNotifierProvider.autoDispose<WebSocketNotifier, WebSocketSessionState>(
  (ref) => WebSocketNotifier(),
);

class WebSocketConnectionDraft {
  const WebSocketConnectionDraft({
    this.subprotocolsCsv = '',
    this.origin = '',
    this.maxFrameBytes = '',
    this.maxReconnectAttempts = '8',
    this.keepAliveIntervalSec = '0',
    this.headersJson = '{}',
    this.truncateFrames = true,
    this.reconnectPolicy = WebSocketReconnectPolicy.off,
  });

  final String subprotocolsCsv;
  final String origin;
  final String maxFrameBytes;
  final String maxReconnectAttempts;
  final String keepAliveIntervalSec;
  final String headersJson;
  final bool truncateFrames;
  final WebSocketReconnectPolicy reconnectPolicy;

  WebSocketConnectionDraft copyWith({
    String? subprotocolsCsv,
    String? origin,
    String? maxFrameBytes,
    String? maxReconnectAttempts,
    String? keepAliveIntervalSec,
    String? headersJson,
    bool? truncateFrames,
    WebSocketReconnectPolicy? reconnectPolicy,
  }) {
    return WebSocketConnectionDraft(
      subprotocolsCsv: subprotocolsCsv ?? this.subprotocolsCsv,
      origin: origin ?? this.origin,
      maxFrameBytes: maxFrameBytes ?? this.maxFrameBytes,
      maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
      keepAliveIntervalSec: keepAliveIntervalSec ?? this.keepAliveIntervalSec,
      headersJson: headersJson ?? this.headersJson,
      truncateFrames: truncateFrames ?? this.truncateFrames,
      reconnectPolicy: reconnectPolicy ?? this.reconnectPolicy,
    );
  }
}

class WebSocketConnectionDraftsNotifier
    extends StateNotifier<Map<String, WebSocketConnectionDraft>> {
  WebSocketConnectionDraftsNotifier() : super(const {});

  WebSocketConnectionDraft forRequest(String requestId) {
    return state[requestId] ?? const WebSocketConnectionDraft();
  }

  void updateDraft(String requestId, WebSocketConnectionDraft draft) {
    state = {
      ...state,
      requestId: draft,
    };
  }

  void clearDraft(String requestId) {
    final next = {...state};
    next.remove(requestId);
    state = next;
  }
}

final webSocketConnectionDraftsProvider = StateNotifierProvider<
    WebSocketConnectionDraftsNotifier, Map<String, WebSocketConnectionDraft>>(
  (ref) => WebSocketConnectionDraftsNotifier(),
);
