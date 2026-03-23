import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash_design_system/apidash_design_system.dart';
import 'package:apidash/providers/providers.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/providers/mqtt_providers.dart';

class EditMqttRequestPane extends ConsumerStatefulWidget {
  const EditMqttRequestPane({super.key});

  @override
  ConsumerState<EditMqttRequestPane> createState() =>
      _EditMqttRequestPaneState();
}

class _EditMqttRequestPaneState extends ConsumerState<EditMqttRequestPane>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Connection form controllers
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '1883');
  final _clientIdCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  // Publish form controllers
  final _pubTopicCtrl = TextEditingController();
  final _pubPayloadCtrl = TextEditingController();
  int _pubQos = 0;
  bool _pubRetain = false;

  // Subscribe form
  final _subTopicCtrl = TextEditingController();
  int _subQos = 0;

  bool _useTls = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _clientIdCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pubTopicCtrl.dispose();
    _pubPayloadCtrl.dispose();
    _subTopicCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(mqttNotifierProvider);
    final notifier = ref.read(mqttNotifierProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // ── Connection status bar ───────────────────────────
        _ConnectionBar(
          session: session,
          onConnect: () => _connect(notifier),
          onDisconnect: notifier.disconnect,
        ),

        if (session.error != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(session.error!,
                style:
                    TextStyle(color: colorScheme.onErrorContainer)),
          ),

        // ── Tab bar ───────────────────────────────────────────
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Connection'),
            Tab(text: 'Publish'),
            Tab(text: 'Subscribe'),
          ],
        ),

        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _ConnectionTab(
                hostCtrl: _hostCtrl,
                portCtrl: _portCtrl,
                clientIdCtrl: _clientIdCtrl,
                userCtrl: _userCtrl,
                passCtrl: _passCtrl,
                useTls: _useTls,
                onTlsChanged: (v) => setState(() => _useTls = v),
                enabled: !session.isConnected,
              ),
              _PublishTab(
                topicCtrl: _pubTopicCtrl,
                payloadCtrl: _pubPayloadCtrl,
                qos: _pubQos,
                retain: _pubRetain,
                enabled: session.isConnected,
                onQosChanged: (v) =>
                    setState(() => _pubQos = v ?? 0),
                onRetainChanged: (v) =>
                    setState(() => _pubRetain = v),
                onPublish: () => _publish(notifier),
              ),
              _SubscribeTab(
                topicCtrl: _subTopicCtrl,
                qos: _subQos,
                subscribedTopics: session.subscribedTopics,
                enabled: session.isConnected,
                onQosChanged: (v) =>
                    setState(() => _subQos = v ?? 0),
                onSubscribe: () {
                  final t = _subTopicCtrl.text.trim();
                  if (t.isNotEmpty) {
                    notifier.subscribe(t, qos: _subQos);
                    final baseUrl = _mqttUrl;
                    ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
                      apiType: APIType.mqtt,
                      url: '$baseUrl/$t',
                      method: HTTPVerb.get,
                      requestHeaders: [
                        const NameValueModel(name: 'mqtt.action', value: 'SUB'),
                        NameValueModel(name: 'mqtt.topic', value: t),
                        NameValueModel(name: 'mqtt.qos', value: '$_subQos'),
                      ],
                      responseStatus: 200,
                      message: 'Subscribed to topic',
                      responseBody: 'Subscribed topic: $t (QoS $_subQos)',
                    );
                  }
                },
                onUnsubscribe: notifier.unsubscribe,
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // ── Message log ─────────────────────────────────────
        Expanded(
          child: _MessageLog(messages: session.messageLog),
        ),
      ],
    );
  }

  void _connect(MqttNotifier notifier) {
    final model = MqttRequestModel(
      brokerHost: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text) ?? 1883,
      clientId: _clientIdCtrl.text.trim(),
      username:
          _userCtrl.text.trim().isEmpty ? null : _userCtrl.text.trim(),
      password:
          _passCtrl.text.isEmpty ? null : _passCtrl.text,
      useTls: _useTls,
    );
    notifier.connect(model).then((_) {
      final session = ref.read(mqttNotifierProvider);
      final baseUrl = _mqttUrl;
      ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
        apiType: APIType.mqtt,
        url: baseUrl,
        method: HTTPVerb.get,
        requestHeaders: [
          const NameValueModel(name: 'mqtt.action', value: 'CONNECT'),
          NameValueModel(name: 'mqtt.clientId', value: model.clientId),
          NameValueModel(name: 'mqtt.tls', value: model.useTls.toString()),
        ],
        responseStatus: session.isConnected ? 200 : -1,
        message: session.isConnected
            ? 'MQTT connected'
            : (session.error ?? 'MQTT connection failed'),
        responseBody: session.error,
      );
    });
  }

  void _publish(MqttNotifier notifier) {
    final topic = _pubTopicCtrl.text.trim();
    if (topic.isEmpty) {
      return;
    }
    final payload = _pubPayloadCtrl.text;
    notifier.publish(
      topic,
      payload,
      qos: _pubQos,
      retain: _pubRetain,
    );

    final baseUrl = _mqttUrl;
    ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
      apiType: APIType.mqtt,
      url: '$baseUrl/$topic',
      method: HTTPVerb.post,
      requestHeaders: [
        const NameValueModel(name: 'mqtt.action', value: 'PUB'),
        NameValueModel(name: 'mqtt.topic', value: topic),
        NameValueModel(name: 'mqtt.qos', value: '$_pubQos'),
        NameValueModel(name: 'mqtt.retain', value: _pubRetain.toString()),
      ],
      requestBody: payload,
      responseStatus: 200,
      message: 'MQTT message published',
      responseBody: payload,
    );
  }

  String get _mqttUrl {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text) ?? 1883;
    final scheme = _useTls ? 'mqtts' : 'mqtt';
    return '$scheme://$host:$port';
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.session,
    required this.onConnect,
    required this.onDisconnect,
  });

  final MqttSessionState session;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected = session.isConnected;
    final isConnecting =
        session.connectionState == MqttClientConnectionState.connecting;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: isConnected
                ? Colors.green
                : isConnecting
                    ? Colors.orange
                    : colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Text(
            isConnected
                ? 'Connected'
                : isConnecting
                    ? 'Connecting…'
                    : 'Disconnected',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const Spacer(),
          if (isConnecting)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (isConnected)
            FilledButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('Disconnect'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
              ),
            )
          else
            FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.link_rounded, size: 16),
              label: const Text('Connect'),
            ),
        ],
      ),
    );
  }
}

class _ConnectionTab extends StatelessWidget {
  const _ConnectionTab({
    required this.hostCtrl,
    required this.portCtrl,
    required this.clientIdCtrl,
    required this.userCtrl,
    required this.passCtrl,
    required this.useTls,
    required this.onTlsChanged,
    required this.enabled,
  });

  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final TextEditingController clientIdCtrl;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final bool useTls;
  final ValueChanged<bool> onTlsChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: hostCtrl,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    labelText: 'Broker Host',
                    hintText: 'broker.hivemq.com',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: portCtrl,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: clientIdCtrl,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Client ID',
              hintText: 'Leave blank to auto-generate',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: userCtrl,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    labelText: 'Username (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: passCtrl,
                  enabled: enabled,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: useTls,
            onChanged: enabled ? onTlsChanged : null,
            title: const Text('Use TLS'),
            subtitle: const Text('Connect over mqtts://'),
          ),
        ],
      ),
    );
  }
}

class _PublishTab extends StatelessWidget {
  const _PublishTab({
    required this.topicCtrl,
    required this.payloadCtrl,
    required this.qos,
    required this.retain,
    required this.enabled,
    required this.onQosChanged,
    required this.onRetainChanged,
    required this.onPublish,
  });

  final TextEditingController topicCtrl;
  final TextEditingController payloadCtrl;
  final int qos;
  final bool retain;
  final bool enabled;
  final ValueChanged<int?> onQosChanged;
  final ValueChanged<bool> onRetainChanged;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: topicCtrl,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Topic',
              hintText: 'sensor/temperature',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text('QoS Level',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('0 – At most once')),
              ButtonSegment(value: 1, label: Text('1 – At least once')),
              ButtonSegment(value: 2, label: Text('2 – Exactly once')),
            ],
            selected: {qos},
            onSelectionChanged: enabled
                ? (s) => onQosChanged(s.first)
                : null,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: retain,
            onChanged: enabled ? onRetainChanged : null,
            title: const Text('Retain'),
            subtitle:
                const Text('Broker stores last message for this topic'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: payloadCtrl,
            enabled: enabled,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Payload',
              hintText: '{"value": 42}',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: enabled ? onPublish : null,
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Publish'),
          ),
        ],
      ),
    );
  }
}

class _SubscribeTab extends StatelessWidget {
  const _SubscribeTab({
    required this.topicCtrl,
    required this.qos,
    required this.subscribedTopics,
    required this.enabled,
    required this.onQosChanged,
    required this.onSubscribe,
    required this.onUnsubscribe,
  });

  final TextEditingController topicCtrl;
  final int qos;
  final List<String> subscribedTopics;
  final bool enabled;
  final ValueChanged<int?> onQosChanged;
  final VoidCallback onSubscribe;
  final ValueChanged<String> onUnsubscribe;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: topicCtrl,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    labelText: 'Topic filter',
                    hintText: 'sensor/# or home/+/temperature',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: enabled ? onSubscribe : null,
                child: const Text('Subscribe'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('QoS Level',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('QoS 0')),
              ButtonSegment(value: 1, label: Text('QoS 1')),
              ButtonSegment(value: 2, label: Text('QoS 2')),
            ],
            selected: {qos},
            onSelectionChanged: enabled
                ? (s) => onQosChanged(s.first)
                : null,
          ),
          const SizedBox(height: 16),
          if (subscribedTopics.isNotEmpty) ...[
            Text('Active Subscriptions',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: subscribedTopics
                  .map(
                    (t) => Chip(
                      label: Text(t),
                      deleteIcon:
                          const Icon(Icons.close, size: 16),
                      onDeleted:
                          enabled ? () => onUnsubscribe(t) : null,
                    ),
                  )
                  .toList(),
            ),
          ] else
            Text(
              'No active subscriptions',
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(100)),
            ),
        ],
      ),
    );
  }
}

class _MessageLog extends StatelessWidget {
  const _MessageLog({required this.messages});
  final List<MqttMessage> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet',
          style: TextStyle(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withAlpha(100)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: messages.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final msg = messages[i];
        final colorScheme = Theme.of(ctx).colorScheme;
        final isPub = msg.isSent;
        return ListTile(
          dense: true,
          leading: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isPub
                  ? colorScheme.primaryContainer
                  : colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isPub ? '↑ PUB' : '↓ SUB',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isPub
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          title: Text(msg.topic,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            msg.payload.length > 80
                ? '${msg.payload.substring(0, 80)}…'
                : msg.payload,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _QosBadge(qos: msg.qos),
              Text(
                '${msg.sizeBytes} B',
                style: Theme.of(ctx).textTheme.labelSmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QosBadge extends StatelessWidget {
  const _QosBadge({required this.qos});
  final int qos;

  @override
  Widget build(BuildContext context) {
    final color = switch (qos) {
      0 => Colors.grey,
      1 => Colors.blue,
      2 => Colors.green,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'QoS $qos',
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
