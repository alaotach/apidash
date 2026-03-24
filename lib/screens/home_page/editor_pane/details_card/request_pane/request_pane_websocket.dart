import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/generated/google/protobuf/descriptor.pb.dart'
  as $descriptor;
import 'package:apidash/providers/providers.dart';
import 'package:apidash/providers/websocket_providers.dart';
import 'package:apidash/utils/file_utils.dart';

enum _WsPaneTab { messages, headers, connection }

enum _WsFilter { all, sent, received, errors }

enum _WsPayloadView { raw, pretty, json, hex }

enum _WsSendMode { text, json, binaryBase64 }

enum _WsBinaryDecoder {
  none,
  utf8,
  protobuf,
  messagePack,
  flatBuffers,
  fixedQuote,
  fixedTrade,
  fixedOrderBook,
}

const int _kFlatBaseTypeNone = 0;
const int _kFlatBaseTypeUType = 1;
const int _kFlatBaseTypeBool = 2;
const int _kFlatBaseTypeByte = 3;
const int _kFlatBaseTypeUByte = 4;
const int _kFlatBaseTypeShort = 5;
const int _kFlatBaseTypeUShort = 6;
const int _kFlatBaseTypeInt = 7;
const int _kFlatBaseTypeUInt = 8;
const int _kFlatBaseTypeLong = 9;
const int _kFlatBaseTypeULong = 10;
const int _kFlatBaseTypeFloat = 11;
const int _kFlatBaseTypeDouble = 12;
const int _kFlatBaseTypeString = 13;
const int _kFlatBaseTypeVector = 14;
const int _kFlatBaseTypeObj = 15;
const int _kFlatBaseTypeUnion = 16;
const int _kFlatBaseTypeArray = 17;

class _WsQuoteEvent {
  const _WsQuoteEvent({
    required this.symbol,
    required this.sequence,
    required this.timestampMicros,
    required this.bid,
    required this.ask,
    required this.bidSize,
    required this.askSize,
  });

  final String symbol;
  final int sequence;
  final int timestampMicros;
  final double bid;
  final double ask;
  final double bidSize;
  final double askSize;

  Map<String, Object> toJson() => {
        'event': 'quote',
        'symbol': symbol,
        'sequence': sequence,
        'timestampMicros': timestampMicros,
        'bid': bid,
        'ask': ask,
        'bidSize': bidSize,
        'askSize': askSize,
      };
}

class _WsTradeEvent {
  const _WsTradeEvent({
    required this.symbol,
    required this.sequence,
    required this.timestampMicros,
    required this.price,
    required this.size,
    required this.side,
  });

  final String symbol;
  final int sequence;
  final int timestampMicros;
  final double price;
  final double size;
  final String side;

  Map<String, Object> toJson() => {
        'event': 'trade',
        'symbol': symbol,
        'sequence': sequence,
        'timestampMicros': timestampMicros,
        'price': price,
        'size': size,
        'side': side,
      };
}

class _WsOrderBookEvent {
  const _WsOrderBookEvent({
    required this.symbol,
    required this.sequence,
    required this.timestampMicros,
    required this.bidPrice,
    required this.bidSize,
    required this.askPrice,
    required this.askSize,
  });

  final String symbol;
  final int sequence;
  final int timestampMicros;
  final double bidPrice;
  final double bidSize;
  final double askPrice;
  final double askSize;

  Map<String, Object> toJson() => {
        'event': 'orderbook',
        'symbol': symbol,
        'sequence': sequence,
        'timestampMicros': timestampMicros,
        'bidPrice': bidPrice,
        'bidSize': bidSize,
        'askPrice': askPrice,
        'askSize': askSize,
      };
}

class _WsDecodedPayload {
  const _WsDecodedPayload({
    required this.display,
    this.sequence,
    this.streamKey,
  });

  final String display;
  final int? sequence;
  final String? streamKey;
}

class _WsProtoFieldSchema {
  const _WsProtoFieldSchema({
    required this.name,
    required this.number,
    required this.type,
    this.typeName,
  });

  final String name;
  final int number;
  final int type;
  final String? typeName;
}

class _WsFlatFieldSchema {
  const _WsFlatFieldSchema({
    required this.name,
    required this.id,
    this.offset,
    required this.baseType,
    required this.elementType,
    this.objectType,
    this.structType,
  });

  final String name;
  final int id;
  final int? offset;
  final int baseType;
  final int elementType;
  final String? objectType;
  final bool? structType;
}

class _WsFlatObjectSchema {
  const _WsFlatObjectSchema({
    required this.name,
    required this.fields,
    required this.isStruct,
    required this.byteSize,
  });

  final String name;
  final Map<int, _WsFlatFieldSchema> fields;
  final bool isStruct;
  final int byteSize;
}

class _WsFlatSchemaBundle {
  const _WsFlatSchemaBundle({
    required this.schemas,
    this.detectedRootTable,
  });

  final Map<String, _WsFlatObjectSchema> schemas;
  final String? detectedRootTable;
}

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
  _WsBinaryDecoder _binaryDecoder = _WsBinaryDecoder.utf8;
  _WsSendMode _sendMode = _WsSendMode.text;
  bool _showAdvancedTools = false;
  bool _showAdvancedSend = false;
  bool _collapseSimilar = false;
  bool _groupByType = false;
  int _delaySendMs = 0;
  int _throttleMs = 0;
  DateTime _nextSendAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _jsonInputError;
  String? _protoSchemaFileName;
  String? _flatSchemaFileName;
  String? _selectedProtoMessageType;
  final Map<String, Map<int, _WsProtoFieldSchema>> _protoFieldSchemas = {};
  final Map<int, String> _flatBufferFieldAliases = {};
  final Map<String, _WsFlatObjectSchema> _flatTableSchemas = {};
  String? _selectedFlatTableType;

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
    final decodedPayloadByMessage =
      _buildDecodedPayloadsWithGapDetection(filteredMessages);
    final durationSecs = session.connectedAt == null
        ? 0
        : DateTime.now().difference(session.connectedAt!).inSeconds;
    final msgRate = durationSecs <= 0
        ? '--'
        : (session.messages.length / durationSecs).toStringAsFixed(2);
    final statusText = switch (session.connectionState) {
      WebSocketConnectionState.connected => 'Connected',
      WebSocketConnectionState.connecting => 'Connecting',
      WebSocketConnectionState.disconnected => 'Disconnected',
    };

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

        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<_WsPaneTab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: _WsPaneTab.messages, label: Text('Messages')),
                    ButtonSegment(
                        value: _WsPaneTab.headers, label: Text('Headers')),
                    ButtonSegment(
                        value: _WsPaneTab.connection,
                        label: Text('Connection')),
                  ],
                  selected: {_activeTab},
                  onSelectionChanged: (selection) {
                    setState(() => _activeTab = selection.first);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$statusText • ${session.messages.length} msgs • $msgRate msg/s',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: colorScheme.onSurface.withAlpha(180)),
              ),
            ],
          ),
        ),

        if (_activeTab == _WsPaneTab.messages)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(children: [
              LayoutBuilder(builder: (context, constraints) {
                final typeField = DropdownButtonFormField<_WsFilter>(
                  value: _activeFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: _WsFilter.all, child: Text('All')),
                    DropdownMenuItem(value: _WsFilter.sent, child: Text('Sent')),
                    DropdownMenuItem(value: _WsFilter.received, child: Text('Received')),
                    DropdownMenuItem(value: _WsFilter.errors, child: Text('Errors')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _activeFilter = value);
                  },
                );

                final searchField = TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Search messages',
                    hintText: 'Find payload content',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                );

                final actions = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _groupByType ? 'Ungroup by type' : 'Group by type',
                      onPressed: () => setState(() => _groupByType = !_groupByType),
                      icon: Icon(
                        Icons.segment_rounded,
                        color: _groupByType ? colorScheme.primary : null,
                      ),
                    ),
                    IconButton(
                      tooltip: _collapseSimilar
                          ? 'Expand similar messages'
                          : 'Collapse similar messages',
                      onPressed: () => setState(
                          () => _collapseSimilar = !_collapseSimilar),
                      icon: Icon(
                        Icons.compress_rounded,
                        color: _collapseSimilar ? colorScheme.primary : null,
                      ),
                    ),
                    IconButton(
                      tooltip: _autoScroll ? 'Disable auto-scroll' : 'Enable auto-scroll',
                      onPressed: () => setState(() => _autoScroll = !_autoScroll),
                      icon: Icon(
                        Icons.vertical_align_bottom_rounded,
                        color: _autoScroll ? colorScheme.primary : null,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(
                          () => _showAdvancedTools = !_showAdvancedTools),
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: Text(_showAdvancedTools ? 'Hide advanced' : 'Advanced'),
                    ),
                  ],
                );

                if (constraints.maxWidth < 900) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      typeField,
                      const SizedBox(height: 8),
                      searchField,
                      const SizedBox(height: 4),
                      Align(alignment: Alignment.centerLeft, child: actions),
                    ],
                  );
                }

                return Row(
                  children: [
                    SizedBox(width: 140, child: typeField),
                    const SizedBox(width: 8),
                    Expanded(child: searchField),
                    const SizedBox(width: 6),
                    actions,
                  ],
                );
              }),
              if (_showAdvancedTools) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withAlpha(130),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      LayoutBuilder(builder: (context, constraints) {
                        final payloadViewField =
                            DropdownButtonFormField<_WsPayloadView>(
                          value: _payloadView,
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: 'Payload View',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: _WsPayloadView.raw, child: Text('Raw')),
                            DropdownMenuItem(
                                value: _WsPayloadView.pretty,
                                child: Text('Pretty')),
                            DropdownMenuItem(
                                value: _WsPayloadView.json, child: Text('JSON')),
                            DropdownMenuItem(
                                value: _WsPayloadView.hex, child: Text('Hex')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _payloadView = v);
                          },
                        );

                        final binaryDecoderField =
                            DropdownButtonFormField<_WsBinaryDecoder>(
                          value: _binaryDecoder,
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: 'Binary Decoder',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.none,
                                child: Text('Raw bytes')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.utf8,
                                child: Text('UTF-8')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.protobuf,
                                child: Text('Protobuf (wire)')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.messagePack,
                                child: Text('MessagePack')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.flatBuffers,
                                child: Text('FlatBuffers')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.fixedQuote,
                                child: Text('Fixed: Quote')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.fixedTrade,
                                child: Text('Fixed: Trade')),
                            DropdownMenuItem(
                                value: _WsBinaryDecoder.fixedOrderBook,
                                child: Text('Fixed: OrderBook')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _binaryDecoder = v);
                          },
                        );

                        if (constraints.maxWidth < 700) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              payloadViewField,
                              const SizedBox(height: 8),
                              binaryDecoderField,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: payloadViewField),
                            const SizedBox(width: 8),
                            Expanded(child: binaryDecoderField),
                          ],
                        );
                      }),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _uploadProtobufDescriptor,
                            icon: const Icon(Icons.upload_file_rounded, size: 16),
                            label: Text(_protoSchemaFileName == null
                                ? 'Upload Protobuf Descriptor'
                                : 'Descriptor: $_protoSchemaFileName'),
                          ),
                          if (_protoFieldSchemas.isNotEmpty)
                            SizedBox(
                              width: 300,
                              child: DropdownButtonFormField<String>(
                                value: _selectedProtoMessageType,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Proto Message Type',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: _protoFieldSchemas.keys
                                    .map((name) => DropdownMenuItem<String>(
                                          value: name,
                                          child: Text(name,
                                              overflow: TextOverflow.ellipsis),
                                        ))
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(
                                      () => _selectedProtoMessageType = value);
                                },
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: _uploadFlatSchema,
                            icon: const Icon(Icons.schema_rounded, size: 16),
                            label: Text(_flatSchemaFileName == null
                                ? 'Upload FlatBuffers BFBS/JSON'
                                : 'Flat schema: $_flatSchemaFileName'),
                          ),
                          if (_flatTableSchemas.isNotEmpty)
                            SizedBox(
                              width: 300,
                              child: DropdownButtonFormField<String>(
                                value: _selectedFlatTableType,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'FlatBuffers Table',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: _flatTableSchemas.keys
                                    .map((name) => DropdownMenuItem<String>(
                                          value: name,
                                          child: Text(name,
                                              overflow: TextOverflow.ellipsis),
                                        ))
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() {
                                    _selectedFlatTableType = value;
                                    final schema =
                                        _flatTableSchemas[value]?.fields ??
                                            const {};
                                    _flatBufferFieldAliases
                                      ..clear()
                                      ..addEntries(schema.entries.map(
                                          (e) => MapEntry(e.key, e.value.name)));
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ]),
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
                      final decoded = decodedPayloadByMessage[msg] ??
                          _WsDecodedPayload(display: _renderPayload(msg));
                      return _MessageRow(
                        message: msg,
                        index: i + 1,
                        repeatCount: entry.repeatCount,
                        renderedPayload: decoded.display,
                        sequence: decoded.sequence,
                        streamKey: decoded.streamKey,
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _showAdvancedSend = !_showAdvancedSend),
                    icon: const Icon(Icons.tune_rounded, size: 16),
                    label: Text(
                      _showAdvancedSend ? 'Hide advanced send' : 'Advanced send',
                    ),
                  ),
                ),
                if (_showAdvancedSend) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withAlpha(130),
                      borderRadius: BorderRadius.circular(8),
                    ),
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
                                  DropdownMenuItem(
                                      value: _WsSendMode.text,
                                      child: Text('TEXT')),
                                  DropdownMenuItem(
                                      value: _WsSendMode.json,
                                      child: Text('JSON')),
                                  DropdownMenuItem(
                                      value: _WsSendMode.binaryBase64,
                                      child: Text('BINARY (base64)')),
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
                                const Text('Send on Enter',
                                    style: TextStyle(fontSize: 12)),
                                Switch.adaptive(
                                  value: _sendOnEnter,
                                  onChanged: (v) =>
                                      setState(() => _sendOnEnter = v),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
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
                                onPressed: () =>
                                    _validateJsonInput(showSnack: true),
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
                                icon: const Icon(Icons.auto_fix_high_rounded,
                                    size: 16),
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
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
                                  DropdownMenuItem(
                                      value: 100, child: Text('100 ms')),
                                  DropdownMenuItem(
                                      value: 250, child: Text('250 ms')),
                                  DropdownMenuItem(
                                      value: 500, child: Text('500 ms')),
                                  DropdownMenuItem(value: 1000, child: Text('1 s')),
                                  DropdownMenuItem(value: 2000, child: Text('2 s')),
                                  DropdownMenuItem(value: 5000, child: Text('5 s')),
                                ],
                                onChanged: (v) =>
                                    setState(() => _delaySendMs = v ?? 0),
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
                                  DropdownMenuItem(
                                      value: 100,
                                      child: Text('100 ms/frame')),
                                  DropdownMenuItem(
                                      value: 250,
                                      child: Text('250 ms/frame')),
                                  DropdownMenuItem(
                                      value: 500,
                                      child: Text('500 ms/frame')),
                                  DropdownMenuItem(
                                      value: 1000, child: Text('1 s/frame')),
                                ],
                                onChanged: (v) =>
                                    setState(() => _throttleMs = v ?? 0),
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
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
      return _payloadForDisplay(msg).toLowerCase().contains(query) ||
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
          _samePayload(pending.message!, msg) &&
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
    await Clipboard.setData(ClipboardData(text: _payloadForDisplay(msg)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied to clipboard.')),
    );
  }

  void _duplicateMessage(WebSocketMessage msg) {
    setState(() {
      _msgController.text = _payloadForComposer(msg);
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
    final raw = (msg.textPayload ?? '').trim();
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
      final bytes = msg.binaryPayload;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot resend invalid binary payload.')),
        );
        return;
      }
      _dispatchSend(
        notifier,
        sendAction: () => notifier.sendBinary(bytes),
        requestBody: _payloadForDisplay(msg),
        mode: _WsSendMode.binaryBase64,
      );
      return;
    }
    if (msg.type == 'error' || msg.type == 'system') {
      return;
    }
    _dispatchSend(
      notifier,
      sendAction: () => notifier.sendText(msg.textPayload ?? ''),
      requestBody: msg.textPayload ?? '',
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

  Future<void> _uploadProtobufDescriptor() async {
    final files = await pickFiles(
      extensions: const ['desc', 'pb', 'protoset', 'bin'],
    );
    if (files.isEmpty) {
      return;
    }
    final file = files.first;
    try {
      final bytes = await file.readAsBytes();
      final descriptorSet = $descriptor.FileDescriptorSet.fromBuffer(bytes);
      final schemas = _extractProtoSchemas(descriptorSet);
      if (schemas.isEmpty) {
        throw const FormatException('No message schemas found in descriptor set');
      }
      final sortedKeys = schemas.keys.toList(growable: false)..sort();
      if (!mounted) return;
      setState(() {
        _protoFieldSchemas
          ..clear()
          ..addAll(schemas);
        _protoSchemaFileName = getFilenameFromPath(file.path);
        _selectedProtoMessageType = sortedKeys.first;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded ${schemas.length} protobuf message schemas.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load descriptor: $e')),
      );
    }
  }

  Future<void> _uploadFlatSchema() async {
    final files = await pickFiles(
      extensions: const ['bfbs', 'json'],
    );
    if (files.isEmpty) {
      return;
    }
    final file = files.first;
    try {
      final bytes = await file.readAsBytes();
      final fileName = getFilenameFromPath(file.path).toLowerCase();
      final aliases = <int, String>{};
      final tableSchemas = <String, _WsFlatObjectSchema>{};
      String? detectedRootTable;
      if (fileName.endsWith('.json')) {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) {
          final rawMap = decoded['fieldAliases'] ?? decoded['fields'] ?? decoded;
          if (rawMap is Map) {
            for (final entry in rawMap.entries) {
              final fieldIndex = int.tryParse(entry.key.toString());
              final fieldName = entry.value?.toString();
              if (fieldIndex != null && fieldName != null && fieldName.isNotEmpty) {
                aliases[fieldIndex] = fieldName;
              }
            }
          }
        }
      } else {
        final bundle = _extractFlatSchemasFromBfbs(bytes);
        tableSchemas.addAll(bundle.schemas);
        detectedRootTable = bundle.detectedRootTable;
        if (tableSchemas.isNotEmpty) {
          final sortedTables = tableSchemas.keys.toList(growable: false)..sort();
          final selectedByDefault =
              (detectedRootTable != null && tableSchemas.containsKey(detectedRootTable))
                  ? detectedRootTable
                  : sortedTables.first;
          final firstSchema =
              tableSchemas[selectedByDefault]?.fields ?? const {};
          aliases.addEntries(
            firstSchema.entries.map((e) => MapEntry(e.key, e.value.name)),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _flatSchemaFileName = getFilenameFromPath(file.path);
        _flatBufferFieldAliases
          ..clear()
          ..addAll(aliases);
        if (tableSchemas.isNotEmpty) {
          _flatTableSchemas
            ..clear()
            ..addAll(tableSchemas);
          final sortedKeys = _flatTableSchemas.keys.toList(growable: false)
            ..sort();
          _selectedFlatTableType =
              (detectedRootTable != null &&
                  _flatTableSchemas.containsKey(detectedRootTable))
                  ? detectedRootTable
                  : sortedKeys.first;
        } else if (fileName.endsWith('.json')) {
          _flatTableSchemas.clear();
          _selectedFlatTableType = null;
        }
      });

      final message = tableSchemas.isNotEmpty
          ? (detectedRootTable != null
              ? 'Loaded BFBS tables (${tableSchemas.length}). Auto-selected root table: $detectedRootTable.'
              : 'Loaded BFBS tables (${tableSchemas.length}) with semantic field names.')
          : aliases.isNotEmpty
              ? 'Loaded FlatBuffers field aliases (${aliases.length}).'
              : 'No FlatBuffers schema metadata found.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load flat schema: $e')),
      );
    }
  }

  _WsFlatSchemaBundle _extractFlatSchemasFromBfbs(
      Uint8List bytes) {
    final schemas = <String, _WsFlatObjectSchema>{};
    if (bytes.lengthInBytes < 8) {
      return const _WsFlatSchemaBundle(schemas: {});
    }

    final rootTable = _flatRootTable(bytes);
    final objectsVector = _flatTableGetVectorStart(bytes, rootTable, 0);
    if (objectsVector == null) {
      return const _WsFlatSchemaBundle(schemas: {});
    }

    String? detectedRootTable;
    final rootObjectTable = _flatTableGetIndirectTableField(bytes, rootTable, 4);
    if (rootObjectTable != null) {
      final rootName = _flatTableGetString(bytes, rootObjectTable, 0);
      if (rootName != null && rootName.isNotEmpty) {
        detectedRootTable = rootName;
      }
    }

    final objectCount = _flatVectorLength(bytes, objectsVector);
    final objectNameByIndex = <int, String>{};
    final objectIsStructByName = <String, bool>{};
    final objectByteSizeByName = <String, int>{};

    for (var i = 0; i < objectCount; i++) {
      final objectTable = _flatVectorGetIndirectTable(bytes, objectsVector, i);
      if (objectTable == null) continue;
      final objectName = _flatTableGetString(bytes, objectTable, 0);
      if (objectName == null || objectName.isEmpty) continue;
      objectNameByIndex[i] = objectName;
      objectIsStructByName[objectName] =
          (_flatTableGetUint8(bytes, objectTable, 2) ?? 0) != 0;
      objectByteSizeByName[objectName] =
          _flatTableGetInt32(bytes, objectTable, 4) ?? 0;
    }

    for (var i = 0; i < objectCount; i++) {
      final objectTable = _flatVectorGetIndirectTable(bytes, objectsVector, i);
      if (objectTable == null) continue;
      final objectName = _flatTableGetString(bytes, objectTable, 0);
      if (objectName == null || objectName.isEmpty) continue;

      final fieldsVector = _flatTableGetVectorStart(bytes, objectTable, 1);
      final fields = <int, _WsFlatFieldSchema>{};
      if (fieldsVector != null) {
        final fieldCount = _flatVectorLength(bytes, fieldsVector);
        for (var j = 0; j < fieldCount; j++) {
          final fieldTable = _flatVectorGetIndirectTable(bytes, fieldsVector, j);
          if (fieldTable == null) continue;
          final fieldName = _flatTableGetString(bytes, fieldTable, 0);
          if (fieldName == null || fieldName.isEmpty) continue;
          final fieldId = _flatTableGetUint16(bytes, fieldTable, 2) ?? j;
          final fieldOffset = _flatTableGetUint16(bytes, fieldTable, 3);
          final typeTable = _flatTableGetIndirectTableField(bytes, fieldTable, 1);
          final baseType =
              typeTable == null ? _kFlatBaseTypeNone : (_flatTableGetUint8(bytes, typeTable, 0) ?? _kFlatBaseTypeNone);
          final elementType =
              typeTable == null ? _kFlatBaseTypeNone : (_flatTableGetUint8(bytes, typeTable, 1) ?? _kFlatBaseTypeNone);
          final objectIndex =
              typeTable == null ? null : _flatTableGetInt32(bytes, typeTable, 2);
          final objectType =
              objectIndex == null ? null : objectNameByIndex[objectIndex];

          fields[fieldId] = _WsFlatFieldSchema(
            name: fieldName,
            id: fieldId,
            offset: fieldOffset,
            baseType: baseType,
            elementType: elementType,
            objectType: objectType,
            structType: objectType == null
                ? null
                : objectIsStructByName[objectType],
          );
        }
      }
      schemas[objectName] = _WsFlatObjectSchema(
        name: objectName,
        fields: fields,
        isStruct: objectIsStructByName[objectName] ?? false,
        byteSize: objectByteSizeByName[objectName] ?? 0,
      );
    }

    return _WsFlatSchemaBundle(
      schemas: schemas,
      detectedRootTable: detectedRootTable,
    );
  }

  Map<String, Map<int, _WsProtoFieldSchema>> _extractProtoSchemas(
      $descriptor.FileDescriptorSet descriptorSet) {
    final schemas = <String, Map<int, _WsProtoFieldSchema>>{};

    void collectFromMessage(
      String packageName,
      String parentPath,
      $descriptor.DescriptorProto message,
    ) {
      final simpleName = message.name;
      if (simpleName.isEmpty) return;
      final qualified = [
        if (packageName.isNotEmpty) packageName,
        if (parentPath.isNotEmpty) parentPath,
        simpleName,
      ].join('.');

      final fieldMap = <int, _WsProtoFieldSchema>{};
      for (final field in message.field) {
        if (!field.hasNumber()) continue;
        fieldMap[field.number] = _WsProtoFieldSchema(
          name: field.name,
          number: field.number,
          type: field.type.value,
          typeName: field.typeName,
        );
      }
      schemas[qualified] = fieldMap;

      final nestedParent = parentPath.isEmpty ? simpleName : '$parentPath.$simpleName';
      for (final nested in message.nestedType) {
        collectFromMessage(packageName, nestedParent, nested);
      }
    }

    for (final file in descriptorSet.file) {
      final pkg = file.package;
      for (final message in file.messageType) {
        collectFromMessage(pkg, '', message);
      }
    }

    return schemas;
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
      return _payloadForDisplay(msg);
    }
    if (_payloadView == _WsPayloadView.hex) {
      if (msg.type == 'binary') {
        return _toHex(msg.binaryPayload ?? Uint8List(0));
      }
      return _toHex(Uint8List.fromList(utf8.encode(msg.textPayload ?? '')));
    }

    final normalized = msg.type == 'binary'
        ? _decodeBinaryOnDemand(msg.binaryPayload ?? Uint8List(0)).display
        : (msg.textPayload ?? '');

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

  Map<WebSocketMessage, _WsDecodedPayload> _buildDecodedPayloadsWithGapDetection(
      List<WebSocketMessage> messages) {
    final decoded = <WebSocketMessage, _WsDecodedPayload>{};
    final lastSequenceByStream = <String, int>{};
    for (final msg in messages) {
      final parsed = _decodeMessage(msg);
      if (parsed.sequence != null && parsed.streamKey != null) {
        final previous = lastSequenceByStream[parsed.streamKey!];
        if (previous != null && parsed.sequence! > previous + 1) {
          final gap = parsed.sequence! - previous - 1;
          decoded[msg] = _WsDecodedPayload(
            display:
                '[sequence_gap=$gap, prev=$previous, current=${parsed.sequence}]\n${parsed.display}',
            sequence: parsed.sequence,
            streamKey: parsed.streamKey,
          );
        } else {
          decoded[msg] = parsed;
        }
        lastSequenceByStream[parsed.streamKey!] = parsed.sequence!;
      } else {
        decoded[msg] = parsed;
      }
    }
    return decoded;
  }

  _WsDecodedPayload _decodeMessage(WebSocketMessage msg) {
    if (msg.type != 'binary') {
      return _WsDecodedPayload(display: _renderPayload(msg));
    }
    return _decodeBinaryOnDemand(msg.binaryPayload ?? Uint8List(0));
  }

  _WsDecodedPayload _decodeBinaryOnDemand(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const _WsDecodedPayload(display: '');
    }

    try {
      switch (_binaryDecoder) {
        case _WsBinaryDecoder.none:
          return _WsDecodedPayload(display: _toHex(bytes));
        case _WsBinaryDecoder.utf8:
          return _WsDecodedPayload(display: utf8.decode(bytes));
        case _WsBinaryDecoder.protobuf:
          final wire = _decodeProtoWire(
            bytes,
            schemaType: _selectedProtoMessageType,
          );
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(wire),
            sequence: _extractSequence(wire),
            streamKey: _extractStreamKey(wire),
          );
        case _WsBinaryDecoder.messagePack:
          final value = _decodeMessagePack(bytes);
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(value),
            sequence: _extractSequence(value),
            streamKey: _extractStreamKey(value),
          );
        case _WsBinaryDecoder.flatBuffers:
          final fb = _decodeFlatBufferTable(bytes);
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(fb),
            sequence: (fb['sequence'] as num?)?.toInt(),
            streamKey: fb['stream'] as String?,
          );
        case _WsBinaryDecoder.fixedQuote:
          final event = _decodeFixedQuote(bytes);
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(event.toJson()),
            sequence: event.sequence,
            streamKey: 'quote:${event.symbol}',
          );
        case _WsBinaryDecoder.fixedTrade:
          final event = _decodeFixedTrade(bytes);
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(event.toJson()),
            sequence: event.sequence,
            streamKey: 'trade:${event.symbol}',
          );
        case _WsBinaryDecoder.fixedOrderBook:
          final event = _decodeFixedOrderBook(bytes);
          return _WsDecodedPayload(
            display: const JsonEncoder.withIndent('  ').convert(event.toJson()),
            sequence: event.sequence,
            streamKey: 'orderbook:${event.symbol}',
          );
      }
    } catch (e) {
      return _WsDecodedPayload(
        display: 'Decode error (${_binaryDecoder.name}): $e\n${_toHex(bytes)}',
      );
    }
  }

  Map<String, Object?> _decodeProtoWire(
    Uint8List bytes, {
    String? schemaType,
  }) {
    final normalizedSchema = _normalizeProtoTypeName(schemaType);
    final schema = normalizedSchema == null
        ? null
        : _protoFieldSchemas[normalizedSchema];

    final values = <String, Object?>{};
    var index = 0;
    while (index < bytes.length) {
      final key = _readVarint(bytes, index);
      final tag = key.$1;
      index = key.$2;
      final field = tag >> 3;
      final wireType = tag & 0x7;
      final fieldSchema = schema?[field];
      final name = fieldSchema?.name ?? 'field_$field';
      switch (wireType) {
        case 0:
          final value = _readVarint(bytes, index);
          index = value.$2;
          _appendField(
            values,
            name,
            _decodeProtoScalarVarint(value.$1, fieldSchema),
          );
          break;
        case 1:
          if (index + 8 > bytes.length) {
            throw const FormatException('Truncated fixed64');
          }
          final raw = ByteData.sublistView(bytes, index, index + 8)
              .getUint64(0, Endian.little);
          index += 8;
          _appendField(
            values,
            name,
            _decodeProtoFixed64(raw, fieldSchema),
          );
          break;
        case 2:
          final lenInfo = _readVarint(bytes, index);
          final len = lenInfo.$1;
          index = lenInfo.$2;
          if (index + len > bytes.length) {
            throw const FormatException('Truncated length-delimited');
          }
          final chunk = Uint8List.sublistView(bytes, index, index + len);
          index += len;
          _appendField(
            values,
            name,
            _decodeProtoLengthDelimited(chunk, fieldSchema),
          );
          break;
        case 5:
          if (index + 4 > bytes.length) {
            throw const FormatException('Truncated fixed32');
          }
          final raw = ByteData.sublistView(bytes, index, index + 4)
              .getUint32(0, Endian.little);
          index += 4;
          _appendField(
            values,
            name,
            _decodeProtoFixed32(raw, fieldSchema),
          );
          break;
        default:
          throw FormatException('Unsupported protobuf wire type $wireType');
      }
    }

    final seq = _extractSequence(values);
    final stream = _extractStreamKey(values);
    return {
      'protocol': 'protobuf-wire',
      if (normalizedSchema != null) 'schemaType': normalizedSchema,
      if (seq != null) 'sequence': seq,
      if (stream != null && stream.isNotEmpty) 'stream': stream,
      'fields': values,
    };
  }

  void _appendField(Map<String, Object?> map, String key, Object? value) {
    if (!map.containsKey(key)) {
      map[key] = value;
      return;
    }
    final existing = map[key];
    if (existing is List<Object?>) {
      map[key] = [...existing, value];
      return;
    }
    map[key] = [existing, value];
  }

  String? _normalizeProtoTypeName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    return name.startsWith('.') ? name.substring(1) : name;
  }

  Object? _decodeProtoScalarVarint(int raw, _WsProtoFieldSchema? schema) {
    final type = schema?.type;
    switch (type) {
      case 8:
        return raw != 0;
      case 17:
      case 18:
        return _zigZagDecode(raw);
      default:
        return raw;
    }
  }

  Object? _decodeProtoFixed64(int raw, _WsProtoFieldSchema? schema) {
    final type = schema?.type;
    if (type == 1) {
      final data = ByteData(8)..setUint64(0, raw, Endian.little);
      return data.getFloat64(0, Endian.little);
    }
    return raw;
  }

  Object? _decodeProtoFixed32(int raw, _WsProtoFieldSchema? schema) {
    final type = schema?.type;
    if (type == 2) {
      final data = ByteData(4)..setUint32(0, raw, Endian.little);
      return data.getFloat32(0, Endian.little);
    }
    return raw;
  }

  Object? _decodeProtoLengthDelimited(
    Uint8List chunk,
    _WsProtoFieldSchema? schema,
  ) {
    final type = schema?.type;
    if (type == 9) {
      return utf8.decode(chunk);
    }
    if (type == 12) {
      return _toHex(chunk);
    }
    if (type == 11) {
      final nestedType = _normalizeProtoTypeName(schema?.typeName);
      final nested = _decodeProtoWire(chunk, schemaType: nestedType);
      return nested['fields'];
    }
    return _bestEffortPayload(chunk);
  }

  int _zigZagDecode(int value) {
    return (value >> 1) ^ (-(value & 1));
  }

  (int, int) _readVarint(Uint8List bytes, int start) {
    var value = 0;
    var shift = 0;
    var index = start;
    while (index < bytes.length) {
      final byte = bytes[index++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return (value, index);
      }
      shift += 7;
      if (shift > 63) throw const FormatException('Varint too large');
    }
    throw const FormatException('Truncated varint');
  }

  int _flatRootTable(Uint8List bytes) {
    if (bytes.lengthInBytes < 4) return 0;
    final rootOffset = ByteData.sublistView(bytes, 0, 4)
        .getUint32(0, Endian.little);
    return rootOffset;
  }

  int _flatTableVTable(Uint8List bytes, int table) {
    if (table <= 0 || table + 4 > bytes.lengthInBytes) return -1;
    final rel = ByteData.sublistView(bytes, table, table + 4)
        .getInt32(0, Endian.little);
    return table - rel;
  }

  int _flatTableFieldOffset(Uint8List bytes, int table, int fieldId) {
    final vtable = _flatTableVTable(bytes, table);
    if (vtable < 0 || vtable + 4 > bytes.lengthInBytes) return 0;
    final vtableLength = ByteData.sublistView(bytes, vtable, vtable + 2)
        .getUint16(0, Endian.little);
    final entry = vtable + 4 + (fieldId * 2);
    if (entry + 2 > vtable + vtableLength || entry + 2 > bytes.lengthInBytes) {
      return 0;
    }
    return ByteData.sublistView(bytes, entry, entry + 2)
        .getUint16(0, Endian.little);
  }

  int? _flatTableGetVectorStart(Uint8List bytes, int table, int fieldId) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    if (addr + 4 > bytes.lengthInBytes) return null;
    final rel = ByteData.sublistView(bytes, addr, addr + 4)
        .getUint32(0, Endian.little);
    final vec = addr + rel;
    if (vec + 4 > bytes.lengthInBytes) return null;
    return vec;
  }

  int _flatVectorLength(Uint8List bytes, int vectorStart) {
    if (vectorStart + 4 > bytes.lengthInBytes) return 0;
    return ByteData.sublistView(bytes, vectorStart, vectorStart + 4)
        .getUint32(0, Endian.little);
  }

  int? _flatVectorGetIndirectTable(
    Uint8List bytes,
    int vectorStart,
    int index,
  ) {
    final length = _flatVectorLength(bytes, vectorStart);
    if (index < 0 || index >= length) return null;
    final elemAddr = vectorStart + 4 + (index * 4);
    if (elemAddr + 4 > bytes.lengthInBytes) return null;
    final rel = ByteData.sublistView(bytes, elemAddr, elemAddr + 4)
        .getUint32(0, Endian.little);
    final table = elemAddr + rel;
    if (table < 0 || table >= bytes.lengthInBytes) return null;
    return table;
  }

  String? _flatTableGetString(Uint8List bytes, int table, int fieldId) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    if (addr + 4 > bytes.lengthInBytes) return null;
    final rel = ByteData.sublistView(bytes, addr, addr + 4)
        .getUint32(0, Endian.little);
    final str = addr + rel;
    if (str + 4 > bytes.lengthInBytes) return null;
    final len = ByteData.sublistView(bytes, str, str + 4)
        .getUint32(0, Endian.little);
    final start = str + 4;
    final end = start + len;
    if (start < 0 || end > bytes.lengthInBytes) return null;
    return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  }

  int? _flatTableGetUint16(Uint8List bytes, int table, int fieldId) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    if (addr + 2 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 2)
        .getUint16(0, Endian.little);
  }

  int? _flatTableGetUint8(Uint8List bytes, int table, int fieldId) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    if (addr + 1 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 1).getUint8(0);
  }

  int? _flatTableGetInt32(Uint8List bytes, int table, int fieldId) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    if (addr + 4 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 4)
        .getInt32(0, Endian.little);
  }

  int? _flatTableGetIndirectTableField(
    Uint8List bytes,
    int table,
    int fieldId,
  ) {
    final fieldOffset = _flatTableFieldOffset(bytes, table, fieldId);
    if (fieldOffset == 0) return null;
    final addr = table + fieldOffset;
    return _flatIndirectFromAddress(bytes, addr);
  }

  int? _flatIndirectFromAddress(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 4 > bytes.lengthInBytes) return null;
    final rel = ByteData.sublistView(bytes, addr, addr + 4)
        .getInt32(0, Endian.little);
    final target = addr + rel;
    if (target < 0 || target >= bytes.lengthInBytes) return null;
    return target;
  }

  int? _flatVectorFromAddress(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 4 > bytes.lengthInBytes) return null;
    final rel = ByteData.sublistView(bytes, addr, addr + 4)
        .getInt32(0, Endian.little);
    final vec = addr + rel;
    if (vec < 0 || vec + 4 > bytes.lengthInBytes) return null;
    return vec;
  }

  bool? _readFlatBool(Uint8List bytes, int addr) {
    final v = _readFlatUint8(bytes, addr);
    return v == null ? null : v != 0;
  }

  int? _readFlatInt8(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 1 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 1).getInt8(0);
  }

  int? _readFlatUint8(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 1 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 1).getUint8(0);
  }

  int? _readFlatInt16(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 2 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 2)
        .getInt16(0, Endian.little);
  }

  int? _readFlatUint16(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 2 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 2)
        .getUint16(0, Endian.little);
  }

  int? _readFlatInt32(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 4 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 4)
        .getInt32(0, Endian.little);
  }

  int? _readFlatUint32(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 4 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 4)
        .getUint32(0, Endian.little);
  }

  int? _readFlatInt64(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 8 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 8)
        .getInt64(0, Endian.little);
  }

  int? _readFlatUint64(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 8 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 8)
        .getUint64(0, Endian.little);
  }

  double? _readFlatFloat32(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 4 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 4)
        .getFloat32(0, Endian.little);
  }

  double? _readFlatFloat64(Uint8List bytes, int addr) {
    if (addr < 0 || addr + 8 > bytes.lengthInBytes) return null;
    return ByteData.sublistView(bytes, addr, addr + 8)
        .getFloat64(0, Endian.little);
  }

  String? _readFlatStringFromField(Uint8List bytes, int addr) {
    return _readFlatStringFromAddress(bytes, addr);
  }

  String? _readFlatStringFromAddress(Uint8List bytes, int addr) {
    final str = _flatIndirectFromAddress(bytes, addr);
    if (str == null || str + 4 > bytes.lengthInBytes) return null;
    final len = ByteData.sublistView(bytes, str, str + 4)
        .getUint32(0, Endian.little);
    final start = str + 4;
    final end = start + len;
    if (start < 0 || end > bytes.lengthInBytes) return null;
    return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  }

  Object? _decodeMessagePack(Uint8List bytes) {
    final result = _decodeMessagePackValue(bytes, 0);
    return result.$1;
  }

  (Object?, int) _decodeMessagePackValue(Uint8List bytes, int offset) {
    if (offset >= bytes.length) throw const FormatException('Unexpected EOF');
    final c = bytes[offset];
    if (c <= 0x7f) return (c, offset + 1);
    if (c >= 0xe0) return (c - 256, offset + 1);
    if ((c & 0xf0) == 0x90) {
      final size = c & 0x0f;
      var idx = offset + 1;
      final list = <Object?>[];
      for (var i = 0; i < size; i++) {
        final next = _decodeMessagePackValue(bytes, idx);
        list.add(next.$1);
        idx = next.$2;
      }
      return (list, idx);
    }
    if ((c & 0xf0) == 0x80) {
      final size = c & 0x0f;
      var idx = offset + 1;
      final map = <String, Object?>{};
      for (var i = 0; i < size; i++) {
        final k = _decodeMessagePackValue(bytes, idx);
        idx = k.$2;
        final v = _decodeMessagePackValue(bytes, idx);
        idx = v.$2;
        map[k.$1.toString()] = v.$1;
      }
      return (map, idx);
    }
    if ((c & 0xe0) == 0xa0) {
      final len = c & 0x1f;
      final s = utf8.decode(bytes.sublist(offset + 1, offset + 1 + len));
      return (s, offset + 1 + len);
    }

    switch (c) {
      case 0xc0:
        return (null, offset + 1);
      case 0xc2:
        return (false, offset + 1);
      case 0xc3:
        return (true, offset + 1);
      case 0xcc:
        return (bytes[offset + 1], offset + 2);
      case 0xcd:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 3)
              .getUint16(0, Endian.big),
          offset + 3,
        );
      case 0xce:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 5)
              .getUint32(0, Endian.big),
          offset + 5,
        );
      case 0xd0:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 2)
              .getInt8(0),
          offset + 2,
        );
      case 0xd1:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 3)
              .getInt16(0, Endian.big),
          offset + 3,
        );
      case 0xd2:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 5)
              .getInt32(0, Endian.big),
          offset + 5,
        );
      case 0xcb:
        return (
          ByteData.sublistView(bytes, offset + 1, offset + 9)
              .getFloat64(0, Endian.big),
          offset + 9,
        );
      case 0xda:
        final len = ByteData.sublistView(bytes, offset + 1, offset + 3)
            .getUint16(0, Endian.big);
        final s = utf8.decode(bytes.sublist(offset + 3, offset + 3 + len));
        return (s, offset + 3 + len);
      case 0xdc:
        final size = ByteData.sublistView(bytes, offset + 1, offset + 3)
            .getUint16(0, Endian.big);
        var idx = offset + 3;
        final list = <Object?>[];
        for (var i = 0; i < size; i++) {
          final next = _decodeMessagePackValue(bytes, idx);
          list.add(next.$1);
          idx = next.$2;
        }
        return (list, idx);
      case 0xde:
        final size = ByteData.sublistView(bytes, offset + 1, offset + 3)
            .getUint16(0, Endian.big);
        var idx = offset + 3;
        final map = <String, Object?>{};
        for (var i = 0; i < size; i++) {
          final k = _decodeMessagePackValue(bytes, idx);
          idx = k.$2;
          final v = _decodeMessagePackValue(bytes, idx);
          idx = v.$2;
          map[k.$1.toString()] = v.$1;
        }
        return (map, idx);
      default:
        throw FormatException('Unsupported MessagePack token 0x${c.toRadixString(16)}');
    }
  }

  Map<String, Object?> _decodeFlatBufferTable(Uint8List bytes) {
    if (bytes.lengthInBytes < 8) {
      throw const FormatException('FlatBuffer payload too short');
    }
    final rootOffset = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.little);
    if (rootOffset >= bytes.lengthInBytes) {
      throw const FormatException('Invalid FlatBuffer root offset');
    }
    final tablePos = rootOffset;
    final vtableOffset = ByteData.sublistView(bytes, tablePos, tablePos + 4)
        .getInt32(0, Endian.little);
    final vtablePos = tablePos - vtableOffset;
    if (vtablePos < 0 || vtablePos + 4 > bytes.lengthInBytes) {
      throw const FormatException('Invalid FlatBuffer vtable offset');
    }

    final view = ByteData.sublistView(bytes);
    final vtableSize = view.getUint16(vtablePos, Endian.little);
    final objectSize = view.getUint16(vtablePos + 2, Endian.little);
    final selectedTableSchema = _selectedFlatTableType == null
      ? null
      : _flatTableSchemas[_selectedFlatTableType!];
    final fields = selectedTableSchema == null
        ? _decodeFlatTableStructurally(bytes, tablePos, vtablePos)
        : _decodeFlatTableWithSchema(
            bytes,
            tablePos,
            selectedTableSchema,
          );

    final sequence = _extractSequence(fields);
    final stream = _extractStreamKey(fields);

    return {
      'protocol': 'flatbuffers-table',
      if (_selectedFlatTableType != null) 'schemaType': _selectedFlatTableType,
      'rootOffset': rootOffset,
      'tableOffset': tablePos,
      'vtableOffset': vtablePos,
      'vtableSize': vtableSize,
      'objectSize': objectSize,
      'fields': fields,
      if (sequence != null) 'sequence': sequence,
      if (stream != null && stream.isNotEmpty) 'stream': stream,
    };
  }

  Map<String, Object?> _decodeFlatTableStructurally(
    Uint8List bytes,
    int tablePos,
    int vtablePos,
  ) {
    final view = ByteData.sublistView(bytes);
    final vtableSize = view.getUint16(vtablePos, Endian.little);
    final fieldCount = ((vtableSize - 4) ~/ 2).clamp(0, 64);
    final fields = <String, Object?>{};
    for (var i = 0; i < fieldCount; i++) {
      final offsetInTable = view.getUint16(vtablePos + 4 + (i * 2), Endian.little);
      if (offsetInTable == 0) continue;
      final fieldPos = tablePos + offsetInTable;
      final baseName = _flatBufferFieldAliases[i] ?? 'field_$i';
      if (fieldPos + 8 <= bytes.lengthInBytes) {
        fields['$baseName.u64'] = view.getUint64(fieldPos, Endian.little);
        fields['$baseName.f64'] = view.getFloat64(fieldPos, Endian.little);
      } else if (fieldPos + 4 <= bytes.lengthInBytes) {
        fields['$baseName.u32'] = view.getUint32(fieldPos, Endian.little);
      }
    }
    return fields;
  }

  Map<String, Object?> _decodeFlatTableWithSchema(
    Uint8List bytes,
    int tablePos,
    _WsFlatObjectSchema schema,
  ) {
    final fields = <String, Object?>{};
    final entries = schema.fields.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      final field = entry.value;
      final value = _decodeFlatFieldValue(bytes, tablePos, field);
      if (value != null) {
        fields[field.name] = value;
      }
    }
    return fields;
  }

  Object? _decodeFlatFieldValue(
    Uint8List bytes,
    int tablePos,
    _WsFlatFieldSchema field,
  ) {
    final fieldOffset = _flatTableFieldOffset(bytes, tablePos, field.id);
    if (fieldOffset == 0) {
      return null;
    }
    final addr = tablePos + fieldOffset;
    if (addr < 0 || addr >= bytes.lengthInBytes) {
      return null;
    }

    switch (field.baseType) {
      case _kFlatBaseTypeBool:
        return _readFlatBool(bytes, addr);
      case _kFlatBaseTypeByte:
        return _readFlatInt8(bytes, addr);
      case _kFlatBaseTypeUByte:
      case _kFlatBaseTypeUType:
        return _readFlatUint8(bytes, addr);
      case _kFlatBaseTypeShort:
        return _readFlatInt16(bytes, addr);
      case _kFlatBaseTypeUShort:
        return _readFlatUint16(bytes, addr);
      case _kFlatBaseTypeInt:
        return _readFlatInt32(bytes, addr);
      case _kFlatBaseTypeUInt:
        return _readFlatUint32(bytes, addr);
      case _kFlatBaseTypeLong:
        return _readFlatInt64(bytes, addr);
      case _kFlatBaseTypeULong:
        return _readFlatUint64(bytes, addr);
      case _kFlatBaseTypeFloat:
        return _readFlatFloat32(bytes, addr);
      case _kFlatBaseTypeDouble:
        return _readFlatFloat64(bytes, addr);
      case _kFlatBaseTypeString:
        return _readFlatStringFromField(bytes, addr);
      case _kFlatBaseTypeVector:
        return _decodeFlatVector(bytes, addr, field);
      case _kFlatBaseTypeObj:
        return _decodeFlatObjectFromField(bytes, addr, field);
      case _kFlatBaseTypeUnion:
        return {'union': _readFlatUint8(bytes, addr)};
      default:
        return null;
    }
  }

  Object? _decodeFlatObjectFromField(
    Uint8List bytes,
    int addr,
    _WsFlatFieldSchema field,
  ) {
    final objectType = field.objectType;
    if (objectType == null) {
      return null;
    }
    final nestedSchema = _flatTableSchemas[objectType];
    if (nestedSchema == null) {
      final targetTable = _flatIndirectFromAddress(bytes, addr);
      return targetTable == null ? null : {'table': targetTable};
    }
    if (nestedSchema.isStruct) {
      return _decodeFlatStructWithSchema(bytes, addr, nestedSchema);
    }
    final targetTable = _flatIndirectFromAddress(bytes, addr);
    if (targetTable == null) {
      return null;
    }
    return _decodeFlatTableWithSchema(bytes, targetTable, nestedSchema);
  }

  Object? _decodeFlatVector(
    Uint8List bytes,
    int addr,
    _WsFlatFieldSchema field,
  ) {
    final vec = _flatVectorFromAddress(bytes, addr);
    if (vec == null) {
      return null;
    }
    final length = _flatVectorLength(bytes, vec);
    final start = vec + 4;
    final element = field.elementType;
    final out = <Object?>[];
    for (var i = 0; i < length; i++) {
      switch (element) {
        case _kFlatBaseTypeBool:
          out.add(_readFlatBool(bytes, start + i));
          break;
        case _kFlatBaseTypeByte:
          out.add(_readFlatInt8(bytes, start + i));
          break;
        case _kFlatBaseTypeUByte:
        case _kFlatBaseTypeUType:
          out.add(_readFlatUint8(bytes, start + i));
          break;
        case _kFlatBaseTypeShort:
          out.add(_readFlatInt16(bytes, start + (i * 2)));
          break;
        case _kFlatBaseTypeUShort:
          out.add(_readFlatUint16(bytes, start + (i * 2)));
          break;
        case _kFlatBaseTypeInt:
          out.add(_readFlatInt32(bytes, start + (i * 4)));
          break;
        case _kFlatBaseTypeUInt:
          out.add(_readFlatUint32(bytes, start + (i * 4)));
          break;
        case _kFlatBaseTypeFloat:
          out.add(_readFlatFloat32(bytes, start + (i * 4)));
          break;
        case _kFlatBaseTypeLong:
          out.add(_readFlatInt64(bytes, start + (i * 8)));
          break;
        case _kFlatBaseTypeULong:
          out.add(_readFlatUint64(bytes, start + (i * 8)));
          break;
        case _kFlatBaseTypeDouble:
          out.add(_readFlatFloat64(bytes, start + (i * 8)));
          break;
        case _kFlatBaseTypeString:
          out.add(_readFlatStringFromAddress(bytes, start + (i * 4)));
          break;
        case _kFlatBaseTypeObj:
          final objName = field.objectType;
          final nested = objName == null ? null : _flatTableSchemas[objName];
          if (nested == null) {
            out.add(_flatIndirectFromAddress(bytes, start + (i * 4)));
          } else if (nested.isStruct) {
            final structSize = nested.byteSize <= 0 ? 1 : nested.byteSize;
            out.add(_decodeFlatStructWithSchema(bytes, start + (i * structSize), nested));
          } else {
            final table = _flatIndirectFromAddress(bytes, start + (i * 4));
            if (table == null) {
              out.add(null);
            } else {
              out.add(_decodeFlatTableWithSchema(bytes, table, nested));
            }
          }
          break;
        default:
          out.add(null);
          break;
      }
    }
    return out;
  }

  Map<String, Object?> _decodeFlatStructWithSchema(
    Uint8List bytes,
    int structPos,
    _WsFlatObjectSchema schema,
  ) {
    final fields = <String, Object?>{};
    final entries = schema.fields.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      final field = entry.value;
      final value = _decodeFlatStructFieldValue(bytes, structPos, field);
      if (value != null) {
        fields[field.name] = value;
      }
    }
    return fields;
  }

  Object? _decodeFlatStructFieldValue(
    Uint8List bytes,
    int structPos,
    _WsFlatFieldSchema field,
  ) {
    final addr = structPos + (field.offset ?? field.id);
    switch (field.baseType) {
      case _kFlatBaseTypeBool:
        return _readFlatBool(bytes, addr);
      case _kFlatBaseTypeByte:
        return _readFlatInt8(bytes, addr);
      case _kFlatBaseTypeUByte:
      case _kFlatBaseTypeUType:
        return _readFlatUint8(bytes, addr);
      case _kFlatBaseTypeShort:
        return _readFlatInt16(bytes, addr);
      case _kFlatBaseTypeUShort:
        return _readFlatUint16(bytes, addr);
      case _kFlatBaseTypeInt:
        return _readFlatInt32(bytes, addr);
      case _kFlatBaseTypeUInt:
        return _readFlatUint32(bytes, addr);
      case _kFlatBaseTypeLong:
        return _readFlatInt64(bytes, addr);
      case _kFlatBaseTypeULong:
        return _readFlatUint64(bytes, addr);
      case _kFlatBaseTypeFloat:
        return _readFlatFloat32(bytes, addr);
      case _kFlatBaseTypeDouble:
        return _readFlatFloat64(bytes, addr);
      default:
        return null;
    }
  }

  _WsQuoteEvent _decodeFixedQuote(Uint8List bytes) {
    if (bytes.lengthInBytes < 56) {
      throw FormatException('Quote frame too short: ${bytes.lengthInBytes} < 56');
    }
    final view = ByteData.sublistView(bytes, 0, 56);
    return _WsQuoteEvent(
      sequence: view.getUint64(0, Endian.little),
      timestampMicros: view.getUint64(8, Endian.little),
      symbol: _decodeAsciiSymbol(bytes.sublist(16, 24)),
      bid: view.getFloat64(24, Endian.little),
      ask: view.getFloat64(32, Endian.little),
      bidSize: view.getFloat64(40, Endian.little),
      askSize: view.getFloat64(48, Endian.little),
    );
  }

  _WsTradeEvent _decodeFixedTrade(Uint8List bytes) {
    if (bytes.lengthInBytes < 41) {
      throw FormatException('Trade frame too short: ${bytes.lengthInBytes} < 41');
    }
    final view = ByteData.sublistView(bytes, 0, 41);
    return _WsTradeEvent(
      sequence: view.getUint64(0, Endian.little),
      timestampMicros: view.getUint64(8, Endian.little),
      symbol: _decodeAsciiSymbol(bytes.sublist(16, 24)),
      price: view.getFloat64(24, Endian.little),
      size: view.getFloat64(32, Endian.little),
      side: (view.getUint8(40) == 0) ? 'buy' : 'sell',
    );
  }

  _WsOrderBookEvent _decodeFixedOrderBook(Uint8List bytes) {
    if (bytes.lengthInBytes < 56) {
      throw FormatException('OrderBook frame too short: ${bytes.lengthInBytes} < 56');
    }
    final view = ByteData.sublistView(bytes, 0, 56);
    return _WsOrderBookEvent(
      sequence: view.getUint64(0, Endian.little),
      timestampMicros: view.getUint64(8, Endian.little),
      symbol: _decodeAsciiSymbol(bytes.sublist(16, 24)),
      bidPrice: view.getFloat64(24, Endian.little),
      bidSize: view.getFloat64(32, Endian.little),
      askPrice: view.getFloat64(40, Endian.little),
      askSize: view.getFloat64(48, Endian.little),
    );
  }

  String _decodeAsciiSymbol(Uint8List bytes) {
    final chars = bytes.takeWhile((b) => b != 0).toList(growable: false);
    return ascii.decode(chars).trim();
  }

  Object _bestEffortPayload(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes);
      if (text.isEmpty) return '';
      try {
        return jsonDecode(text);
      } catch (_) {
        return text;
      }
    } catch (_) {
      return _toHex(bytes);
    }
  }

  int? _extractSequence(Object? value) {
    if (value is Map) {
      final direct = value['sequence'];
      if (direct is num) return direct.toInt();
      final seq = value['seq'];
      if (seq is num) return seq.toInt();
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (key.contains('sequence') || key == 'seq') {
          final v = entry.value;
          if (v is num) return v.toInt();
          if (v is String) {
            final parsed = int.tryParse(v);
            if (parsed != null) return parsed;
          }
        }
      }
      final nested = value['fields'];
      if (nested is Map) {
        return _extractSequence(nested);
      }
    }
    return null;
  }

  String? _extractStreamKey(Object? value) {
    if (value is Map) {
      final s = value['symbol'] ?? value['stream'] ?? value['channel'];
      if (s != null) return s.toString();
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (key.contains('symbol') ||
            key.contains('instrument') ||
            key.contains('stream') ||
            key.contains('channel')) {
          final v = entry.value;
          if (v != null && v.toString().isNotEmpty) {
            return v.toString();
          }
        }
      }
      final nested = value['fields'];
      if (nested is Map) {
        return _extractStreamKey(nested);
      }
    }
    return null;
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

  String _payloadForDisplay(WebSocketMessage msg) {
    if (msg.type == 'binary') {
      final bytes = msg.binaryPayload;
      if (bytes == null) return '';
      return _toHex(bytes);
    }
    return msg.textPayload ?? '';
  }

  String _payloadForComposer(WebSocketMessage msg) {
    if (msg.type == 'binary') {
      final bytes = msg.binaryPayload;
      return bytes == null ? '' : base64Encode(bytes);
    }
    return msg.textPayload ?? '';
  }

  bool _samePayload(WebSocketMessage a, WebSocketMessage b) {
    if (a.type != b.type) return false;
    if (a.type == 'binary') {
      final ab = a.binaryPayload;
      final bb = b.binaryPayload;
      if (ab == null || bb == null || ab.lengthInBytes != bb.lengthInBytes) {
        return false;
      }
      for (var i = 0; i < ab.lengthInBytes; i++) {
        if (ab[i] != bb[i]) return false;
      }
      return true;
    }
    return (a.textPayload ?? '') == (b.textPayload ?? '');
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
      .map((m) => m.sizeBytes ?? m.binaryPayload?.lengthInBytes ?? (m.textPayload ?? '').length)
        .fold<int>(0, (a, b) => a + b);
    final msgRate = durationSecs <= 0
        ? '--'
        : (total / durationSecs).toStringAsFixed(2);
    final throughput = durationSecs <= 0
        ? '--'
        : '${(totalBytes / durationSecs).toStringAsFixed(1)} B/s';
    final spike = session.messages.isEmpty
        ? '--'
      : '${session.messages.map((m) => m.sizeBytes ?? m.binaryPayload?.lengthInBytes ?? (m.textPayload ?? '').length).reduce((a, b) => a > b ? a : b)} B';
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
    required this.sequence,
    required this.streamKey,
    required this.jsonError,
    required this.onResend,
    required this.onCopy,
    required this.onDuplicate,
  });
  final WebSocketMessage message;
  final int index;
  final int repeatCount;
  final String renderedPayload;
  final int? sequence;
  final String? streamKey;
  final String? jsonError;
  final VoidCallback onResend;
  final VoidCallback onCopy;
  final VoidCallback onDuplicate;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  int _messageBytesLength(WebSocketMessage msg) {
    if (msg.sizeBytes != null) return msg.sizeBytes!;
    if (msg.binaryPayload != null) return msg.binaryPayload!.lengthInBytes;
    return (msg.textPayload ?? '').length;
  }

  String _rawPayloadForSection(WebSocketMessage msg) {
    if (msg.type == 'binary') {
      final bytes = msg.binaryPayload;
      if (bytes == null) return '';
      final b = StringBuffer();
      for (var i = 0; i < bytes.lengthInBytes; i++) {
        if (i > 0) b.write(' ');
        b.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      }
      return b.toString();
    }
    return msg.textPayload ?? '';
  }

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
            if (widget.streamKey != null) ...[
              const SizedBox(width: 8),
              Text(widget.streamKey!, style: Theme.of(context).textTheme.labelSmall),
            ],
            if (widget.sequence != null) ...[
              const SizedBox(width: 8),
              Text('seq:${widget.sequence}',
                  style: Theme.of(context).textTheme.labelSmall),
            ],
            const Spacer(),
            Text(
              _formatTime(msg.timestamp),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(width: 8),
            Text(
              '${_messageBytesLength(msg)} B',
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
                'Size: ${_messageBytesLength(msg)} B',
          ),
          const SizedBox(height: 6),
              _section(context, 'Raw payload', _rawPayloadForSection(msg)),
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
