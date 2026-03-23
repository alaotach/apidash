import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash_design_system/apidash_design_system.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/providers/providers.dart';
import 'package:apidash/providers/websocket_providers.dart';

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
  final _msgFocusNode = FocusNode();
  final _scrollController = ScrollController();

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
    _urlController.dispose();
    _msgController.dispose();
    _msgFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSocketNotifierProvider);
    final notifier = ref.read(webSocketNotifierProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    ref.listen(selectedIdStateProvider, (previous, next) {
      if (previous != next) {
        final requestModel = ref.read(selectedRequestModelProvider);
        final url = requestModel?.httpRequestModel?.url;
        _urlController.text = (url != null && url.isNotEmpty) ? url : '';
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
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

        // ── Message timeline ─────────────────────────────────────
        Expanded(
          child: session.messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded,
                          size: 48,
                          color: colorScheme.onSurface.withAlpha(80)),
                      const SizedBox(height: 8),
                      Text(
                        'Connect and send a message to see the timeline',
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
                  itemCount: session.messages.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final msg = session.messages[i];
                    return _MessageRow(message: msg, index: i + 1);
                  },
                ),
        ),

        // ── Message composer ────────────────────────────────────
        if (session.isConnected)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    focusNode: _msgFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText: 'Enter text payload',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(notifier),
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
          ),
      ],
    );
  }

  void _sendMessage(WebSocketNotifier notifier) {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    notifier.sendMessage(text);
    final url = _normalizeWebSocketUrl(_urlController.text.trim());
    ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
      apiType: APIType.websocket,
      url: url,
      method: HTTPVerb.post,
      requestBody: text,
      responseStatus: 200,
      message: 'WebSocket message sent',
      responseBody: text,
    );
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
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _StatChip(label: 'Total', value: '$total', icon: Icons.swap_horiz),
          _StatChip(
              label: '↑ Sent', value: '$sent', icon: Icons.arrow_upward),
          _StatChip(
              label: '↓ Received',
              value: '$received',
              icon: Icons.arrow_downward),
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
  const _MessageRow({required this.message, required this.index});
  final WebSocketMessage message;
  final int index;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final colorScheme = Theme.of(context).colorScheme;
    final isSent = msg.isSent;

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Index
                SizedBox(
                  width: 32,
                  child: Text(
                    '#${widget.index}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                // Direction badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isSent
                        ? colorScheme.primaryContainer
                        : colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isSent ? '↑ SENT' : '↓ RECV',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isSent
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Type chip
                Chip(
                  label: Text(msg.type.toUpperCase()),
                  padding: EdgeInsets.zero,
                  labelPadding:
                      const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 8),
                // Timestamp
                Text(
                  _formatTime(msg.timestamp),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const Spacer(),
                if (msg.sizeBytes != null)
                  Text(
                    '${msg.sizeBytes} B',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 16,
                ),
              ],
            ),
            // Payload (collapsed: preview, expanded: full)
            const SizedBox(height: 4),
            Text(
              _expanded
                  ? msg.payload
                  : msg.payload.length > 120
                      ? '${msg.payload.substring(0, 120)}…'
                      : msg.payload,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurface.withAlpha(180),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}
