import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:better_networking/better_networking.dart';

class WebSocketTransportDiagnostics {
  const WebSocketTransportDiagnostics({
    required this.secure,
    this.tlsSubject,
    this.tlsIssuer,
    this.tlsSha1,
    this.tlsValidFrom,
    this.tlsValidTo,
    this.negotiatedExtensions = const [],
    this.negotiatedSubprotocol,
    this.totalFrames = 0,
    this.continuationFrames = 0,
    this.fragmentedMessages = 0,
    this.compressedFrames = 0,
    this.textFrames = 0,
    this.binaryFrames = 0,
    this.pingFrames = 0,
    this.pongFrames = 0,
    this.closeFrames = 0,
    this.compressedPayloadBytes = 0,
    this.decompressedPayloadBytes = 0,
  });

  final bool secure;
  final String? tlsSubject;
  final String? tlsIssuer;
  final String? tlsSha1;
  final DateTime? tlsValidFrom;
  final DateTime? tlsValidTo;
  final List<String> negotiatedExtensions;
  final String? negotiatedSubprotocol;
  final int totalFrames;
  final int continuationFrames;
  final int fragmentedMessages;
  final int compressedFrames;
  final int textFrames;
  final int binaryFrames;
  final int pingFrames;
  final int pongFrames;
  final int closeFrames;
  final int compressedPayloadBytes;
  final int decompressedPayloadBytes;

  WebSocketTransportDiagnostics copyWith({
    bool? secure,
    String? tlsSubject,
    String? tlsIssuer,
    String? tlsSha1,
    DateTime? tlsValidFrom,
    DateTime? tlsValidTo,
    List<String>? negotiatedExtensions,
    String? negotiatedSubprotocol,
    int? totalFrames,
    int? continuationFrames,
    int? fragmentedMessages,
    int? compressedFrames,
    int? textFrames,
    int? binaryFrames,
    int? pingFrames,
    int? pongFrames,
    int? closeFrames,
    int? compressedPayloadBytes,
    int? decompressedPayloadBytes,
  }) {
    return WebSocketTransportDiagnostics(
      secure: secure ?? this.secure,
      tlsSubject: tlsSubject ?? this.tlsSubject,
      tlsIssuer: tlsIssuer ?? this.tlsIssuer,
      tlsSha1: tlsSha1 ?? this.tlsSha1,
      tlsValidFrom: tlsValidFrom ?? this.tlsValidFrom,
      tlsValidTo: tlsValidTo ?? this.tlsValidTo,
      negotiatedExtensions: negotiatedExtensions ?? this.negotiatedExtensions,
      negotiatedSubprotocol: negotiatedSubprotocol ?? this.negotiatedSubprotocol,
      totalFrames: totalFrames ?? this.totalFrames,
      continuationFrames: continuationFrames ?? this.continuationFrames,
      fragmentedMessages: fragmentedMessages ?? this.fragmentedMessages,
      compressedFrames: compressedFrames ?? this.compressedFrames,
      textFrames: textFrames ?? this.textFrames,
      binaryFrames: binaryFrames ?? this.binaryFrames,
      pingFrames: pingFrames ?? this.pingFrames,
      pongFrames: pongFrames ?? this.pongFrames,
      closeFrames: closeFrames ?? this.closeFrames,
      compressedPayloadBytes: compressedPayloadBytes ?? this.compressedPayloadBytes,
      decompressedPayloadBytes:
          decompressedPayloadBytes ?? this.decompressedPayloadBytes,
    );
  }
}

/// Manages a single WebSocket connection lifecycle.
class WebSocketService {
  Socket? _socket;
  StreamSubscription? _subscription;
  StreamController<WebSocketMessage>? _controller;
  final _rxBuffer = BytesBuilder(copy: false);
  WebSocketTransportDiagnostics _diag =
      const WebSocketTransportDiagnostics(secure: false);

  Uint8List? _fragmentBuffer;
  int? _fragmentOpcode;
  bool _fragmentCompressed = false;

  static const _wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  bool get isConnected => _socket != null;

  /// Opens a WebSocket connection to [url] with optional [headers].
  Stream<WebSocketMessage> connect(
    String url, {
    Map<String, String> headers = const {},
    List<String> protocols = const [],
    int? maxFrameBytes,
    bool truncateFrames = true,
    void Function(WebSocketTransportDiagnostics diagnostics)? onDiagnostics,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw ArgumentError('Invalid WebSocket URL: $url');
    }

    _controller = StreamController<WebSocketMessage>.broadcast(
      onCancel: disconnect,
    );

    unawaited(_connectInternal(
      uri,
      headers: headers,
      protocols: protocols,
      maxFrameBytes: maxFrameBytes,
      truncateFrames: truncateFrames,
      onDiagnostics: onDiagnostics,
    ));

    return _controller!.stream;
  }

  Future<void> _connectInternal(
    Uri uri, {
    required Map<String, String> headers,
    required List<String> protocols,
    required int? maxFrameBytes,
    required bool truncateFrames,
    void Function(WebSocketTransportDiagnostics diagnostics)? onDiagnostics,
  }) async {
    try {
      final secure = uri.scheme.toLowerCase() == 'wss';
      final host = uri.host;
      final port = uri.hasPort
          ? uri.port
          : (secure ? 443 : 80);

      final socket = secure
          ? await SecureSocket.connect(host, port)
          : await Socket.connect(host, port);
      _socket = socket;

      if (socket is SecureSocket) {
        final cert = socket.peerCertificate;
        _diag = _diag.copyWith(
          secure: true,
          tlsSubject: cert?.subject,
          tlsIssuer: cert?.issuer,
          tlsSha1: cert?.sha1 == null
              ? null
              : cert!.sha1
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(':'),
          tlsValidFrom: cert?.startValidity,
          tlsValidTo: cert?.endValidity,
        );
      } else {
        _diag = _diag.copyWith(secure: false);
      }

      final keyBytes = Uint8List(16);
      final rnd = Random.secure();
      for (var i = 0; i < keyBytes.length; i++) {
        keyBytes[i] = rnd.nextInt(256);
      }
      final wsKey = base64Encode(keyBytes);

      final reqPath = uri.path.isEmpty ? '/' : uri.path;
      final reqQuery = uri.hasQuery ? '?${uri.query}' : '';
      final headerLines = <String>[
        'GET $reqPath$reqQuery HTTP/1.1',
        'Host: ${uri.host}${uri.hasPort ? ':${uri.port}' : ''}',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: $wsKey',
        'Sec-WebSocket-Version: 13',
        if (protocols.isNotEmpty) 'Sec-WebSocket-Protocol: ${protocols.join(', ')}',
        ...headers.entries.map((e) => '${e.key}: ${e.value}'),
        '',
        '',
      ];
      socket.add(utf8.encode(headerLines.join('\r\n')));
      await socket.flush();

      final handshakeBuffer = BytesBuilder(copy: false);
      var handshakeDone = false;

      _subscription = socket.listen(
        (chunk) {
          if (!handshakeDone) {
            handshakeBuffer.add(chunk);
            final data = handshakeBuffer.toBytes();
            final end = _findHeaderEnd(data);
            if (end == -1) {
              return;
            }

            final headerText = ascii.decode(
              Uint8List.sublistView(data, 0, end),
            );
            final parsed = _parseHandshake(headerText);
            if (parsed.statusCode != 101) {
              _controller?.addError(
                StateError('WebSocket handshake failed: ${parsed.statusLine}'),
              );
              unawaited(disconnect());
              return;
            }

            final expectedAccept =
                base64Encode(sha1.convert(utf8.encode('$wsKey$_wsGuid')).bytes);
            final actualAccept = parsed.headers['sec-websocket-accept'];
            if (actualAccept != expectedAccept) {
              _controller?.addError(
                StateError('Invalid Sec-WebSocket-Accept from server'),
              );
              unawaited(disconnect());
              return;
            }

            final extHeader = parsed.headers['sec-websocket-extensions'] ?? '';
            final extensions = extHeader
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList(growable: false);

            _diag = _diag.copyWith(
              negotiatedExtensions: extensions,
              negotiatedSubprotocol: parsed.headers['sec-websocket-protocol'],
            );
            onDiagnostics?.call(_diag);

            handshakeDone = true;
            final leftover = end < data.length
                ? Uint8List.sublistView(data, end)
                : Uint8List(0);
            if (leftover.isNotEmpty) {
              _rxBuffer.add(leftover);
              _drainFrames(
                maxFrameBytes: maxFrameBytes,
                truncateFrames: truncateFrames,
                onDiagnostics: onDiagnostics,
              );
            }
            return;
          }

          _rxBuffer.add(chunk);
          _drainFrames(
            maxFrameBytes: maxFrameBytes,
            truncateFrames: truncateFrames,
            onDiagnostics: onDiagnostics,
          );
        },
        onDone: () {
          _controller?.close();
        },
        onError: (e) {
          _controller?.addError(e);
        },
      );
    } catch (e, st) {
      _controller?.addError(e, st);
      await disconnect();
    }
  }

  int _findHeaderEnd(Uint8List bytes) {
    for (var i = 0; i <= bytes.length - 4; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }

  _Handshake _parseHandshake(String raw) {
    final lines = raw.split('\r\n');
    final statusLine = lines.firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final parts = statusLine.split(' ');
    final statusCode = parts.length > 1 ? int.tryParse(parts[1]) ?? -1 : -1;
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim().toLowerCase();
      final v = line.substring(idx + 1).trim();
      headers[k] = v;
    }
    return _Handshake(statusLine, statusCode, headers);
  }

  void _drainFrames({
    required int? maxFrameBytes,
    required bool truncateFrames,
    void Function(WebSocketTransportDiagnostics diagnostics)? onDiagnostics,
  }) {
    var bytes = _rxBuffer.toBytes();
    _rxBuffer.clear();
    var offset = 0;
    while (true) {
      if (bytes.length - offset < 2) break;
      final b0 = bytes[offset];
      final b1 = bytes[offset + 1];
      final fin = (b0 & 0x80) != 0;
      final rsv1 = (b0 & 0x40) != 0;
      final opcode = b0 & 0x0f;
      final masked = (b1 & 0x80) != 0;
      var length = b1 & 0x7f;
      var cursor = offset + 2;

      if (length == 126) {
        if (bytes.length - cursor < 2) break;
        length = ByteData.sublistView(bytes, cursor, cursor + 2)
            .getUint16(0, Endian.big);
        cursor += 2;
      } else if (length == 127) {
        if (bytes.length - cursor < 8) break;
        final longLen = ByteData.sublistView(bytes, cursor, cursor + 8)
            .getUint64(0, Endian.big);
        if (longLen > 0x7fffffff) {
          throw const FormatException('Frame payload too large');
        }
        length = longLen.toInt();
        cursor += 8;
      }

      Uint8List? maskKey;
      if (masked) {
        if (bytes.length - cursor < 4) break;
        maskKey = Uint8List.sublistView(bytes, cursor, cursor + 4);
        cursor += 4;
      }

      if (bytes.length - cursor < length) break;
      var payload = Uint8List.sublistView(bytes, cursor, cursor + length);
      if (masked && maskKey != null) {
        final unmasked = Uint8List(payload.lengthInBytes);
        for (var i = 0; i < payload.lengthInBytes; i++) {
          unmasked[i] = payload[i] ^ maskKey[i % 4];
        }
        payload = unmasked;
      }

      _diag = _diag.copyWith(
        totalFrames: _diag.totalFrames + 1,
        continuationFrames:
            _diag.continuationFrames + (opcode == 0x0 ? 1 : 0),
        compressedFrames: _diag.compressedFrames + (rsv1 ? 1 : 0),
        textFrames: _diag.textFrames + (opcode == 0x1 ? 1 : 0),
        binaryFrames: _diag.binaryFrames + (opcode == 0x2 ? 1 : 0),
        pingFrames: _diag.pingFrames + (opcode == 0x9 ? 1 : 0),
        pongFrames: _diag.pongFrames + (opcode == 0xA ? 1 : 0),
        closeFrames: _diag.closeFrames + (opcode == 0x8 ? 1 : 0),
        compressedPayloadBytes:
            _diag.compressedPayloadBytes + (rsv1 ? payload.lengthInBytes : 0),
      );

      if (opcode == 0x8) {
        unawaited(_sendFrame(0x8, payload));
        unawaited(disconnect());
      } else if (opcode == 0x9) {
        // Reply to ping with pong.
        unawaited(_sendFrame(0xA, payload));
      } else if (opcode == 0xA) {
        _controller?.add(
          WebSocketMessage(
            textPayload: 'pong',
            isSent: false,
            timestamp: DateTime.now(),
            type: 'text',
            sizeBytes: payload.lengthInBytes,
          ),
        );
      } else if (opcode == 0x1 || opcode == 0x2 || opcode == 0x0) {
        _consumeDataFrame(
          fin: fin,
          opcode: opcode,
          compressed: rsv1,
          payload: payload,
          maxFrameBytes: maxFrameBytes,
          truncateFrames: truncateFrames,
        );
      }

      offset = cursor + length;
      onDiagnostics?.call(_diag);
    }

    if (offset < bytes.length) {
      _rxBuffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  void _consumeDataFrame({
    required bool fin,
    required int opcode,
    required bool compressed,
    required Uint8List payload,
    required int? maxFrameBytes,
    required bool truncateFrames,
  }) {
    if (opcode == 0x0) {
      if (_fragmentBuffer == null || _fragmentOpcode == null) {
        return;
      }
      _fragmentBuffer = Uint8List.fromList([..._fragmentBuffer!, ...payload]);
      if (!fin) {
        return;
      }
      final merged = _fragmentBuffer!;
      final messageOpcode = _fragmentOpcode!;
      final messageCompressed = _fragmentCompressed;
      _fragmentBuffer = null;
      _fragmentOpcode = null;
      _fragmentCompressed = false;
      _emitMessage(
        messageOpcode,
        merged,
        compressed: messageCompressed,
        maxFrameBytes: maxFrameBytes,
        truncateFrames: truncateFrames,
      );
      return;
    }

    if (!fin) {
      _diag = _diag.copyWith(fragmentedMessages: _diag.fragmentedMessages + 1);
      _fragmentOpcode = opcode;
      _fragmentCompressed = compressed;
      _fragmentBuffer = Uint8List.fromList(payload);
      return;
    }

    _emitMessage(
      opcode,
      payload,
      compressed: compressed,
      maxFrameBytes: maxFrameBytes,
      truncateFrames: truncateFrames,
    );
  }

  void _emitMessage(
    int opcode,
    Uint8List payload, {
    required bool compressed,
    required int? maxFrameBytes,
    required bool truncateFrames,
  }) {
    var effectivePayload = payload;
    if (compressed &&
        _diag.negotiatedExtensions
            .join(',')
            .toLowerCase()
            .contains('permessage-deflate')) {
      // Per-message deflate payload requires RFC tail for inflateRaw.
      final withTail = Uint8List.fromList([...payload, 0x00, 0x00, 0xff, 0xff]);
      try {
        effectivePayload = Uint8List.fromList(
          ZLibCodec(raw: true).decode(withTail),
        );
        _diag = _diag.copyWith(
          decompressedPayloadBytes:
              _diag.decompressedPayloadBytes + effectivePayload.lengthInBytes,
        );
      } catch (_) {
        // If decompression fails, keep raw payload and continue.
      }
    }

    final isText = opcode == 0x1;
    final sizeBytes = effectivePayload.lengthInBytes;
    final shouldTruncate =
        truncateFrames && maxFrameBytes != null && sizeBytes > maxFrameBytes;
    final cut = shouldTruncate ? maxFrameBytes! : sizeBytes;
    final truncated = Uint8List.sublistView(effectivePayload, 0, cut);

    _controller?.add(
      WebSocketMessage(
        textPayload: isText ? utf8.decode(truncated, allowMalformed: true) : null,
        binaryPayload: isText ? null : truncated,
        isSent: false,
        timestamp: DateTime.now(),
        type: isText ? 'text' : 'binary',
        sizeBytes: cut,
        isTruncated: shouldTruncate,
        originalSizeBytes: shouldTruncate ? sizeBytes : null,
      ),
    );
  }

  Future<void> _sendFrame(int opcode, Uint8List payload) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Not connected');
    }

    final finOpcode = 0x80 | (opcode & 0x0f);
    final maskBit = 0x80;
    final builder = BytesBuilder(copy: false);
    builder.addByte(finOpcode);

    if (payload.lengthInBytes < 126) {
      builder.addByte(maskBit | payload.lengthInBytes);
    } else if (payload.lengthInBytes <= 0xffff) {
      builder.addByte(maskBit | 126);
      final lenBytes = ByteData(2)..setUint16(0, payload.lengthInBytes, Endian.big);
      builder.add(lenBytes.buffer.asUint8List());
    } else {
      builder.addByte(maskBit | 127);
      final lenBytes = ByteData(8)..setUint64(0, payload.lengthInBytes, Endian.big);
      builder.add(lenBytes.buffer.asUint8List());
    }

    final mask = Uint8List(4);
    final rnd = Random.secure();
    for (var i = 0; i < 4; i++) {
      mask[i] = rnd.nextInt(256);
    }
    builder.add(mask);

    final masked = Uint8List(payload.lengthInBytes);
    for (var i = 0; i < payload.lengthInBytes; i++) {
      masked[i] = payload[i] ^ mask[i % 4];
    }
    builder.add(masked);

    socket.add(builder.toBytes());
    await socket.flush();
  }

  /// Sends [payload] as a text frame on the active channel.
  void sendMessage(String payload) {
    unawaited(_sendFrame(0x1, Uint8List.fromList(utf8.encode(payload))));
  }

  /// Sends [bytes] as a binary frame on the active channel.
  void sendBinaryMessage(Uint8List bytes) {
    unawaited(_sendFrame(0x2, bytes));
  }

  /// Closes the WebSocket connection gracefully.
  Future<void> disconnect() async {
    await _subscription?.cancel();
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}

class _Handshake {
  _Handshake(this.statusLine, this.statusCode, this.headers);

  final String statusLine;
  final int statusCode;
  final Map<String, String> headers;
}
