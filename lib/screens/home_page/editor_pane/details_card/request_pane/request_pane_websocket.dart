import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/providers/providers.dart';
import 'package:apidash/providers/websocket_providers.dart';

enum _WsPaneTab { messages, headers, connection }

enum _WsFilter { all, sent, received, errors }

enum _WsPayloadView { raw, pretty, json, hex }

enum _WsSendMode { text, json, binaryBase64 }

class EditWebSocketRequestPane extends ConsumerStatefulWidget {
  const EditWebSocketRequestPane({super.key});

  @override
  ConsumerState<EditWebSocketRequestPane> createState() =>
      _EditWebSocketRequestPaneState();
}

class _EditWebSocketRequestPaneState
    extends ConsumerState<EditWebSocketRequestPane> {
  final _urlController = TextEditingController();
  final _msgController = TextEditingController();
  final _searchController = TextEditingController();
  final _msgFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final List<Timer> _scheduledSendTimers = [];
  bool _autoScroll = true;
  bool _sendOnEnter = true;
  _WsPaneTab _activeTab = _WsPaneTab.messages;
  _WsFilter _activeFilter = _WsFilter.all;
  _WsPayloadView _payloadView = _WsPayloadView.pretty;
  _WsSendMode _sendMode = _WsSendMode.text;
  bool _collapseSimilar = false;
  bool _groupByType = false;
  int _delaySendMs = 0;
  int _throttleMs = 0;
  DateTime _nextSendAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _jsonInputError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final requestModel = ref.read(selectedRequestModelProvider);
      final url = requestModel?.httpRequestModel?.url;
      if (url != null && url.isNotEmpty) {
        _urlController.text = url;
      }
    });
  }

  @override
  void dispose() {
    for (final timer in _scheduledSendTimers) {
      timer.cancel();
    }
    _urlController.dispose();
    _msgController.dispose();
    _searchController.dispose();
    _msgFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSocketNotifierProvider);
    final notifier = ref.read(webSocketNotifierProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final filteredMessages = _filteredMessages(session.messages);
    final timelineEntries = _timelineEntries(filteredMessages);

    ref.listen(selectedIdStateProvider, (previous, next) {
      if (previous != next) {
        final requestModel = ref.read(selectedRequestModelProvider);
        final url = requestModel?.httpRequestModel?.url;
        _urlController.text = (url != null && url.isNotEmpty) ? url : '';
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScroll && _activeTab == _WsPaneTab.messages && _scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── URL bar + Connect button ─────────────────────────────
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  enabled: !session.isConnected,
                  onChanged: (v) {
                    ref.read(collectionStateNotifierProvider.notifier).update(url: v);
                  },
                  decoration: InputDecoration(
                    labelText: 'WebSocket URL',
                    hintText: 'wss://echo.websocket.org',
                    prefixIcon: const Icon(Icons.cable_rounded),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ConnectButton(
                state: session.connectionState,
                onConnect: () => _connect(notifier),
                onDisconnect: notifier.disconnect,
              ),
            ],
          ),
        ),

        // ── Error banner ─────────────────────────────────────────
        if (session.error != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              session.error!,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),

        // ── Stats strip ─────────────────────────────────────────
        _StatsStrip(session: session),

        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SegmentedButton<_WsPaneTab>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _WsPaneTab.messages, label: Text('Messages')),
              ButtonSegment(value: _WsPaneTab.headers, label: Text('Headers')),
              ButtonSegment(value: _WsPaneTab.connection, label: Text('Connection')),
            ],
            selected: {_activeTab},
            onSelectionChanged: (selection) {
              setState(() => _activeTab = selection.first);
            },
          ),
        ),

        if (_activeTab == _WsPaneTab.messages)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<_WsFilter>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: const [
                          ButtonSegment(value: _WsFilter.all, label: Text('All')),
                          ButtonSegment(value: _WsFilter.sent, label: Text('Sent')),
                          ButtonSegment(value: _WsFilter.received, label: Text('Received')),
                          ButtonSegment(value: _WsFilter.errors, label: Text('Errors')),
                        ],
                        selected: {_activeFilter},
                        onSelectionChanged: (selection) {
                          setState(() => _activeFilter = selection.first);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      children: [
                        const Text('Auto-scroll', style: TextStyle(fontSize: 12)),
                        Switch.adaptive(
                          value: _autoScroll,
                          onChanged: (v) => setState(() => _autoScroll = v),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: const Text('Collapse similar messages'),
                            selected: _collapseSimilar,
                            onSelected: (v) => setState(() => _collapseSimilar = v),
                          ),
                          FilterChip(
                            label: const Text('Group by type'),
                            selected: _groupByType,
                            onSelected: (v) => setState(() => _groupByType = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Search messages',
                          hintText: 'Find payload content',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<_WsPayloadView>(
                        value: _payloadView,
                        decoration: const InputDecoration(
                          labelText: 'Payload View',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: _WsPayloadView.raw, child: Text('Raw')),
                          DropdownMenuItem(value: _WsPayloadView.pretty, child: Text('Pretty')),
                          DropdownMenuItem(value: _WsPayloadView.json, child: Text('JSON')),
                          DropdownMenuItem(value: _WsPayloadView.hex, child: Text('Hex')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _payloadView = v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // ── Message timeline ─────────────────────────────────────
        Expanded(
          child: switch (_activeTab) {
            _WsPaneTab.messages => timelineEntries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded,
                            size: 48,
                            color: colorScheme.onSurface.withAlpha(80)),
                        const SizedBox(height: 8),
                        Text(
                          session.messages.isEmpty
                              ? 'Connect and send a message to see the timeline'
                              : 'No messages match current filter/search',
                          style: TextStyle(
                              color: colorScheme.onSurface.withAlpha(80)),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    itemCount: timelineEntries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final entry = timelineEntries[i];
                      if (entry.groupLabel != null) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            entry.groupLabel!,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        );
                      }
                      final msg = entry.message!;
                      return _MessageRow(
                        message: msg,
                        index: i + 1,
                        repeatCount: entry.repeatCount,
                        renderedPayload: _renderPayload(msg),
                        jsonError: _jsonErrorFor(msg),
                        onResend: () => _resendMessage(notifier, msg),
                        onCopy: () => _copyMessage(msg),
                        onDuplicate: () => _duplicateMessage(msg),
                      );
                    },
                  ),
            _WsPaneTab.headers => _HeadersView(session: session),
            _WsPaneTab.connection => _ConnectionView(session: session),
          },
        ),

        // ── Message composer ────────────────────────────────────
        if (session.isConnected)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<_WsSendMode>(
                        value: _sendMode,
                        decoration: const InputDecoration(
                          labelText: 'Send Mode',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: _WsSendMode.text, child: Text('TEXT')),
                          DropdownMenuItem(value: _WsSendMode.json, child: Text('JSON')),
                          DropdownMenuItem(value: _WsSendMode.binaryBase64, child: Text('BINARY (base64)')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _sendMode = v;
                            _jsonInputError = null;
                          });
                          if (v == _WsSendMode.json) {
                            _validateJsonInput(showSnack: false);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      children: [
                        const Text('Send on Enter', style: TextStyle(fontSize: 12)),
                        Switch.adaptive(
                          value: _sendOnEnter,
                          onChanged: (v) => setState(() => _sendOnEnter = v),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ],
                ),
                if (_sendMode == _WsSendMode.json) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _validateJsonInput(showSnack: true),
                        icon: Icon(
                          _jsonInputError == null
                              ? Icons.verified_rounded
                              : Icons.error_outline_rounded,
                          size: 16,
                        ),
                        label: const Text('Validate JSON'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _formatJsonInput,
                        icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                        label: const Text('Format'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _jsonInputError == null
                              ? 'JSON looks valid.'
                              : _jsonInputError!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: _jsonInputError == null
                                    ? colorScheme.primary
                                    : colorScheme.error,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _delaySendMs,
                        decoration: const InputDecoration(
                          labelText: 'Delay send',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('None')),
                          DropdownMenuItem(value: 100, child: Text('100 ms')),
                          DropdownMenuItem(value: 250, child: Text('250 ms')),
                          DropdownMenuItem(value: 500, child: Text('500 ms')),
                          DropdownMenuItem(value: 1000, child: Text('1 s')),
                          DropdownMenuItem(value: 2000, child: Text('2 s')),
                          DropdownMenuItem(value: 5000, child: Text('5 s')),
                        ],
                        onChanged: (v) => setState(() => _delaySendMs = v ?? 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _throttleMs,
                        decoration: const InputDecoration(
                          labelText: 'Throttle',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Off')),
                          DropdownMenuItem(value: 100, child: Text('100 ms/frame')),
                          DropdownMenuItem(value: 250, child: Text('250 ms/frame')),
                          DropdownMenuItem(value: 500, child: Text('500 ms/frame')),
                          DropdownMenuItem(value: 1000, child: Text('1 s/frame')),
                        ],
                        onChanged: (v) => setState(() => _throttleMs = v ?? 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => notifier.simulateDropConnection(),
                      icon: const Icon(Icons.portable_wifi_off_rounded),
                      label: const Text('Drop connection'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _msgController,
                        focusNode: _msgFocusNode,
                        minLines: 2,
                        maxLines: 8,
                        textInputAction:
                            _sendOnEnter ? TextInputAction.send : TextInputAction.newline,
                        onSubmitted: _sendOnEnter ? (_) => _sendMessage(notifier) : null,
                        onChanged: _sendMode == _WsSendMode.json
                            ? (_) => _validateJsonInput(showSnack: false)
                            : null,
                        decoration: InputDecoration(
                          labelText: 'Message',
                          hintText: switch (_sendMode) {
                            _WsSendMode.text => 'Enter text payload',
                            _WsSendMode.json => 'Enter JSON payload',
                            _WsSendMode.binaryBase64 => 'Enter base64 payload',
                          },
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        style: _sendMode == _WsSendMode.json
                            ? const TextStyle(fontFamily: 'monospace')
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _sendMessage(notifier),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _sendMessage(WebSocketNotifier notifier) {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    final mode = _sendMode;
    late final VoidCallback sendAction;

    if (_sendMode == _WsSendMode.json) {
      if (!_validateJsonInput(showSnack: true)) {
        return;
      }
      sendAction = () => notifier.sendText(text);
    } else if (_sendMode == _WsSendMode.binaryBase64) {
      late final Uint8List bytes;
      try {
        bytes = base64Decode(text);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid base64 payload: $e')),
        );
        return;
      }
      sendAction = () => notifier.sendBinary(bytes);
    } else {
      sendAction = () => notifier.sendText(text);
    }

    _dispatchSend(notifier, sendAction: sendAction, requestBody: text, mode: mode);
    _msgController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _msgFocusNode.requestFocus();
      }
    });
  }

  Future<void> _connect(WebSocketNotifier notifier) async {
    final url = _normalizeWebSocketUrl(_urlController.text.trim());
    await notifier.connect(url);
    final session = ref.read(webSocketNotifierProvider);
    ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
      apiType: APIType.websocket,
      url: url,
      method: HTTPVerb.get,
      responseStatus: session.isConnected ? 101 : -1,
      message: session.isConnected
          ? 'WebSocket connected'
          : (session.error ?? 'WebSocket connection failed'),
      responseBody: session.error,
    );
  }

  String _normalizeWebSocketUrl(String url) {
    if (url.isEmpty) return url;
    final lower = url.toLowerCase();
    if (lower.startsWith('ws://') || lower.startsWith('wss://')) {
      return url;
    }
    return 'ws://$url';
  }

  List<WebSocketMessage> _filteredMessages(List<WebSocketMessage> all) {
    return all.where((msg) {
      final filterMatch = switch (_activeFilter) {
        _WsFilter.all => true,
        _WsFilter.sent => msg.isSent,
        _WsFilter.received => !msg.isSent && msg.type != 'error',
        _WsFilter.errors => msg.type == 'error',
      };
      if (!filterMatch) return false;
      final query = _searchController.text.trim().toLowerCase();
      if (query.isEmpty) return true;
      return msg.payload.toLowerCase().contains(query) ||
          msg.type.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  List<_WsTimelineEntry> _timelineEntries(List<WebSocketMessage> messages) {
    final entries = <_WsTimelineEntry>[];
    String? lastType;
    _WsTimelineEntry? pending;

    for (final msg in messages) {
      if (_groupByType && lastType != msg.type) {
        entries.add(_WsTimelineEntry.group('Type: ${msg.type.toUpperCase()}'));
        lastType = msg.type;
      }

      if (_collapseSimilar) {
        final canMerge = pending != null &&
            pending.message != null &&
            pending.message!.payload == msg.payload &&
            pending.message!.type == msg.type &&
            pending.message!.isSent == msg.isSent;
        if (canMerge) {
          pending = _WsTimelineEntry.message(msg, repeatCount: pending.repeatCount + 1);
          entries[entries.length - 1] = pending;
          continue;
        }
      }

      pending = _WsTimelineEntry.message(msg);
      entries.add(pending);
    }

    return entries;
  }

  Future<void> _copyMessage(WebSocketMessage msg) async {
    await Clipboard.setData(ClipboardData(text: msg.payload));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied to clipboard.')),
    );
  }

  void _duplicateMessage(WebSocketMessage msg) {
    setState(() {
      _msgController.text = msg.payload;
      if (msg.type == 'binary') {
        _sendMode = _WsSendMode.binaryBase64;
      } else {
        _sendMode = _WsSendMode.text;
      }
    });
    _msgFocusNode.requestFocus();
  }

  String? _jsonErrorFor(WebSocketMessage msg) {
    if (msg.type == 'binary') {
      return null;
    }
    final raw = msg.payload.trim();
    if (raw.isEmpty || (!raw.startsWith('{') && !raw.startsWith('['))) {
      return null;
    }
    try {
      jsonDecode(raw);
      return null;
    } on FormatException catch (e) {
      final offset = e.offset ?? 0;
      final prefix = offset <= 0
          ? ''
          : raw.substring(0, offset.clamp(0, raw.length));
      final line = '\n'.allMatches(prefix).length + 1;
      final lastLineBreak = prefix.lastIndexOf('\n');
      final column = lastLineBreak == -1
          ? prefix.length + 1
          : prefix.length - lastLineBreak;
      return 'Invalid JSON at line $line, column $column';
    } catch (_) {
      return 'Invalid JSON';
    }
  }

  void _resendMessage(WebSocketNotifier notifier, WebSocketMessage msg) {
    if (!sessionCanSend(ref.read(webSocketNotifierProvider))) {
      return;
    }
    if (msg.type == 'binary') {
      late final Uint8List bytes;
      try {
        bytes = base64Decode(msg.payload);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot resend invalid binary payload.')),
        );
        return;
      }
      _dispatchSend(
        notifier,
        sendAction: () => notifier.sendBinary(bytes),
        requestBody: msg.payload,
        mode: _WsSendMode.binaryBase64,
      );
      return;
    }
    if (msg.type == 'error' || msg.type == 'system') {
      return;
    }
    _dispatchSend(
      notifier,
      sendAction: () => notifier.sendText(msg.payload),
      requestBody: msg.payload,
      mode: _WsSendMode.text,
    );
  }

  bool _validateJsonInput({required bool showSnack}) {
    final text = _msgController.text.trim();
    if (text.isEmpty) {
      setState(() => _jsonInputError = 'JSON payload is empty.');
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JSON payload is empty.')),
        );
      }
      return false;
    }
    try {
      final parsed = jsonDecode(text);
      if (parsed is! Map && parsed is! List) {
        throw const FormatException('JSON payload must be object or array');
      }
      setState(() => _jsonInputError = null);
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JSON is valid.')),
        );
      }
      return true;
    } on FormatException catch (e) {
      final message = _jsonFormatExceptionMessage(text, e);
      setState(() => _jsonInputError = message);
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      return false;
    } catch (e) {
      final message = 'Invalid JSON payload: $e';
      setState(() => _jsonInputError = message);
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      return false;
    }
  }

  String _jsonFormatExceptionMessage(String input, FormatException e) {
    final offset = e.offset ?? 0;
    if (offset <= 0 || offset > input.length) {
      return 'Invalid JSON payload: ${e.message}';
    }
    final prefix = input.substring(0, offset);
    final line = '\n'.allMatches(prefix).length + 1;
    final lineStart = prefix.lastIndexOf('\n');
    final column = lineStart == -1 ? prefix.length + 1 : prefix.length - lineStart;
    return 'Invalid JSON at line $line, column $column: ${e.message}';
  }

  void _formatJsonInput() {
    final text = _msgController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('JSON payload is empty.')),
      );
      return;
    }
    try {
      final parsed = jsonDecode(text);
      if (parsed is! Map && parsed is! List) {
        throw const FormatException('JSON payload must be object or array');
      }
      final formatted = const JsonEncoder.withIndent('  ').convert(parsed);
      setState(() {
        _msgController.text = formatted;
        _jsonInputError = null;
      });
      _msgController.selection = TextSelection.collapsed(offset: formatted.length);
      _msgFocusNode.requestFocus();
    } on FormatException catch (e) {
      final message = _jsonFormatExceptionMessage(text, e);
      setState(() => _jsonInputError = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      final message = 'Unable to format JSON: $e';
      setState(() => _jsonInputError = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  void _dispatchSend(
    WebSocketNotifier notifier, {
    required VoidCallback sendAction,
    required String requestBody,
    required _WsSendMode mode,
  }) {
    final now = DateTime.now();
    var scheduledAt = now.add(Duration(milliseconds: _delaySendMs));
    if (_throttleMs > 0 && scheduledAt.isBefore(_nextSendAt)) {
      scheduledAt = _nextSendAt;
    }
    if (_throttleMs > 0) {
      _nextSendAt = scheduledAt.add(Duration(milliseconds: _throttleMs));
    }

    final waitMs = scheduledAt.difference(now).inMilliseconds;
    void executeSend() {
      if (!sessionCanSend(ref.read(webSocketNotifierProvider))) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot send: WebSocket is disconnected.')),
          );
        }
        return;
      }
      sendAction();
      final url = _normalizeWebSocketUrl(_urlController.text.trim());
      ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
        apiType: APIType.websocket,
        url: url,
        method: HTTPVerb.post,
        requestBody: requestBody,
        responseStatus: 200,
        message: 'WebSocket message sent (${mode.name.toUpperCase()})',
        responseBody: requestBody,
      );
    }

    if (waitMs <= 0) {
      executeSend();
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Message queued for ${waitMs}ms (delay/throttle simulation).')),
      );
    }
    late final Timer timer;
    timer = Timer(Duration(milliseconds: waitMs), () {
      _scheduledSendTimers.remove(timer);
      executeSend();
    });
    _scheduledSendTimers.add(timer);
  }

  String _renderPayload(WebSocketMessage msg) {
    if (_payloadView == _WsPayloadView.raw) {
      return msg.payload;
    }
    if (_payloadView == _WsPayloadView.hex) {
      if (msg.type == 'binary') {
        try {
          return _toHex(base64Decode(msg.payload));
        } catch (_) {
          return msg.payload;
        }
      }
      return _toHex(Uint8List.fromList(utf8.encode(msg.payload)));
    }

    final normalized = msg.type == 'binary'
        ? _tryDecodeBinaryAsText(msg.payload)
        : msg.payload;

    if (_payloadView == _WsPayloadView.json) {
      try {
        final parsed = jsonDecode(normalized);
        return const JsonEncoder.withIndent('  ').convert(parsed);
      } catch (_) {
        return normalized;
      }
    }

    // Pretty mode: pretty-print JSON automatically, else return raw text.
    try {
      final parsed = jsonDecode(normalized);
      return const JsonEncoder.withIndent('  ').convert(parsed);
    } catch (_) {
      return normalized;
    }
  }

  String _tryDecodeBinaryAsText(String base64Payload) {
    try {
      final decoded = base64Decode(base64Payload);
      return utf8.decode(decoded);
    } catch (_) {
      return base64Payload;
    }
  }

  String _toHex(Uint8List data) {
    final b = StringBuffer();
    for (var i = 0; i < data.length; i++) {
      if (i > 0) {
        b.write(' ');
      }
      b.write(data[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  bool sessionCanSend(WebSocketSessionState session) {
    return session.connectionState == WebSocketConnectionState.connected;
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.state,
    required this.onConnect,
    required this.onDisconnect,
  });

  final WebSocketConnectionState state;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      WebSocketConnectionState.connecting => FilledButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('Connecting…'),
        ),
      WebSocketConnectionState.connected => FilledButton.icon(
          onPressed: onDisconnect,
          icon: const Icon(Icons.stop_circle_rounded),
          label: const Text('Disconnect'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade700,
          ),
        ),
      WebSocketConnectionState.disconnected => FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.cable_rounded),
          label: const Text('Connect'),
        ),
    };
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.session});
  final WebSocketSessionState session;

  @override
  Widget build(BuildContext context) {
    final total = session.messages.length;
    final sent = session.messages.where((m) => m.isSent).length;
    final received = total - sent;
    final protocol = session.connectedUrl == null
      ? '--'
      : (Uri.tryParse(session.connectedUrl!)?.scheme ?? '--');
    final latency = session.connectLatencyMs == null
      ? '--'
      : '${session.connectLatencyMs} ms';
    final durationSecs = session.connectedAt == null
        ? 0
        : DateTime.now().difference(session.connectedAt!).inSeconds;
    final totalBytes = session.messages
        .map((m) => m.sizeBytes ?? m.payload.length)
        .fold<int>(0, (a, b) => a + b);
    final msgRate = durationSecs <= 0
        ? '--'
        : (total / durationSecs).toStringAsFixed(2);
    final throughput = durationSecs <= 0
        ? '--'
        : '${(totalBytes / durationSecs).toStringAsFixed(1)} B/s';
    final spike = session.messages.isEmpty
        ? '--'
        : '${session.messages.map((m) => m.sizeBytes ?? m.payload.length).reduce((a, b) => a > b ? a : b)} B';
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colorScheme.surfaceContainerHighest,
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        runSpacing: 4,
        spacing: 10,
        children: [
          _StatChip(label: 'Total', value: '$total', icon: Icons.swap_horiz),
          _StatChip(
              label: '↑ Sent', value: '$sent', icon: Icons.arrow_upward),
          _StatChip(
              label: '↓ Received',
              value: '$received',
              icon: Icons.arrow_downward),
          _StatChip(label: 'Protocol', value: protocol, icon: Icons.link_rounded),
          _StatChip(label: 'Latency', value: latency, icon: Icons.speed_rounded),
          _StatChip(label: 'Msg/s', value: msgRate, icon: Icons.toll_rounded),
          _StatChip(label: 'Throughput', value: throughput, icon: Icons.show_chart_rounded),
          _StatChip(label: 'Spike', value: spike, icon: Icons.graphic_eq_rounded),
          _StatChip(
            label: 'Status',
            value: switch (session.connectionState) {
              WebSocketConnectionState.connected => 'Connected',
              WebSocketConnectionState.connecting => 'Connecting',
              WebSocketConnectionState.disconnected => 'Disconnected',
            },
            icon: Icons.circle,
          ),
        ],
      ),
    );
  }
}

class _HeadersView extends StatelessWidget {
  const _HeadersView({required this.session});

  final WebSocketSessionState session;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Handshake Request', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        ListTile(
          dense: true,
          title: const Text('Request line'),
          subtitle: SelectableText(
            session.handshakeRequestLine ?? 'GET / HTTP/1.1',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        ...session.requestHeaders.entries.map(
          (e) => ListTile(
            dense: true,
            title: Text(e.key),
            subtitle: SelectableText(
              e.value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
        const Divider(),
        Text('Handshake Response', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        ListTile(
          dense: true,
          title: const Text('Status'),
          subtitle: SelectableText(
            session.handshakeResponseLine ?? 'Not exposed by transport',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        ListTile(
          dense: true,
          title: const Text('Subprotocol'),
          subtitle: SelectableText(
            session.negotiatedSubprotocol ?? 'None',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        ListTile(
          dense: true,
          title: const Text('Extensions'),
          subtitle: SelectableText(
            session.negotiatedExtensions.isEmpty
                ? 'None / not exposed by transport'
                : session.negotiatedExtensions.join(', '),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

class _ConnectionView extends StatelessWidget {
  const _ConnectionView({required this.session});

  final WebSocketSessionState session;

  @override
  Widget build(BuildContext context) {
    final connectedUrl = session.connectedUrl ?? '--';
    final protocol = session.connectedUrl == null
        ? '--'
        : (Uri.tryParse(session.connectedUrl!)?.scheme ?? '--');
    final latency = session.connectLatencyMs == null
        ? '--'
        : '${session.connectLatencyMs} ms';
    final uptime = session.connectedAt == null
        ? '--'
        : '${DateTime.now().difference(session.connectedAt!).inSeconds}s';

    final rows = <(String, String)>[
      ('URL', connectedUrl),
      ('Protocol', protocol),
      ('Connect latency', latency),
      ('Uptime', uptime),
      (
        'Status',
        switch (session.connectionState) {
          WebSocketConnectionState.connected => 'Connected',
          WebSocketConnectionState.connecting => 'Connecting',
          WebSocketConnectionState.disconnected => 'Disconnected',
        },
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: rows
          .map(
            (row) => ListTile(
              dense: true,
              title: Text(row.$1),
              subtitle: SelectableText(
                row.$2,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(
      {required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 4),
        Text('$label: ', style: Theme.of(context).textTheme.labelSmall),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.message,
    required this.index,
    required this.repeatCount,
    required this.renderedPayload,
    required this.jsonError,
    required this.onResend,
    required this.onCopy,
    required this.onDuplicate,
  });
  final WebSocketMessage message;
  final int index;
  final int repeatCount;
  final String renderedPayload;
  final String? jsonError;
  final VoidCallback onResend;
  final VoidCallback onCopy;
  final VoidCallback onDuplicate;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final colorScheme = Theme.of(context).colorScheme;
    final isSent = msg.isSent;
    final isError = msg.type == 'error';
    final isSystem = msg.type == 'system';
    final collapsedPreview = widget.renderedPayload.length > 140
        ? '${widget.renderedPayload.substring(0, 140)}...'
        : widget.renderedPayload;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        dense: true,
        title: Row(
          children: [
            Text(
              '#${widget.index}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (widget.repeatCount > 1) ...[
              const SizedBox(width: 6),
              Text(
                'x${widget.repeatCount}',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isError
                    ? colorScheme.errorContainer
                    : isSystem
                        ? colorScheme.surfaceContainerHighest
                        : isSent
                            ? colorScheme.primaryContainer
                            : colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isError
                    ? 'ERROR'
                    : isSystem
                        ? 'SYSTEM'
                        : isSent
                            ? 'SENT'
                            : 'RECV',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isError
                      ? colorScheme.onErrorContainer
                      : isSystem
                          ? colorScheme.onSurface
                          : isSent
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onTertiaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(msg.type.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            Text(
              _formatTime(msg.timestamp),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(width: 8),
            Text(
              '${msg.sizeBytes ?? msg.payload.length} B',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            collapsedPreview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface.withAlpha(170),
                ),
          ),
        ),
        children: [
          Row(
            children: [
              if (!isError && !isSystem)
                IconButton(
                  tooltip: 'Resend',
                  onPressed: widget.onResend,
                  icon: const Icon(Icons.replay_rounded, size: 16),
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                tooltip: 'Copy',
                onPressed: widget.onCopy,
                icon: const Icon(Icons.copy_rounded, size: 16),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: 'Duplicate to composer',
                onPressed: widget.onDuplicate,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          _section(
            context,
            'Headers',
            'Direction: ${isSent ? 'Sent' : 'Received'}\n'
                'Type: ${msg.type}\n'
                'Timestamp: ${msg.timestamp.toIso8601String()}\n'
                'Size: ${msg.sizeBytes ?? msg.payload.length} B',
          ),
          const SizedBox(height: 6),
          _section(context, 'Raw payload', msg.payload),
          const SizedBox(height: 6),
          _section(
            context,
            'Parsed view',
            widget.jsonError == null
                ? widget.renderedPayload
                : '${widget.jsonError}\n\n${widget.renderedPayload}',
            isError: widget.jsonError != null,
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    String value, {
    bool isError = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer.withAlpha(100) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isError ? scheme.onErrorContainer : null,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}

class _WsTimelineEntry {
  const _WsTimelineEntry._({
    this.groupLabel,
    this.message,
    this.repeatCount = 1,
  });

  const _WsTimelineEntry.group(String label)
      : this._(groupLabel: label, message: null, repeatCount: 0);

  const _WsTimelineEntry.message(WebSocketMessage msg, {int repeatCount = 1})
      : this._(groupLabel: null, message: msg, repeatCount: repeatCount);

  final String? groupLabel;
  final WebSocketMessage? message;
  final int repeatCount;
}
