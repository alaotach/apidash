import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash/providers/providers.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/providers/mqtt_providers.dart';

enum _MqttStreamTypeFilter { all, sent, received }

class EditMqttRequestPane extends ConsumerStatefulWidget {
  const EditMqttRequestPane({super.key});

  @override
  ConsumerState<EditMqttRequestPane> createState() =>
      _EditMqttRequestPaneState();
}

class _EditMqttRequestPaneState extends ConsumerState<EditMqttRequestPane> {

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
  MqttProtocolVersion _protocolVersion = MqttProtocolVersion.v311;
  String? _selectedTopicFilter;
  bool _showConnectionDetails = true;
  bool _isLeftCollapsed = false;
  bool _isPublishCollapsed = false;
  bool _isStreamCollapsed = false;
  double _leftWidth = 420;
  double _centerWidth = 320;
  bool _leftDividerHovered = false;
  bool _centerDividerHovered = false;
  final _streamSearchCtrl = TextEditingController();
  _MqttStreamTypeFilter _streamTypeFilter = _MqttStreamTypeFilter.all;
  String? _selectedPayloadTemplate;
  bool _isHydratingDraft = false;

  static const Map<String, String> _payloadTemplates = {
    'JSON object': '{\n  "device": "sensor-01",\n  "value": 42\n}',
    'JSON event': '{\n  "event": "heartbeat",\n  "ts": "2026-01-01T00:00:00Z"\n}',
    'Plain text': 'hello mqtt',
  };

  @override
  void initState() {
    super.initState();
    _hostCtrl.addListener(_onConnectionDraftFieldChanged);
    _portCtrl.addListener(_onConnectionDraftFieldChanged);
    _clientIdCtrl.addListener(_onConnectionDraftFieldChanged);
    _userCtrl.addListener(_onConnectionDraftFieldChanged);
    _passCtrl.addListener(_onConnectionDraftFieldChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadDraftFromSelectedRequest();
    });
  }

  @override
  void dispose() {
    _hostCtrl.removeListener(_onConnectionDraftFieldChanged);
    _portCtrl.removeListener(_onConnectionDraftFieldChanged);
    _clientIdCtrl.removeListener(_onConnectionDraftFieldChanged);
    _userCtrl.removeListener(_onConnectionDraftFieldChanged);
    _passCtrl.removeListener(_onConnectionDraftFieldChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _clientIdCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pubTopicCtrl.dispose();
    _pubPayloadCtrl.dispose();
    _subTopicCtrl.dispose();
    _streamSearchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedIdStateProvider, (previous, next) {
      if (previous != next) {
        _loadDraftFromSelectedRequest();
      }
    });

    final session = ref.watch(mqttNotifierProvider);
    final notifier = ref.read(mqttNotifierProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final topicCounts = _buildTopicCounts(session.messageLog);
    final topicRates = _buildTopicRates(session.messageLog);
    final topicLastActivity = _buildTopicLastActivity(session.messageLog);
    final lastSent = _lastSentMessage(session.messageLog);
    final filteredMessages = _filteredMessages(session.messageLog);

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
        _MqttMetricsBar(
          session: session,
          messages: session.messageLog,
        ),

        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const collapsedWidth = 36.0;
                const dividerWidth = 8.0;
                final leftExpanded = !_isLeftCollapsed;
                final centerExpanded = !_isPublishCollapsed;
                final streamExpanded = !_isStreamCollapsed;
                final collapsedCount = [leftExpanded, centerExpanded, streamExpanded]
                    .where((expanded) => !expanded)
                    .length;
                final dividerCount = (leftExpanded ? 1 : 0) +
                    ((centerExpanded && streamExpanded) ? 1 : 0);
                final availableForExpanded = (constraints.maxWidth -
                        (collapsedCount * collapsedWidth) -
                        (dividerCount * dividerWidth))
                    .clamp(0.0, double.infinity);
                const streamPreferredMinWidth = 220.0;
                final leftDesired =
                  leftExpanded ? _leftWidth.clamp(180.0, 460.0).toDouble() : 0.0;
                final centerDesired = centerExpanded
                  ? _centerWidth.clamp(220.0, 560.0).toDouble()
                  : 0.0;

                final nonStreamDesired = leftDesired + centerDesired;
                double leftPaneWidth = 0.0;
                double centerPaneWidth = 0.0;
                double streamPaneWidth = 0.0;

                if (streamExpanded) {
                  final targetForNonStream =
                    (availableForExpanded - streamPreferredMinWidth)
                      .clamp(0.0, availableForExpanded);
                  final nonStreamScale = nonStreamDesired <= 0
                    ? 0.0
                    : (nonStreamDesired <= targetForNonStream
                      ? 1.0
                      : (targetForNonStream / nonStreamDesired));
                  leftPaneWidth = leftDesired * nonStreamScale;
                  centerPaneWidth = centerDesired * nonStreamScale;
                  streamPaneWidth =
                    (availableForExpanded - leftPaneWidth - centerPaneWidth)
                      .clamp(0.0, double.infinity);
                } else {
                  final nonStreamScale = nonStreamDesired <= 0
                    ? 0.0
                    : (nonStreamDesired <= availableForExpanded
                      ? 1.0
                      : (availableForExpanded / nonStreamDesired));
                  leftPaneWidth = leftDesired * nonStreamScale;
                  centerPaneWidth = centerDesired * nonStreamScale;
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (leftExpanded)
                      SizedBox(
                        width: leftPaneWidth,
                        child: Card(
                          child: Column(
                            children: [
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.settings_ethernet_rounded),
                                title: const Text('Connection + Topics'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (session.isConnected)
                                      IconButton(
                                        tooltip: _showConnectionDetails
                                            ? 'Collapse details'
                                            : 'Expand details',
                                        onPressed: () {
                                          setState(() {
                                            _showConnectionDetails =
                                                !_showConnectionDetails;
                                          });
                                        },
                                        icon: Icon(
                                          _showConnectionDetails
                                              ? Icons.unfold_less_rounded
                                              : Icons.unfold_more_rounded,
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: 'Collapse pane',
                                      onPressed: () {
                                        setState(() {
                                          _isLeftCollapsed = true;
                                        });
                                      },
                                      icon: const Icon(Icons.chevron_left_rounded),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: ListView(
                                  children: [
                                    if (!session.isConnected ||
                                        _showConnectionDetails)
                                      _ConnectionTab(
                                        hostCtrl: _hostCtrl,
                                        portCtrl: _portCtrl,
                                        clientIdCtrl: _clientIdCtrl,
                                        userCtrl: _userCtrl,
                                        passCtrl: _passCtrl,
                                        useTls: _useTls,
                                        protocolVersion: _protocolVersion,
                                        onTlsChanged: (v) =>
                                            setState(() {
                                              _useTls = v;
                                              _persistMqttDraft();
                                            }),
                                        onProtocolVersionChanged: (v) =>
                                            setState(() {
                                              _protocolVersion = v;
                                              _persistMqttDraft();
                                            }),
                                        enabled: !session.isConnected,
                                      )
                                    else
                                      Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(
                                          'Connection details collapsed. Stream and publish panes expanded for active debugging.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ),
                                    const Divider(height: 1),
                                    _SubscribeTab(
                                      topicCtrl: _subTopicCtrl,
                                      qos: _subQos,
                                      subscribedTopics: session.subscribedTopics,
                                      topicCounts: topicCounts,
                                      topicRates: topicRates,
                                      topicLastActivity: topicLastActivity,
                                      selectedTopic: _selectedTopicFilter,
                                      enabled: session.isConnected,
                                      onTopicSelected: (topic) {
                                        setState(() => _selectedTopicFilter = topic);
                                      },
                                      onQosChanged: (v) =>
                                          setState(() => _subQos = v ?? 0),
                                      onSubscribe: () {
                                        final t = _subTopicCtrl.text.trim();
                                        if (t.isNotEmpty) {
                                          notifier.subscribe(t, qos: _subQos);
                                          final baseUrl = _mqttUrl;
                                          ref
                                              .read(collectionStateNotifierProvider
                                                  .notifier)
                                              .logProtocolRequest(
                                                apiType: APIType.mqtt,
                                                url: '$baseUrl/$t',
                                                method: HTTPVerb.get,
                                                requestHeaders: [
                                                  const NameValueModel(
                                                    name: 'mqtt.action',
                                                    value: 'SUB',
                                                  ),
                                                  NameValueModel(
                                                    name: 'mqtt.topic',
                                                    value: t,
                                                  ),
                                                  NameValueModel(
                                                    name: 'mqtt.qos',
                                                    value: '$_subQos',
                                                  ),
                                                ],
                                                responseStatus: 200,
                                                message: 'Subscribed to topic',
                                                responseBody:
                                                    'Subscribed topic: $t (QoS $_subQos)',
                                              );
                                        }
                                      },
                                      onUnsubscribe: (topic) {
                                        notifier.unsubscribe(topic);
                                        if (_selectedTopicFilter == topic) {
                                          setState(() => _selectedTopicFilter = null);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: collapsedWidth,
                        child: Center(
                          child: IconButton(
                            tooltip: 'Expand connection pane',
                            onPressed: () => setState(() => _isLeftCollapsed = false),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ),
                      ),
                    if (leftExpanded)
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        onEnter: (_) => setState(() => _leftDividerHovered = true),
                        onExit: (_) => setState(() => _leftDividerHovered = false),
                        child: GestureDetector(
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              _leftWidth = (_leftWidth + details.delta.dx)
                                  .clamp(180.0, 460.0);
                            });
                          },
                          child: Container(
                            width: dividerWidth,
                            color: _leftDividerHovered
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withAlpha(80)
                                : Colors.transparent,
                            child: VerticalDivider(
                              width: 1,
                              color: _leftDividerHovered
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                            ),
                          ),
                        ),
                      ),
                    if (centerExpanded)
                      SizedBox(
                        width: centerPaneWidth,
                        child: Card(
                          child: Column(
                            children: [
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.upload_rounded),
                                title: const Text('Publish'),
                                trailing: IconButton(
                                  tooltip: 'Collapse pane',
                                  onPressed: () =>
                                      setState(() => _isPublishCollapsed = true),
                                  icon: const Icon(Icons.chevron_left_rounded),
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: _PublishTab(
                                  topicCtrl: _pubTopicCtrl,
                                  payloadCtrl: _pubPayloadCtrl,
                                  qos: _pubQos,
                                  retain: _pubRetain,
                                  enabled: session.isConnected,
                                  templates:
                                      _payloadTemplates.entries.toList(growable: false),
                                  selectedTemplate: _selectedPayloadTemplate,
                                  hasLastSent: lastSent != null,
                                  onTemplateChanged: (name) {
                                    setState(() => _selectedPayloadTemplate = name);
                                    if (name == null) return;
                                    final payloadTemplate = _payloadTemplates[name];
                                    if (payloadTemplate != null) {
                                      _pubPayloadCtrl.text = payloadTemplate;
                                    }
                                  },
                                  onUseLastSent: () {
                                    if (lastSent == null) return;
                                    _pubTopicCtrl.text = lastSent.topic;
                                    _pubPayloadCtrl.text = lastSent.payload;
                                    setState(() {
                                      _pubQos = lastSent.qos;
                                      _pubRetain = lastSent.retain;
                                    });
                                  },
                                  onQosChanged: (v) =>
                                      setState(() => _pubQos = v ?? 0),
                                  onRetainChanged: (v) =>
                                      setState(() => _pubRetain = v),
                                  onPublish: () => _publish(notifier),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: collapsedWidth,
                        child: Center(
                          child: IconButton(
                            tooltip: 'Expand publish pane',
                            onPressed: () =>
                                setState(() => _isPublishCollapsed = false),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ),
                      ),
                    if (centerExpanded && streamExpanded)
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        onEnter: (_) =>
                            setState(() => _centerDividerHovered = true),
                        onExit: (_) => setState(() => _centerDividerHovered = false),
                        child: GestureDetector(
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              _centerWidth = (_centerWidth + details.delta.dx)
                                  .clamp(220.0, 560.0);
                            });
                          },
                          child: Container(
                            width: dividerWidth,
                            color: _centerDividerHovered
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withAlpha(80)
                                : Colors.transparent,
                            child: VerticalDivider(
                              width: 1,
                              color: _centerDividerHovered
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                            ),
                          ),
                        ),
                      ),
                    if (!_isStreamCollapsed)
                      SizedBox(
                        width: streamPaneWidth,
                        child: Card(
                          child: LayoutBuilder(
                            builder: (context, streamConstraints) {
                              final streamCompact =
                                  streamConstraints.maxWidth < 180;
                              return Column(
                                children: [
                                  if (!streamCompact)
                                    ListTile(
                                      dense: true,
                                      leading: const Icon(Icons.stream_rounded),
                                      title: const Text('Live Message Stream'),
                                      subtitle: Text(
                                        _selectedTopicFilter == null
                                            ? 'Showing all topics'
                                            : 'Filtered: $_selectedTopicFilter',
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'Collapse pane',
                                        onPressed: () => setState(
                                            () => _isStreamCollapsed = true),
                                        icon:
                                            const Icon(Icons.chevron_right_rounded),
                                      ),
                                    )
                                  else
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Text(
                                        'Live Stream',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(12, 0, 12, 10),
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final compact = constraints.maxWidth < 340;

                                        final typeField =
                                            DropdownButtonFormField<_MqttStreamTypeFilter>(
                                          initialValue: _streamTypeFilter,
                                          isDense: true,
                                          isExpanded: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Type',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: const [
                                            DropdownMenuItem(
                                              value: _MqttStreamTypeFilter.all,
                                              child: Text('All'),
                                            ),
                                            DropdownMenuItem(
                                              value: _MqttStreamTypeFilter.sent,
                                              child: Text('PUB'),
                                            ),
                                            DropdownMenuItem(
                                              value: _MqttStreamTypeFilter.received,
                                              child: Text('SUB'),
                                            ),
                                          ],
                                          onChanged: (v) {
                                            if (v == null) return;
                                            setState(() => _streamTypeFilter = v);
                                          },
                                        );

                                        final searchField = TextField(
                                          controller: _streamSearchCtrl,
                                          onChanged: (_) => setState(() {}),
                                          decoration: const InputDecoration(
                                            labelText: 'Search payload',
                                            hintText:
                                                'Filter by payload/body text',
                                            prefixIcon:
                                                Icon(Icons.search_rounded),
                                            border: OutlineInputBorder(),
                                            isDense: true,
                                          ),
                                        );

                                        final clearButton =
                                            _selectedTopicFilter == null
                                                ? const SizedBox.shrink()
                                                : TextButton.icon(
                                                    onPressed: () {
                                                      setState(() =>
                                                          _selectedTopicFilter =
                                                              null);
                                                    },
                                                    icon: const Icon(
                                                      Icons.clear_all_rounded,
                                                      size: 16,
                                                    ),
                                                    label: const Text(
                                                        'Clear filter'),
                                                  );

                                        if (compact) {
                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              typeField,
                                              const SizedBox(height: 8),
                                              searchField,
                                              if (_selectedTopicFilter != null) ...[
                                                const SizedBox(height: 6),
                                                Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: clearButton,
                                                ),
                                              ],
                                            ],
                                          );
                                        }

                                        return Row(
                                          children: [
                                            SizedBox(width: 130, child: typeField),
                                            const SizedBox(width: 8),
                                            Expanded(child: searchField),
                                            if (_selectedTopicFilter != null) ...[
                                              const SizedBox(width: 8),
                                              clearButton,
                                            ],
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  const Divider(height: 1),
                                  Expanded(
                                    child: _MessageLog(
                                      session: session,
                                      messages: filteredMessages,
                                      activeTopicFilter: _selectedTopicFilter,
                                      onReplay: (msg) {
                                        notifier.publish(
                                          msg.topic,
                                          msg.payload,
                                          qos: msg.qos,
                                          retain: msg.retain,
                                        );
                                      },
                                      onCopy: (msg) async {
                                        await Clipboard.setData(
                                          ClipboardData(text: msg.payload),
                                        );
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'Payload copied to clipboard.'),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: collapsedWidth,
                        child: Center(
                          child: IconButton(
                            tooltip: 'Expand stream pane',
                            onPressed: () => setState(() => _isStreamCollapsed = false),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Map<String, int> _buildTopicCounts(List<MqttMessage> messages) {
    final counts = <String, int>{};
    for (final m in messages) {
      counts[m.topic] = (counts[m.topic] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, double> _buildTopicRates(List<MqttMessage> messages) {
    final now = DateTime.now();
    final window = const Duration(seconds: 10);
    final counts = <String, int>{};
    for (final m in messages) {
      if (now.difference(m.timestamp) > window) continue;
      counts[m.topic] = (counts[m.topic] ?? 0) + 1;
    }
    return counts.map(
      (topic, count) => MapEntry(topic, count / window.inSeconds),
    );
  }

  Map<String, DateTime> _buildTopicLastActivity(List<MqttMessage> messages) {
    final last = <String, DateTime>{};
    for (final m in messages) {
      final prev = last[m.topic];
      if (prev == null || m.timestamp.isAfter(prev)) {
        last[m.topic] = m.timestamp;
      }
    }
    return last;
  }

  MqttMessage? _lastSentMessage(List<MqttMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isSent) return messages[i];
    }
    return null;
  }

  List<MqttMessage> _filteredMessages(List<MqttMessage> all) {
    final query = _streamSearchCtrl.text.trim().toLowerCase();
    return all.where((m) {
      if (_selectedTopicFilter != null && m.topic != _selectedTopicFilter) {
        return false;
      }
      final typeMatch = switch (_streamTypeFilter) {
        _MqttStreamTypeFilter.all => true,
        _MqttStreamTypeFilter.sent => m.isSent,
        _MqttStreamTypeFilter.received => !m.isSent,
      };
      if (!typeMatch) return false;
      if (query.isEmpty) return true;
      return m.payload.toLowerCase().contains(query) ||
          m.topic.toLowerCase().contains(query);
    }).toList(growable: false);
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
      protocolVersion: _protocolVersion,
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
          NameValueModel(
            name: 'mqtt.protocol',
            value: switch (model.protocolVersion) {
              MqttProtocolVersion.v31 => '3.1',
              MqttProtocolVersion.v311 => '3.1.1',
              MqttProtocolVersion.v5 => '5.0',
            },
          ),
        ],
        responseStatus: session.isConnected ? 200 : -1,
        message: session.isConnected
            ? 'MQTT connected'
            : (session.error ?? 'MQTT connection failed'),
        responseBody: session.error,
      );
    });
  }

  void _onConnectionDraftFieldChanged() {
    if (_isHydratingDraft) {
      return;
    }
    _persistMqttDraft();
  }

  void _loadDraftFromSelectedRequest() {
    final requestModel = ref.read(selectedRequestModelProvider);
    final http = requestModel?.httpRequestModel;
    if (http == null) {
      return;
    }

    final parsedUrl = Uri.tryParse(http.url ?? '');
    var host = _hostCtrl.text;
    var port = _portCtrl.text;
    var useTls = _useTls;

    if (parsedUrl != null && parsedUrl.host.isNotEmpty) {
      host = parsedUrl.host;
      final defaultPort = parsedUrl.scheme == 'mqtts' ? 8883 : 1883;
      port = (parsedUrl.hasPort ? parsedUrl.port : defaultPort).toString();
      useTls = parsedUrl.scheme == 'mqtts';
    }

    var clientId = _clientIdCtrl.text;
    var username = _userCtrl.text;
    var password = _passCtrl.text;
    var protocolVersion = _protocolVersion;

    final rawQuery = http.query;
    if (rawQuery != null && rawQuery.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawQuery);
        if (decoded is Map<String, dynamic>) {
          final draft = decoded;
          clientId = (draft['clientId'] as String?) ?? clientId;
          username = (draft['username'] as String?) ?? username;
          password = (draft['password'] as String?) ?? password;
          useTls = (draft['useTls'] as bool?) ?? useTls;
          final protoName = draft['protocolVersion'] as String?;
          if (protoName != null) {
            protocolVersion = MqttProtocolVersion.values.firstWhere(
              (v) => v.name == protoName,
              orElse: () => protocolVersion,
            );
          }
        }
      } catch (_) {
        // Keep current values if saved query is not valid JSON.
      }
    }

    _isHydratingDraft = true;
    _hostCtrl.text = host;
    _portCtrl.text = port;
    _clientIdCtrl.text = clientId;
    _userCtrl.text = username;
    _passCtrl.text = password;
    setState(() {
      _useTls = useTls;
      _protocolVersion = protocolVersion;
    });
    _isHydratingDraft = false;
  }

  void _persistMqttDraft() {
    final notifier = ref.read(collectionStateNotifierProvider.notifier);
    final draft = <String, dynamic>{
      'clientId': _clientIdCtrl.text.trim(),
      'username': _userCtrl.text.trim(),
      'password': _passCtrl.text,
      'useTls': _useTls,
      'protocolVersion': _protocolVersion.name,
    };

    notifier.update(
      apiType: APIType.mqtt,
      method: HTTPVerb.get,
      url: _mqttUrl,
      query: jsonEncode(draft),
    );
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
    if (host.isEmpty) {
      return '';
    }
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
          const SizedBox(width: 8),
          Text(
            'Attempts: ${session.connectAttempts}${session.connectLatencyMs == null ? '' : ' • ${session.connectLatencyMs} ms'}',
            style: Theme.of(context).textTheme.labelSmall,
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

class _MqttMetricsBar extends StatelessWidget {
  const _MqttMetricsBar({
    required this.session,
    required this.messages,
  });

  final MqttSessionState session;
  final List<MqttMessage> messages;

  @override
  Widget build(BuildContext context) {
    final total = messages.length;
    final sent = messages.where((m) => m.isSent).length;
    final recv = total - sent;
    final bytes = messages.fold<int>(0, (sum, m) => sum + m.sizeBytes);
    final uptimeSecs = session.connectedAt == null
        ? 0
        : DateTime.now().difference(session.connectedAt!).inSeconds;
    final msgRate = uptimeSecs <= 0 ? '--' : (total / uptimeSecs).toStringAsFixed(2);
    final throughput = uptimeSecs <= 0 ? '--' : '${(bytes / uptimeSecs).toStringAsFixed(1)} B/s';
    final latency = session.connectLatencyMs == null ? '--' : '${session.connectLatencyMs} ms';
    final status = switch (session.connectionState) {
      MqttClientConnectionState.connected => 'Connected',
      MqttClientConnectionState.connecting => 'Connecting',
      MqttClientConnectionState.disconnected => 'Disconnected',
    };
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: scheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        children: [
          _Metric(label: 'Status', value: status),
          _Metric(label: 'Msgs', value: '$total'),
          _Metric(label: 'Sent', value: '$sent'),
          _Metric(label: 'Recv', value: '$recv'),
          _Metric(label: 'Msg/s', value: msgRate),
          _Metric(label: 'Throughput', value: throughput),
          _Metric(label: 'Latency', value: latency),
          _Metric(label: 'Connect attempts', value: '${session.connectAttempts}'),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.labelSmall,
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w700),
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
    required this.protocolVersion,
    required this.onTlsChanged,
    required this.onProtocolVersionChanged,
    required this.enabled,
  });

  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final TextEditingController clientIdCtrl;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final bool useTls;
  final MqttProtocolVersion protocolVersion;
  final ValueChanged<bool> onTlsChanged;
  final ValueChanged<MqttProtocolVersion> onProtocolVersionChanged;
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
          Text('Protocol Version',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          DropdownButtonFormField<MqttProtocolVersion>(
            initialValue: protocolVersion,
            isDense: true,
            decoration: const InputDecoration(
              labelText: 'Protocol',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: MqttProtocolVersion.v31,
                child: Text('3.1'),
              ),
              DropdownMenuItem(
                value: MqttProtocolVersion.v311,
                child: Text('3.1.1'),
              ),
              DropdownMenuItem(
                value: MqttProtocolVersion.v5,
                child: Text('5.0'),
              ),
            ],
            onChanged: enabled
                ? (v) {
                    if (v != null) onProtocolVersionChanged(v);
                  }
                : null,
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
    required this.templates,
    required this.selectedTemplate,
    required this.hasLastSent,
    required this.onTemplateChanged,
    required this.onUseLastSent,
    required this.onQosChanged,
    required this.onRetainChanged,
    required this.onPublish,
  });

  final TextEditingController topicCtrl;
  final TextEditingController payloadCtrl;
  final int qos;
  final bool retain;
  final bool enabled;
  final List<MapEntry<String, String>> templates;
  final String? selectedTemplate;
  final bool hasLastSent;
  final ValueChanged<String?> onTemplateChanged;
  final VoidCallback onUseLastSent;
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
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 380;

              final templateField = DropdownButtonFormField<String>(
                initialValue: selectedTemplate,
                isDense: true,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Payload template',
                  border: OutlineInputBorder(),
                ),
                selectedItemBuilder: (context) => [
                  const Text('None', overflow: TextOverflow.ellipsis),
                  ...templates.map(
                    (entry) => Text(
                      entry.key,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('None', overflow: TextOverflow.ellipsis),
                  ),
                  ...templates.map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.key, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: enabled ? onTemplateChanged : null,
              );

              final lastSentButton = OutlinedButton.icon(
                onPressed: enabled && hasLastSent ? onUseLastSent : null,
                icon: const Icon(Icons.history_rounded, size: 16),
                label: const Text('Use last sent', overflow: TextOverflow.ellipsis),
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    templateField,
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: lastSentButton,
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: templateField),
                  const SizedBox(width: 8),
                  lastSentButton,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text('QoS Level',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          _QosRadioSelector(
            value: qos,
            enabled: enabled,
            onChanged: onQosChanged,
            options: const [
              (0, '0 - At most once'),
              (1, '1 - At least once'),
              (2, '2 - Exactly once'),
            ],
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
    required this.topicCounts,
    required this.topicRates,
    required this.topicLastActivity,
    required this.selectedTopic,
    required this.enabled,
    required this.onTopicSelected,
    required this.onQosChanged,
    required this.onSubscribe,
    required this.onUnsubscribe,
  });

  final TextEditingController topicCtrl;
  final int qos;
  final List<String> subscribedTopics;
  final Map<String, int> topicCounts;
  final Map<String, double> topicRates;
  final Map<String, DateTime> topicLastActivity;
  final String? selectedTopic;
  final bool enabled;
  final ValueChanged<String?> onTopicSelected;
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
          Text('Subscribe', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
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
          const SizedBox(height: 6),
          _QosRadioSelector(
            value: qos,
            enabled: enabled,
            onChanged: onQosChanged,
            options: const [
              (0, 'QoS 0'),
              (1, 'QoS 1'),
              (2, 'QoS 2'),
            ],
          ),
          const SizedBox(height: 16),
          if (subscribedTopics.isNotEmpty) ...[
            Text('Active Subscriptions',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Column(
              children: subscribedTopics
                  .map(
                    (topic) => Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        onTap: () {
                          if (selectedTopic == topic) {
                            onTopicSelected(null);
                            return;
                          }
                          onTopicSelected(topic);
                        },
                        leading: Icon(
                          selectedTopic == topic
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                        ),
                        title: _TopicHierarchyLabel(topic: topic),
                        subtitle: Text(
                          'Subscribed • ${topicCounts[topic] ?? 0} msgs • ${topicRates[topic]?.toStringAsFixed(2) ?? '0.00'} msgs/s',
                        ),
                        trailing: IconButton(
                          tooltip: 'Unsubscribe',
                          onPressed: enabled ? () => onUnsubscribe(topic) : null,
                          icon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 10,
                                color: _isTopicActive(topic) ? Colors.green : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.close_rounded, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ] else
            Text(
              'No active subscriptions yet. Add a topic to start receiving live traffic.',
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

  bool _isTopicActive(String topic) {
    final last = topicLastActivity[topic];
    if (last == null) return false;
    return DateTime.now().difference(last).inSeconds <= 5;
  }
}

class _TopicHierarchyLabel extends StatelessWidget {
  const _TopicHierarchyLabel({required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) {
    final parts = topic.split('/').where((p) => p.isNotEmpty).toList(growable: false);
    if (parts.length <= 1) {
      return Text(topic);
    }
    final parent = parts.sublist(0, parts.length - 1).join('/');
    final leaf = parts.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          parent,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Text('└─ $leaf'),
      ],
    );
  }
}

class _MessageLog extends StatelessWidget {
  const _MessageLog({
    required this.session,
    required this.messages,
    required this.activeTopicFilter,
    required this.onReplay,
    required this.onCopy,
  });

  final MqttSessionState session;
  final List<MqttMessage> messages;
  final String? activeTopicFilter;
  final ValueChanged<MqttMessage> onReplay;
  final ValueChanged<MqttMessage> onCopy;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.podcasts_rounded,
                size: 34,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(130),
              ),
              const SizedBox(height: 8),
              Text(
                session.isConnected
                    ? activeTopicFilter == null
                        ? 'Live stream is ready. Subscribe and publish to inspect MQTT traffic in real time.'
                        : 'No messages yet for "$activeTopicFilter". Pick another topic or clear filter.'
                    : 'Connect to a broker to start the live MQTT inspector.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(140),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: messages.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final msg = messages[i];
        return _MqttMessageTile(
          message: msg,
          timeText: _formatTime(msg.timestamp),
          onReplay: () => onReplay(msg),
          onCopy: () => onCopy(msg),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _MqttMessageTile extends StatelessWidget {
  const _MqttMessageTile({
    required this.message,
    required this.timeText,
    required this.onReplay,
    required this.onCopy,
  });

  final MqttMessage message;
  final String timeText;
  final VoidCallback onReplay;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPub = message.isSent;
    final payloadPreview = message.payload.length > 90
        ? '${message.payload.substring(0, 90)}...'
        : message.payload;
    String parsedPayload = message.payload;
    final trimmed = message.payload.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        parsedPayload = const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(trimmed));
      } catch (_) {
        parsedPayload = message.payload;
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        dense: true,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message.topic,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            _QosBadge(qos: message.qos),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                payloadPreview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 2),
              Text('$timeText • ${message.sizeBytes} B', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: onReplay,
                      icon: const Icon(Icons.replay_rounded, size: 16),
                      label: const Text('Replay'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    parsedPayload,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

class _QosRadioSelector extends StatelessWidget {
  const _QosRadioSelector({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.options,
  });

  final int value;
  final bool enabled;
  final ValueChanged<int?> onChanged;
  final List<(int, String)> options;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: options
          .map(
            (opt) => InkWell(
              onTap: enabled ? () => onChanged(opt.$1) : null,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Radio<int>(
                      value: opt.$1,
                      groupValue: value,
                      onChanged: enabled ? onChanged : null,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Text(opt.$2),
                  ],
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}
