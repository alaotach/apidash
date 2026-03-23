import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash/providers/providers.dart';
import 'package:better_networking/better_networking.dart';
import 'package:apidash/providers/grpc_providers.dart';
import 'package:apidash/services/grpc_service.dart';
import 'package:apidash/utils/file_utils.dart';

class EditGrpcRequestPane extends ConsumerStatefulWidget {
  const EditGrpcRequestPane({super.key});

  @override
  ConsumerState<EditGrpcRequestPane> createState() =>
      _EditGrpcRequestPaneState();
}

enum GrpcBytesDisplayMode {
  utf8('UTF-8'),
  base64('Base64'),
  raw('Raw');

  const GrpcBytesDisplayMode(this.label);
  final String label;
}

enum GrpcRequestInputMode {
  form('Form Mode'),
  json('JSON Mode');

  const GrpcRequestInputMode(this.label);
  final String label;
}

class _EditGrpcRequestPaneState
    extends ConsumerState<EditGrpcRequestPane> {
  static const _kDefaultGrpcPort = '443';
  static const _kDefaultGrpcBody = '{\n  \n}';

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: _kDefaultGrpcPort);
  final _serviceCtrl = TextEditingController();
  final _methodCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController(text: _kDefaultGrpcBody);
  GrpcCallType _callType = GrpcCallType.unary;
  GrpcBytesDisplayMode _bytesDisplayMode = GrpcBytesDisplayMode.utf8;
  GrpcRequestInputMode _requestInputMode = GrpcRequestInputMode.form;
  bool _useTls = true;
  bool _showMetadataEditor = false;
  List<String> _uploadedProtoFiles = const [];
  final Map<String, dynamic> _schemaFormValues = {};
  String _lastSchemaKey = '';
  final Map<String, String> _metadata = {};
  final Map<String, String> _methodBodies = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadFromSelectedRequest();
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _serviceCtrl.dispose();
    _methodCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(grpcNotifierProvider);
    final notifier = ref.read(grpcNotifierProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final hasReflectionDiscovery =
      session.discoveryStatus == GrpcDiscoveryStatus.discovered &&
      session.discoveredServices.isNotEmpty;
    final totalWidth = MediaQuery.sizeOf(context).width;
    final explorerWidth = (totalWidth >= 1400
      ? 320.0
      : totalWidth >= 1100
        ? 280.0
        : 220.0)
      .clamp(200.0, 320.0);
    final canInvoke = session.connectionState == GrpcConnectionState.connected &&
      !session.isLoading &&
      session.discoveryStatus != GrpcDiscoveryStatus.requiresProtoUpload &&
      _serviceCtrl.text.trim().isNotEmpty &&
      _methodCtrl.text.trim().isNotEmpty;
    final schemaKey = session.requestSchema
        .map((f) => '${f.jsonName}:${f.kind.name}:${f.isRepeated}')
        .join('|');
    if (schemaKey != _lastSchemaKey) {
      _lastSchemaKey = schemaKey;
      _initializeSchemaFormValues(session.requestSchema);
    }

    ref.listen(selectedIdStateProvider, (previous, next) {
      if (previous != next) {
        _loadFromSelectedRequest();
      }
    });

    final endpointDisplay =
        '${_useTls ? 'grpcs' : 'grpc'}://${_hostCtrl.text.trim().isEmpty ? 'host' : _hostCtrl.text.trim()}:${int.tryParse(_portCtrl.text) ?? 443}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  endpointDisplay,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              _GrpcStatusStrip(session: session),
              const SizedBox(width: 8),
              SizedBox(
                width: 140,
                child: _GrpcConnectButton(
                  state: session.connectionState,
                  isBusy: session.isLoading,
                  onConnect: () => _discover(notifier),
                  onDisconnect: () => _disconnect(notifier),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: explorerWidth,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Service Explorer',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      if (!hasReflectionDiscovery) ...[
                        TextField(
                          controller: _hostCtrl,
                          enabled: !session.isConnected,
                          onChanged: (_) => _persistGrpcDraft(),
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: 'grpc.example.com',
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _portCtrl,
                          enabled: !session.isConnected,
                          onChanged: (_) => _persistGrpcDraft(),
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _useTls,
                          onChanged: session.isConnected
                              ? null
                              : (v) => setState(() {
                                  _useTls = v;
                                  _persistGrpcDraft();
                                }),
                          title: const Text('TLS'),
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _serviceCtrl,
                          onChanged: (_) {
                            _persistGrpcDraft();
                            _maybeLoadSchema(notifier);
                          },
                          decoration: const InputDecoration(
                            labelText: 'Service name',
                            hintText: 'helloworld.Greeter',
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _methodCtrl,
                          onChanged: (_) {
                            _persistGrpcDraft();
                            _maybeLoadSchema(notifier);
                          },
                          decoration: const InputDecoration(
                            labelText: 'Method name',
                            hintText: 'SayHello',
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                      ] else ...[
                        _GrpcMethodExplorer(
                          methodsByService: session.methodsByService,
                          selectedService: _serviceCtrl.text,
                          selectedMethod: _methodCtrl.text,
                          onSelect: (service, method) {
                            setState(() {
                              _serviceCtrl.text = service;
                              _methodCtrl.text = method;
                              _restoreBodyForCurrentMethod();
                              _initializeSchemaFormValues(session.requestSchema);
                              _persistGrpcDraft();
                            });
                            _maybeLoadSchema(notifier);
                          },
                        ),
                      ],
                      if (session.discoveryMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          session.discoveryMessage!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (session.discoveryStatus ==
                          GrpcDiscoveryStatus.requiresProtoUpload) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Reflection unavailable. Upload .proto files.',
                                style:
                                    TextStyle(color: colorScheme.onErrorContainer),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _uploadProto,
                                icon: const Icon(Icons.upload_file_rounded),
                                label: const Text('Upload .proto'),
                              ),
                              if (_uploadedProtoFiles.isNotEmpty)
                                Text(
                                  _uploadedProtoFiles.join(', '),
                                  style: TextStyle(
                                    color: colorScheme.onErrorContainer,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Request Builder',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      if (session.methodSignature != null)
                        Text(
                          session.methodSignature!.toFormattedString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      const SizedBox(height: 6),
                      if (session.requestSchema.isNotEmpty)
                        SegmentedButton<GrpcRequestInputMode>(
                          showSelectedIcon: false,
                          segments: GrpcRequestInputMode.values
                              .map(
                                (mode) => ButtonSegment<GrpcRequestInputMode>(
                                  value: mode,
                                  label: Text(mode.label),
                                ),
                              )
                              .toList(),
                          selected: {_requestInputMode},
                          onSelectionChanged: (selection) {
                            final next = selection.first;
                            setState(() {
                              _requestInputMode = next;
                              if (next == GrpcRequestInputMode.form) {
                                _initializeSchemaFormValues(session.requestSchema);
                              } else {
                                _maybePopulateMockJsonForSchema(session.requestSchema);
                              }
                            });
                          },
                        ),
                      const SizedBox(height: 8),
                      if (_serviceCtrl.text.trim().isEmpty ||
                          _methodCtrl.text.trim().isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Select a method from Service Explorer to build the request.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      Expanded(
                        child: session.isSchemaLoading
                            ? const Center(child: CircularProgressIndicator())
                            : session.requestSchema.isNotEmpty &&
                                    _requestInputMode == GrpcRequestInputMode.form
                                ? _GrpcSchemaForm(
                                    schema: session.requestSchema,
                                    values: _schemaFormValues,
                                    onChanged: _updateSchemaField,
                                  )
                                : TextField(
                                    controller: _bodyCtrl,
                                    onChanged: (_) => _persistGrpcDraft(),
                                    maxLines: null,
                                    expands: true,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                    ),
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.all(12),
                                      hintText: '{\n  "name": "world"\n}',
                                      alignLabelWithHint: true,
                                    ),
                                  ),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _showMetadataEditor = !_showMetadataEditor;
                          });
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                _showMetadataEditor
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _metadata.isEmpty
                                    ? 'Metadata (optional)'
                                    : 'Metadata (${_metadata.length})',
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_showMetadataEditor)
                        _GrpcMetadataEditor(
                          metadata: _metadata,
                          onChanged: (updated) {
                            setState(() {
                              _metadata
                                ..clear()
                                ..addAll(updated);
                              _persistGrpcDraft();
                            });
                          },
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: 170,
                            child: DropdownButtonFormField<GrpcCallType>(
                              isExpanded: true,
                              value: _callType,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                              ),
                              items: GrpcCallType.values
                                  .map(
                                    (t) => DropdownMenuItem(
                                      value: t,
                                      child: Text(t.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _callType = v ?? GrpcCallType.unary;
                                _persistGrpcDraft();
                              }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: canInvoke ? () => _invoke(notifier) : null,
                              icon: session.isLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.play_arrow_rounded),
                              label: const Text('Invoke'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Text('Response',
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _GrpcResponsePanel(
                        session: session,
                        bytesDisplayMode: _bytesDisplayMode,
                        onBytesDisplayModeChanged: (mode) {
                          setState(() => _bytesDisplayMode = mode);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _discover(GrpcNotifier notifier) async {
    final model = GrpcRequestModel(
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text) ?? 443,
      useTls: _useTls,
      serviceName: _serviceCtrl.text.trim(),
      methodName: _methodCtrl.text.trim(),
      requestJson: _bodyCtrl.text,
      metadata: _metadata,
      callType: _callType,
    );
    await notifier.discover(model);
    await _maybeLoadSchema(notifier);
  }

  Future<void> _uploadProto() async {
    final file = await pickFile();
    if (file == null) return;
    if (!mounted) return;
    setState(() {
      _uploadedProtoFiles = [file.path];
    });
    _persistGrpcDraft();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Proto file selected. Parsing-based invocation is pending implementation.'),
      ),
    );
  }

  Future<void> _disconnect(GrpcNotifier notifier) async {
    final model = GrpcRequestModel(
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text) ?? 443,
      useTls: _useTls,
      serviceName: _serviceCtrl.text.trim(),
      methodName: _methodCtrl.text.trim(),
      requestJson: _bodyCtrl.text,
      callType: _callType,
    );
    await notifier.disconnect(model);
  }

  String _currentMethodKey() {
    final service = _serviceCtrl.text.trim();
    final method = _methodCtrl.text.trim();
    if (service.isEmpty || method.isEmpty) return '';
    return '$service/$method';
  }

  void _restoreBodyForCurrentMethod() {
    final key = _currentMethodKey();
    if (key.isEmpty) {
      _bodyCtrl.text = _kDefaultGrpcBody;
      return;
    }
    _bodyCtrl.text = _methodBodies[key] ?? _kDefaultGrpcBody;
  }

  Future<void> _invoke(GrpcNotifier notifier) async {
    final session = ref.read(grpcNotifierProvider);
    if (session.connectionState != GrpcConnectionState.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to the endpoint before invoking.')),
      );
      return;
    }

    if (_serviceCtrl.text.trim().isEmpty || _methodCtrl.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a service and method before invoking.')),
      );
      return;
    }

    final model = GrpcRequestModel(
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text) ?? 443,
      useTls: _useTls,
      serviceName: _serviceCtrl.text.trim(),
      methodName: _methodCtrl.text.trim(),
      requestJson: _bodyCtrl.text,
      callType: _callType,
      metadata: _metadata,
    );
    await notifier.executeCall(model);

    final updatedSession = ref.read(grpcNotifierProvider);
    final result = updatedSession.result;
    final scheme = model.useTls ? 'grpcs' : 'grpc';
    final endpoint =
        '$scheme://${model.host}:${model.port}/${model.serviceName}/${model.methodName}';

    ref.read(collectionStateNotifierProvider.notifier).logProtocolRequest(
      apiType: APIType.grpc,
      url: endpoint,
      method: HTTPVerb.post,
      requestBody: model.requestJson,
      responseStatus: result?.errorMessage == null ? 200 : -1,
      message: result?.errorMessage,
      responseBody: result?.responseJson ?? result?.errorMessage,
      duration: result?.responseDurationMs == null
          ? null
          : Duration(milliseconds: result!.responseDurationMs!),
    );
  }

  void _loadFromSelectedRequest() {
    final requestModel = ref.read(selectedRequestModelProvider);
    final http = requestModel?.httpRequestModel;
    if (http == null) {
      setState(() {
        _hostCtrl.text = '';
        _portCtrl.text = _kDefaultGrpcPort;
        _serviceCtrl.text = '';
        _methodCtrl.text = '';
        _bodyCtrl.text = _kDefaultGrpcBody;
        _useTls = true;
        _callType = GrpcCallType.unary;
        _uploadedProtoFiles = const [];
        _metadata.clear();
        _methodBodies.clear();
      });
      return;
    }

    final parsed = Uri.tryParse(http.url);
    final isGrpcScheme = parsed != null &&
        (parsed.scheme == 'grpc' || parsed.scheme == 'grpcs');

    Map<String, dynamic> grpcConfig = const {};
    final rawQuery = http.query;
    if (rawQuery != null && rawQuery.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawQuery);
        if (decoded is Map<String, dynamic>) {
          grpcConfig = decoded;
        }
      } catch (_) {
        // Ignore invalid persisted config and keep sensible defaults.
      }
    }

    final callTypeName = grpcConfig['callType'] as String?;
    final resolvedCallType = GrpcCallType.values.firstWhere(
      (e) => e.name == callTypeName,
      orElse: () => GrpcCallType.unary,
    );

    setState(() {
      _hostCtrl.text = isGrpcScheme ? (parsed.host) : '';
      _portCtrl.text = isGrpcScheme
          ? ((parsed.hasPort && parsed.port > 0)
                ? parsed.port.toString()
                : _kDefaultGrpcPort)
          : _kDefaultGrpcPort;
      _serviceCtrl.text = (grpcConfig['serviceName'] as String?) ?? '';
      _methodCtrl.text = (grpcConfig['methodName'] as String?) ?? '';
      _bodyCtrl.text = (http.body != null && http.body!.isNotEmpty)
          ? http.body!
          : _kDefaultGrpcBody;
      _useTls = (grpcConfig['useTls'] as bool?) ??
          (isGrpcScheme ? parsed.scheme == 'grpcs' : true);
      _callType = resolvedCallType;
      _uploadedProtoFiles = ((grpcConfig['protoFiles'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false);
      _metadata.clear();
      final metadataFromConfig = grpcConfig['metadata'] as Map?;
      if (metadataFromConfig != null) {
        _metadata.addAll(metadataFromConfig.cast<String, String>());
      }
      _methodBodies.clear();
      final rawBodies = grpcConfig['methodBodies'];
      if (rawBodies is Map) {
        for (final entry in rawBodies.entries) {
          final k = entry.key.toString();
          final v = entry.value;
          if (v is String) {
            _methodBodies[k] = v;
          }
        }
      }
      final currentKey = _currentMethodKey();
      if (currentKey.isNotEmpty && _methodBodies.containsKey(currentKey)) {
        _bodyCtrl.text = _methodBodies[currentKey]!;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeLoadSchema(ref.read(grpcNotifierProvider.notifier));
    });
  }

  void _persistGrpcDraft() {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text) ?? 443;
    final scheme = _useTls ? 'grpcs' : 'grpc';
    final url = host.isEmpty ? '' : '$scheme://$host:$port';

    final methodKey = _currentMethodKey();
    if (methodKey.isNotEmpty) {
      _methodBodies[methodKey] = _bodyCtrl.text;
    }

    final grpcConfig = <String, dynamic>{
      'serviceName': _serviceCtrl.text.trim(),
      'methodName': _methodCtrl.text.trim(),
      'useTls': _useTls,
      'callType': _callType.name,
      'protoFiles': _uploadedProtoFiles,
      if (_metadata.isNotEmpty) 'metadata': _metadata,
      if (_methodBodies.isNotEmpty) 'methodBodies': _methodBodies,
    };

    ref.read(collectionStateNotifierProvider.notifier).update(
      apiType: APIType.grpc,
      method: HTTPVerb.post,
      url: url,
      body: _bodyCtrl.text,
      query: jsonEncode(grpcConfig),
    );
  }

  Future<void> _maybeLoadSchema(GrpcNotifier notifier) async {
    final service = _serviceCtrl.text.trim();
    final method = _methodCtrl.text.trim();
    if (service.isEmpty || method.isEmpty) {
      return;
    }
    final model = GrpcRequestModel(
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text) ?? 443,
      useTls: _useTls,
      serviceName: service,
      methodName: method,
      requestJson: _bodyCtrl.text,
      callType: _callType,
      metadata: _metadata,
    );
    await notifier.loadRequestSchema(model);

    // If the user is already in JSON mode, seed mock JSON as soon as schema arrives.
    if (!mounted || _requestInputMode != GrpcRequestInputMode.json) {
      return;
    }
    final updatedSession = ref.read(grpcNotifierProvider);
    _maybePopulateMockJsonForSchema(updatedSession.requestSchema);
  }

  void _initializeSchemaFormValues(List<GrpcRequestFieldSchema> schema) {
    if (schema.isEmpty) {
      _schemaFormValues.clear();
      return;
    }
    Map<String, dynamic> parsedBody = const {};
    try {
      final decoded = jsonDecode(_bodyCtrl.text);
      if (decoded is Map<String, dynamic>) {
        parsedBody = decoded;
      }
    } catch (_) {
      parsedBody = const {};
    }

    _schemaFormValues
      ..clear()
      ..addAll(parsedBody);
  }

  void _maybePopulateMockJsonForSchema(List<GrpcRequestFieldSchema> schema) {
    if (schema.isEmpty || _hasSavedJsonForCurrentMethod()) {
      return;
    }
    final mock = <String, dynamic>{
      for (final field in schema)
        field.jsonName: _mockValueForField(field),
    };
    _bodyCtrl.text = const JsonEncoder.withIndent('  ').convert(mock);
    _initializeSchemaFormValues(schema);
    _persistGrpcDraft();
  }

  bool _hasSavedJsonForCurrentMethod() {
    final raw = _bodyCtrl.text.trim();
    if (raw.isEmpty || raw == _kDefaultGrpcBody) {
      return false;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.isNotEmpty;
      }
      // Non-map JSON (string/list/number) is still user-provided content.
      return true;
    } catch (_) {
      // If JSON is invalid but non-empty, keep user input untouched.
      return true;
    }
  }

  dynamic _mockValueForField(GrpcRequestFieldSchema field) {
    if (field.isRepeated) {
      return <dynamic>[];
    }
    switch (field.kind) {
      case GrpcFieldKind.string:
      case GrpcFieldKind.bytes:
        return '';
      case GrpcFieldKind.boolType:
        return false;
      case GrpcFieldKind.intType:
        return 0;
      case GrpcFieldKind.doubleType:
        return 0.0;
      case GrpcFieldKind.enumType:
        return field.enumValues.isNotEmpty ? field.enumValues.first : '';
      case GrpcFieldKind.message:
        return <String, dynamic>{};
      case GrpcFieldKind.unknown:
        return null;
    }
  }

  void _updateSchemaField(GrpcRequestFieldSchema field, dynamic rawValue) {
    dynamic value = rawValue;
    if (field.isRepeated && rawValue is String) {
      value = rawValue
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    } else {
      switch (field.kind) {
        case GrpcFieldKind.intType:
          value = rawValue is String ? int.tryParse(rawValue) : rawValue;
          break;
        case GrpcFieldKind.doubleType:
          value = rawValue is String ? double.tryParse(rawValue) : rawValue;
          break;
        case GrpcFieldKind.message:
          if (rawValue is String && rawValue.trim().isNotEmpty) {
            try {
              final decoded = jsonDecode(rawValue);
              if (decoded is Map<String, dynamic>) {
                value = decoded;
              }
            } catch (_) {
              value = rawValue;
            }
          }
          break;
        case GrpcFieldKind.string:
        case GrpcFieldKind.bytes:
        case GrpcFieldKind.boolType:
        case GrpcFieldKind.enumType:
        case GrpcFieldKind.unknown:
          break;
      }
    }

    setState(() {
      if (value == null || (value is String && value.isEmpty)) {
        _schemaFormValues.remove(field.jsonName);
      } else {
        _schemaFormValues[field.jsonName] = value;
      }
      _bodyCtrl.text = const JsonEncoder.withIndent('  ').convert(_schemaFormValues);
      _persistGrpcDraft();
    });
  }
}

class _GrpcMethodExplorer extends StatefulWidget {
  const _GrpcMethodExplorer({
    required this.methodsByService,
    required this.selectedService,
    required this.selectedMethod,
    required this.onSelect,
  });

  final Map<String, List<String>> methodsByService;
  final String selectedService;
  final String selectedMethod;
  final void Function(String service, String method) onSelect;

  @override
  State<_GrpcMethodExplorer> createState() => _GrpcMethodExplorerState();
}

class _GrpcMethodExplorerState extends State<_GrpcMethodExplorer> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final services = widget.methodsByService.keys.toList()..sort();
    final maxExplorerHeight = MediaQuery.sizeOf(context).height * 0.45;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: Text(
                  'Method Explorer',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              SizedBox(
                height: maxExplorerHeight.clamp(180.0, 320.0),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: services.length > 4,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.zero,
                    itemCount: services.length,
                    itemBuilder: (context, index) {
                      final service = services[index];
                      final methods = List<String>.from(
                        widget.methodsByService[service] ?? const <String>[],
                      )..sort();
                      final serviceIsSelected = service == widget.selectedService;
                      return ExpansionTile(
                        key: ValueKey('grpc-svc-$service'),
                        initiallyExpanded: serviceIsSelected,
                        tilePadding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                        childrenPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          service,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight:
                                serviceIsSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        children: methods.map((method) {
                          final methodIsSelected =
                              service == widget.selectedService && method == widget.selectedMethod;
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 20),
                            minVerticalPadding: 0,
                            title: Text(
                              method,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            selected: methodIsSelected,
                            selectedTileColor: colorScheme.secondaryContainer,
                            onTap: () => widget.onSelect(service, method),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrpcSchemaForm extends StatelessWidget {
  const _GrpcSchemaForm({
    required this.schema,
    required this.values,
    required this.onChanged,
  });

  final List<GrpcRequestFieldSchema> schema;
  final Map<String, dynamic> values;
  final void Function(GrpcRequestFieldSchema field, dynamic value) onChanged;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: schema.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final field = schema[index];
        final label = field.isRepeated
            ? '${field.jsonName} (repeated)'
            : field.jsonName;
        final currentValue = values[field.jsonName];

        switch (field.kind) {
          case GrpcFieldKind.boolType:
            return SwitchListTile(
              value: currentValue == true,
              onChanged: (v) => onChanged(field, v),
              title: Text(label),
              contentPadding: EdgeInsets.zero,
            );
          case GrpcFieldKind.enumType:
            return DropdownButtonFormField<String>(
              key: ValueKey('schema-${field.jsonName}'),
              isExpanded: true,
              value: currentValue is String && field.enumValues.contains(currentValue)
                  ? currentValue
                  : null,
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
              ),
              items: field.enumValues
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) => onChanged(field, v),
            );
          case GrpcFieldKind.message:
            return TextFormField(
              key: ValueKey('schema-${field.jsonName}'),
              initialValue: currentValue is Map
                  ? const JsonEncoder.withIndent('  ').convert(currentValue)
                  : (currentValue?.toString() ?? ''),
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: '$label (JSON object)',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged(field, v),
            );
          case GrpcFieldKind.intType:
          case GrpcFieldKind.doubleType:
            return TextFormField(
              key: ValueKey('schema-${field.jsonName}'),
              initialValue: currentValue?.toString() ?? '',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged(field, v),
            );
          case GrpcFieldKind.string:
          case GrpcFieldKind.bytes:
          case GrpcFieldKind.unknown:
            return TextFormField(
              key: ValueKey('schema-${field.jsonName}'),
              initialValue: currentValue is List
                  ? currentValue.join(', ')
                  : (currentValue?.toString() ?? ''),
              decoration: InputDecoration(
                labelText: label,
                helperText: field.kind == GrpcFieldKind.bytes
                    ? 'Bytes: enter text or comma-separated byte values for repeated fields'
                    : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged(field, v),
            );
        }
      },
    );
  }
}

class _GrpcMetadataEditor extends StatefulWidget {
  const _GrpcMetadataEditor({
    required this.metadata,
    required this.onChanged,
  });

  final Map<String, String> metadata;
  final ValueChanged<Map<String, String>> onChanged;

  @override
  State<_GrpcMetadataEditor> createState() => _GrpcMetadataEditorState();
}

class _GrpcMetadataEditorState extends State<_GrpcMetadataEditor> {
  late List<MapEntry<String, String>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = widget.metadata.entries.toList(growable: true);
    if (_entries.isEmpty) {
      _entries.add(const MapEntry('', ''));
    }
  }

  @override
  void didUpdateWidget(covariant _GrpcMetadataEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata != widget.metadata) {
      _entries = widget.metadata.entries.toList(growable: true);
      if (_entries.isEmpty) {
        _entries.add(const MapEntry('', ''));
      }
    }
  }

  void _emit() {
    final next = <String, String>{};
    for (final entry in _entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty) continue;
      next[k] = v;
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Metadata', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        ...List.generate(_entries.length, (index) {
          final entry = _entries[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: entry.key,
                    decoration: const InputDecoration(
                      labelText: 'Key',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    onChanged: (v) {
                      _entries[index] = MapEntry(v, _entries[index].value);
                      _emit();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: entry.value,
                    decoration: const InputDecoration(
                      labelText: 'Value',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    onChanged: (v) {
                      _entries[index] = MapEntry(_entries[index].key, v);
                      _emit();
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _entries.length == 1
                      ? null
                      : () {
                          setState(() {
                            _entries.removeAt(index);
                            if (_entries.isEmpty) {
                              _entries.add(const MapEntry('', ''));
                            }
                          });
                          _emit();
                        },
                ),
              ],
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _entries.add(const MapEntry('', ''));
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Add metadata'),
          ),
        ),
      ],
    );
  }
}

enum _GrpcResponseView {
  body('Body'),
  debug('Debug');

  const _GrpcResponseView(this.label);
  final String label;
}

class _GrpcResponsePanel extends StatefulWidget {
  const _GrpcResponsePanel({
    required this.session,
    required this.bytesDisplayMode,
    required this.onBytesDisplayModeChanged,
  });

  final GrpcSessionState session;
  final GrpcBytesDisplayMode bytesDisplayMode;
  final ValueChanged<GrpcBytesDisplayMode> onBytesDisplayModeChanged;

  @override
  State<_GrpcResponsePanel> createState() => _GrpcResponsePanelState();
}

class _GrpcResponsePanelState extends State<_GrpcResponsePanel> {
  _GrpcResponseView _view = _GrpcResponseView.body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final session = widget.session;

    if (session.status == GrpcCallStatus.idle) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.integration_instructions_rounded,
                size: 48,
                color: colorScheme.onSurface.withAlpha(80)),
            const SizedBox(height: 8),
            Text('Invoke a method to see the response',
                style: TextStyle(
                    color: colorScheme.onSurface.withAlpha(80))),
          ],
        ),
      );
    }

    if (session.status == GrpcCallStatus.calling) {
      return const Center(child: CircularProgressIndicator());
    }

    final result = session.result;
    if (result == null) return const SizedBox();
    final hasStreamResponses = result.streamResponses.isNotEmpty;
    final hasBytesFields = _responseHasBytesFields(result.responseJson);
    final renderedResponse = result.responseJson == null
      ? null
      : _prettyJson(result.responseJson!, widget.bytesDisplayMode);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row
          Row(
            children: [
              Text('Response',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 12),
              _StatusBadge(
                code: result.statusCode ?? '—',
                isError: result.errorMessage != null,
              ),
              if (result.responseDurationMs != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${result.responseDurationMs} ms',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
              const Spacer(),
              SizedBox(
                width: 110,
                child: DropdownButton<GrpcBytesDisplayMode>(
                  key: ValueKey('grpc-bytes-mode-${widget.bytesDisplayMode.name}'),
                  isExpanded: true,
                  value: widget.bytesDisplayMode,
                  items: GrpcBytesDisplayMode.values
                      .map(
                        (m) => DropdownMenuItem(
                          value: m,
                          child: Text(
                            m.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: hasBytesFields
                      ? (v) {
                          if (v == null) return;
                          widget.onBytesDisplayModeChanged(v);
                        }
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<_GrpcResponseView>(
            showSelectedIcon: false,
            segments: _GrpcResponseView.values
                .map(
                  (mode) => ButtonSegment<_GrpcResponseView>(
                    value: mode,
                    label: Text(mode.label),
                  ),
                )
                .toList(),
            selected: {_view},
            onSelectionChanged: (selection) {
              setState(() => _view = selection.first);
            },
          ),
          const SizedBox(height: 10),

          if (result.errorMessage != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(result.errorMessage!,
                  style: TextStyle(
                      color: colorScheme.onErrorContainer,
                      fontFamily: 'monospace')),
            )
          else if (_view == _GrpcResponseView.body && hasStreamResponses)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Stream Responses (${result.streamResponses.length})',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  ...result.streamResponses.asMap().entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          '#${entry.key + 1}\n${_prettyJson(entry.value, widget.bytesDisplayMode)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (_view == _GrpcResponseView.body && result.responseJson != null)
            // Pretty-print JSON
            Container(
              key: ValueKey('grpc-response-${widget.bytesDisplayMode.name}'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                renderedResponse!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),

          if (_view == _GrpcResponseView.debug && result.timeline.isNotEmpty) ...[
            const SizedBox(height: 10),
            _GrpcTimelineView(timeline: result.timeline),
          ],

          if (_view == _GrpcResponseView.debug && result.headers.isNotEmpty) ...[
            const SizedBox(height: 10),
            _GrpcMetadataView(
              title: 'Headers',
              entries: result.headers,
            ),
          ],

          if (_view == _GrpcResponseView.debug && result.trailers.isNotEmpty) ...[
            const SizedBox(height: 10),
            _GrpcMetadataView(
              title: 'Trailers',
              entries: result.trailers,
            ),
          ],

          if (_view == _GrpcResponseView.debug &&
              result.timeline.isEmpty &&
              result.headers.isEmpty &&
              result.trailers.isEmpty)
            Text(
              'No debug metadata available for this response.',
              style: Theme.of(context).textTheme.bodySmall,
            ),

          if (result.statusMessage != null) ...[
            const SizedBox(height: 8),
            Text(result.statusMessage!,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  String _prettyJson(String raw, GrpcBytesDisplayMode bytesMode) {
    try {
      final parsed = jsonDecode(raw);
      final transformed = _transformBytesForDisplay(parsed, bytesMode);
      return const JsonEncoder.withIndent('  ').convert(transformed);
    } catch (_) {
      return raw;
    }
  }

  dynamic _transformBytesForDisplay(
    dynamic node,
    GrpcBytesDisplayMode bytesMode,
  ) {
    if (node is List) {
      if (_looksLikeByteList(node)) {
        final bytes = Uint8List.fromList(node.cast<int>());
        return _renderBytes(bytes, bytesMode);
      }
      return node.map((e) => _transformBytesForDisplay(e, bytesMode)).toList();
    }

    if (node is Map) {
      final isBytes = node['__apidashBytes'] == true ||
          (node.containsKey('base64') && node.containsKey('raw'));
      if (isBytes) {
        final utf8Text = node['utf8'];
        final base64 = node['base64'];
        final raw = node['raw'];
        return switch (bytesMode) {
          GrpcBytesDisplayMode.utf8 => utf8Text ?? base64 ?? raw,
          GrpcBytesDisplayMode.base64 => base64 ?? utf8Text ?? raw,
          GrpcBytesDisplayMode.raw => raw ?? utf8Text ?? base64,
        };
      }

      final mapped = <String, dynamic>{};
      for (final entry in node.entries) {
        mapped[entry.key.toString()] =
            _transformBytesForDisplay(entry.value, bytesMode);
      }
      return mapped;
    }

    return node;
  }

  bool _looksLikeByteList(List<dynamic> value) {
    if (value.isEmpty) return false;
    for (final item in value) {
      if (item is! int || item < 0 || item > 255) {
        return false;
      }
    }
    return true;
  }

  dynamic _renderBytes(Uint8List bytes, GrpcBytesDisplayMode bytesMode) {
    String? utf8Text;
    try {
      utf8Text = utf8.decode(bytes);
    } catch (_) {
      utf8Text = null;
    }
    final base64Text = base64Encode(bytes);
    final raw = bytes.toList(growable: false);

    return switch (bytesMode) {
      GrpcBytesDisplayMode.utf8 => utf8Text ?? base64Text,
      GrpcBytesDisplayMode.base64 => base64Text,
      GrpcBytesDisplayMode.raw => raw,
    };
  }

  bool _responseHasBytesFields(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final parsed = jsonDecode(raw);
      return _containsBytesNode(parsed);
    } catch (_) {
      return false;
    }
  }

  bool _containsBytesNode(dynamic node) {
    if (node is List) {
      if (_looksLikeByteList(node)) {
        return true;
      }
      for (final item in node) {
        if (_containsBytesNode(item)) {
          return true;
        }
      }
      return false;
    }

    if (node is Map) {
      if (node['__apidashBytes'] == true ||
          (node.containsKey('base64') && node.containsKey('raw'))) {
        return true;
      }
      for (final value in node.values) {
        if (_containsBytesNode(value)) {
          return true;
        }
      }
    }

    return false;
  }
}

class _GrpcMetadataView extends StatelessWidget {
  const _GrpcMetadataView({
    required this.title,
    required this.entries,
  });

  final String title;
  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          ...entries.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText(
                '${entry.key}: ${entry.value}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GrpcTimelineView extends StatelessWidget {
  const _GrpcTimelineView({required this.timeline});

  final Map<String, int> timeline;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rows = <(String, int)>[
      ('DNS', timeline['dns'] ?? 0),
      ('Connect', timeline['connect'] ?? 0),
      ('TLS', timeline['tls'] ?? 0),
      ('Invoke', timeline['invoke'] ?? 0),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Timeline', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          ...rows.map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${row.$1}: ${row.$2} ms',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GrpcConnectButton extends StatelessWidget {
  const _GrpcConnectButton({
    required this.state,
    required this.isBusy,
    required this.onConnect,
    required this.onDisconnect,
  });

  final GrpcConnectionState state;
  final bool isBusy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      GrpcConnectionState.connecting => OutlinedButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('Connecting...'),
        ),
      GrpcConnectionState.connected => FilledButton.icon(
          onPressed: isBusy ? null : onDisconnect,
          icon: const Icon(Icons.stop_circle_rounded),
          label: const Text('Disconnect'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade700,
          ),
        ),
      GrpcConnectionState.disconnected => OutlinedButton.icon(
          onPressed: isBusy ? null : onConnect,
          icon: const Icon(Icons.hub_rounded),
          label: const Text('Connect & Discover'),
        ),
    };
  }
}

class _GrpcStatusStrip extends StatelessWidget {
  const _GrpcStatusStrip({required this.session});

  final GrpcSessionState session;

  @override
  Widget build(BuildContext context) {
    final statusText = switch (session.connectionState) {
      GrpcConnectionState.connected => 'Connected',
      GrpcConnectionState.connecting => 'Connecting',
      GrpcConnectionState.disconnected => 'Disconnected',
    };
    final statusColor = switch (session.connectionState) {
      GrpcConnectionState.connected => Colors.green,
      GrpcConnectionState.connecting => Colors.orange,
      GrpcConnectionState.disconnected => Colors.red,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: statusColor),
          const SizedBox(width: 8),
          Text(
            'Status: $statusText',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.code, required this.isError});
  final String code;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.red : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
