import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_networking/better_networking.dart';
import 'package:grpc/grpc.dart' as $grpc;

import '../generated/google/protobuf/descriptor.pb.dart'
    as $descriptor;
import '../generated/grpc/reflection/v1alpha/reflection.pb.dart'
    as $reflection;
import '../generated/grpc/reflection/v1alpha/reflection.pbgrpc.dart'
    as $reflection_grpc;

enum GrpcFieldKind {
  string,
  bytes,
  boolType,
  intType,
  doubleType,
  enumType,
  message,
  unknown,
}

class GrpcRequestFieldSchema {
  const GrpcRequestFieldSchema({
    required this.name,
    required this.jsonName,
    required this.kind,
    required this.isRepeated,
    this.enumValues = const [],
    this.messageType,
  });

  final String name;
  final String jsonName;
  final GrpcFieldKind kind;
  final bool isRepeated;
  final List<String> enumValues;
  final String? messageType;
}

/// Executes gRPC calls described by a [GrpcRequestModel].
///
/// Uses native in-process reflection-driven descriptor resolution and dynamic
/// protobuf encode/decode for unary calls without external tools or generated stubs.
class GrpcService {
  // Cache for descriptor graphs: "host:port" -> resolved file descriptors
  static final Map<String, Map<String, $descriptor.FileDescriptorProto>>
      _descriptorCache = {};

  // Cache for method input/output message types: "Service/Method" -> (inputType, outputType)
  static final Map<String, (String, String)> _methodTypeCache = {};

  // Reuse channels per endpoint to avoid disconnect/reconnect between invocations.
  final Map<String, $grpc.ClientChannel> _channelPool = {};

  String _channelKey(String host, int port, bool useTls) =>
      '$host:$port:${useTls ? 'tls' : 'insecure'}';

  /// Discovers services/methods for an endpoint using reflection first.
  ///
  /// If reflection is unavailable, returns [GrpcDescriptorSource.protoUploadRequired]
  /// so the UI can require proto upload fallback.
  Future<GrpcRequestModel> discover(GrpcRequestModel model) async {
    final endpoint = '${model.host}:${model.port}';
    try {
      final descriptors = await _loadDescriptorsViaReflection(
        host: model.host,
        port: model.port,
        useTls: model.useTls,
      );
      _descriptorCache[endpoint] = descriptors;
      final discovered = _extractServicesAndMethods(descriptors);

      return model.copyWith(
        descriptorSource: GrpcDescriptorSource.reflection,
        availableServices: discovered.$1,
        methodsByService: discovered.$2,
        statusCode: 'OK',
        statusMessage: 'Reflection discovery completed',
        errorMessage: null,
      );
    } catch (e) {
      return model.copyWith(
        descriptorSource: GrpcDescriptorSource.protoUploadRequired,
        availableServices: const [],
        methodsByService: const {},
        statusCode: 'UNAVAILABLE',
        statusMessage: 'Reflection unavailable. Upload .proto files to continue.',
        errorMessage: e.toString(),
      );
    }
  }

  /// Executes a **unary** RPC call and returns an updated [GrpcRequestModel]
  /// populated with the response (or error).
  Future<GrpcRequestModel> callUnary(GrpcRequestModel model) async {
    final stopwatch = Stopwatch()..start();
    try {
      if (model.callType != GrpcCallType.unary) {
        throw UnsupportedError('Only unary gRPC calls are currently supported');
      }

      // Validate JSON early to provide immediate user feedback.
      final jsonPayload = model.requestJson.trim().isEmpty
          ? {}
          : jsonDecode(model.requestJson);

      // Build/cache descriptor graph for the service.
      final endpoint = '${model.host}:${model.port}';
      final cacheKey = endpoint;

      final descriptors = _descriptorCache[cacheKey] ??
          await _loadDescriptorsViaReflection(
            host: model.host,
            port: model.port,
            useTls: model.useTls,
            targetSymbol: '${model.serviceName}.${model.methodName}',
          );
      _descriptorCache[cacheKey] = descriptors;

      // Find the method and its input/output types.
      final (inputTypeStr, outputTypeStr) =
          _resolveMethodTypes(model.serviceName, model.methodName, descriptors);

      // Encode JSON request as protobuf bytes.
      final requestBytes = _jsonToProtobuf(
        jsonPayload,
        inputTypeStr,
        descriptors,
      );

      // Execute unary call over gRPC channel.
      final responseBytes = await _callUnaryMethod(
        model.host,
        model.port,
        model.useTls,
        model.serviceName,
        model.methodName,
        requestBytes,
        model.metadata,
      );

      // Decode response bytes back to JSON.
      final responseJson = _protobufToJson(
        responseBytes,
        outputTypeStr,
        descriptors,
      );

      stopwatch.stop();
      return model.copyWith(
        responseJson: responseJson,
        statusCode: 'OK',
        statusMessage: 'gRPC unary invocation completed',
        responseDurationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      final errorMsg =
          e is _GrpcServiceException ? e.message : e.toString();
      final reflectionFailed = errorMsg.toLowerCase().contains('reflection');
      return model.copyWith(
        descriptorSource: reflectionFailed
            ? GrpcDescriptorSource.protoUploadRequired
            : model.descriptorSource,
        errorMessage: errorMsg,
        statusCode: reflectionFailed ? 'UNAVAILABLE' : 'UNKNOWN',
        statusMessage: reflectionFailed
            ? 'Reflection unavailable. Upload .proto files to continue.'
            : model.statusMessage,
        responseDurationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  Future<List<GrpcRequestFieldSchema>> getRequestSchema(
    GrpcRequestModel model,
  ) async {
    final endpoint = '${model.host}:${model.port}';
    final descriptors = _descriptorCache[endpoint] ??
        await _loadDescriptorsViaReflection(
          host: model.host,
          port: model.port,
          useTls: model.useTls,
          targetSymbol: '${model.serviceName}.${model.methodName}',
        );
    _descriptorCache[endpoint] = descriptors;

    final (inputTypeStr, _) =
        _resolveMethodTypes(model.serviceName, model.methodName, descriptors);
    final messageDesc = _findMessageDescriptor(inputTypeStr, descriptors);
    if (messageDesc == null) {
      throw _GrpcServiceException('Input message type not found: $inputTypeStr');
    }

    return messageDesc.field.map((field) {
      final kind = _kindForField(field);
      return GrpcRequestFieldSchema(
        name: field.name,
        jsonName: field.jsonName.isEmpty ? field.name : field.jsonName,
        kind: kind,
        isRepeated: field.label.value == 3,
        enumValues: kind == GrpcFieldKind.enumType
            ? _resolveEnumValues(field.typeName, descriptors)
            : const [],
        messageType: kind == GrpcFieldKind.message ? field.typeName : null,
      );
    }).toList(growable: false);
  }

  /// Resolves service descriptors via server reflection.
  Future<Map<String, $descriptor.FileDescriptorProto>> _loadDescriptorsViaReflection({
    required String host,
    required int port,
    required bool useTls,
    String? targetSymbol,
  }) async {
    final channel = _getOrCreateChannel(host, port, useTls);

    final client = $reflection_grpc.ServerReflectionClient(channel);
    final descriptorMap = <String, $descriptor.FileDescriptorProto>{};

    if (targetSymbol == null || targetSymbol.isEmpty) {
      final services = await _listServices(client, host);
      for (final service in services) {
        await _fetchDescriptorsForSymbol(
          client: client,
          host: host,
          symbol: service,
          descriptorMap: descriptorMap,
        );
      }
    } else {
      await _fetchDescriptorsForSymbol(
        client: client,
        host: host,
        symbol: targetSymbol,
        descriptorMap: descriptorMap,
      );
    }

    return descriptorMap;
  }

  Future<List<String>> _listServices(
    $reflection_grpc.ServerReflectionClient client,
    String host,
  ) async {
    final req = $reflection.ServerReflectionRequest()
      ..host = host
      ..listServices = '*';
    final responseStream = client.serverReflectionInfo(Stream.value(req));
    await for (final resp in responseStream) {
      if (resp.hasListServicesResponse()) {
        return resp.listServicesResponse.service
            .map((s) => s.name)
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
      }
      if (resp.hasErrorResponse()) {
        throw _GrpcServiceException(
          'Reflection listServices failed: ${resp.errorResponse.errorMessage}',
        );
      }
    }
    return const [];
  }

  Future<void> _fetchDescriptorsForSymbol({
    required $reflection_grpc.ServerReflectionClient client,
    required String host,
    required String symbol,
    required Map<String, $descriptor.FileDescriptorProto> descriptorMap,
  }) async {
    final req = $reflection.ServerReflectionRequest()
      ..host = host
      ..fileContainingSymbol = symbol;

    final responseStream = client.serverReflectionInfo(Stream.value(req));
    await for (final resp in responseStream) {
      if (resp.hasFileDescriptorResponse()) {
        for (final fdBytes in resp.fileDescriptorResponse.fileDescriptorProto) {
          final fd = $descriptor.FileDescriptorProto.fromBuffer(fdBytes);
          if (!descriptorMap.containsKey(fd.name)) {
            descriptorMap[fd.name] = fd;
          }
          for (final dep in fd.dependency) {
            if (!descriptorMap.containsKey(dep)) {
              await _resolveDescriptorsForFile(client, dep, descriptorMap, host);
            }
          }
        }
      } else if (resp.hasErrorResponse()) {
        throw _GrpcServiceException(
          'Reflection symbol lookup failed: ${resp.errorResponse.errorMessage}',
        );
      }
    }
  }

  /// Recursively resolves a file descriptor dependency.
  Future<void> _resolveDescriptorsForFile(
    $reflection_grpc.ServerReflectionClient client,
    String filename,
    Map<String, $descriptor.FileDescriptorProto> descriptorMap,
    String host,
  ) async {
    if (descriptorMap.containsKey(filename)) return;

    final req = $reflection.ServerReflectionRequest();
    req.host = host;
    req.fileByFilename = filename;

    final requestStream = Stream.fromIterable([req]);
    final responseStream = client.serverReflectionInfo(requestStream);

    await for (final resp in responseStream) {
      if (resp.hasFileDescriptorResponse()) {
        for (final fdBytes in resp.fileDescriptorResponse.fileDescriptorProto) {
          final fd = $descriptor.FileDescriptorProto.fromBuffer(fdBytes);
          descriptorMap[fd.name] = fd;

          for (final dep in fd.dependency) {
            if (!descriptorMap.containsKey(dep)) {
              // Recursion for dependencies.
            }
          }
        }
      }
    }
  }

  (List<String>, Map<String, List<String>>) _extractServicesAndMethods(
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    final services = <String>[];
    final methodsByService = <String, List<String>>{};
    for (final file in descriptors.values) {
      for (final service in file.service) {
        final fullServiceName = file.package.isEmpty
            ? service.name
            : '${file.package}.${service.name}';
        services.add(fullServiceName);
        methodsByService[fullServiceName] =
            service.method.map((m) => m.name).toList(growable: false);
      }
    }
    services.sort();
    return (services, methodsByService);
  }

  /// Resolves the input and output type names for a method.
  (String, String) _resolveMethodTypes(
    String serviceName,
    String methodName,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    final cacheKey = '$serviceName/$methodName';
    if (_methodTypeCache.containsKey(cacheKey)) {
      return _methodTypeCache[cacheKey]!;
    }

    // Find service descriptor.
    $descriptor.ServiceDescriptorProto? serviceDesc;
    String? servicePackage;
    for (final fd in descriptors.values) {
      for (final svc in fd.service) {
        if (svc.name == serviceName ||
            '${fd.package}.${svc.name}' == serviceName ||
            svc.name == serviceName.split('.').last) {
          serviceDesc = svc;
          servicePackage = fd.package;
          break;
        }
      }
      if (serviceDesc != null) break;
    }

    if (serviceDesc == null) {
      throw _GrpcServiceException('Service not found: $serviceName');
    }

    // Find method descriptor.
    $descriptor.MethodDescriptorProto? methodDesc;
    for (final method in serviceDesc.method) {
      if (method.name == methodName) {
        methodDesc = method;
        break;
      }
    }

    if (methodDesc == null) {
      throw _GrpcServiceException(
        'Method $methodName not found in service $serviceName',
      );
    }

    // Resolve input/output type names (fully qualified if not already).
    var inputType = methodDesc.inputType;
    var outputType = methodDesc.outputType;

    if (!inputType.startsWith('.')) {
      inputType = servicePackage != null && servicePackage.isNotEmpty
          ? '.$servicePackage.$inputType'
          : '.$inputType';
    }
    if (!outputType.startsWith('.')) {
      outputType = servicePackage != null && servicePackage.isNotEmpty
          ? '.$servicePackage.$outputType'
          : '.$outputType';
    }

    final result = (inputType, outputType);
    _methodTypeCache[cacheKey] = result;
    return result;
  }

  /// Converts JSON to protobuf bytes using the descriptor.
  List<int> _jsonToProtobuf(
    dynamic jsonPayload,
    String typeName,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    // Find the message descriptor.
    final messageDesc = _findMessageDescriptor(typeName, descriptors);
    if (messageDesc == null) {
      throw _GrpcServiceException('Message type not found: $typeName');
    }

    // Build a dynamic message and populate from JSON.
    final msg = _DynamicMessage(messageDesc);
    msg.mergeFromJson(jsonPayload as Map<String, dynamic>? ?? {}, descriptors);

    return msg.toBuffer();
  }

  /// Converts protobuf bytes to JSON using the descriptor.
  String _protobufToJson(
    List<int> bytes,
    String typeName,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    final messageDesc = _findMessageDescriptor(typeName, descriptors);
    if (messageDesc == null) {
      throw _GrpcServiceException('Message type not found: $typeName');
    }

    final msg = _DynamicMessage(messageDesc);
    msg.mergeFromBuffer(bytes, descriptors);
    final jsonMap = msg.toJson(descriptors);

    return const JsonEncoder.withIndent('  ').convert(jsonMap);
  }

  /// Finds a message descriptor by fully-qualified name.
  $descriptor.DescriptorProto? _findMessageDescriptor(
    String typeName,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    // Remove leading dot if present.
    var name = typeName;
    if (name.startsWith('.')) {
      name = name.substring(1);
    }

    for (final fd in descriptors.values) {
      for (final msg in fd.messageType) {
        final fullName = fd.package.isEmpty
            ? msg.name
            : '${fd.package}.${msg.name}';
        if (fullName == name || msg.name == name) {
          return msg;
        }
      }
    }
    return null;
  }

  /// Executes a unary method call over the gRPC channel.
  Future<List<int>> _callUnaryMethod(
    String host,
    int port,
    bool useTls,
    String serviceName,
    String methodName,
    List<int> requestBytes,
    Map<String, String> metadata,
  ) async {
    final channel = _getOrCreateChannel(host, port, useTls);

    final method = $grpc.ClientMethod<List<int>, List<int>>(
      '/$serviceName/$methodName',
      // Request encoder.
      (List<int> value) => value,
      // Response decoder.
      (List<int> value) => value,
    );

    final callOptions = $grpc.CallOptions(
      metadata: metadata,
      timeout: const Duration(seconds: 30),
    );

    final call = channel.createCall(
      method,
      Stream.fromIterable([requestBytes]),
      callOptions,
    );

    final responses = <List<int>>[];
    // Access the response stream via call.response property
    await for (final resp in call.response) {
      responses.add(resp);
    }

    if (responses.isEmpty) {
      throw _GrpcServiceException('No response from server');
    }

    return responses.first;
  }

  $grpc.ClientChannel _getOrCreateChannel(String host, int port, bool useTls) {
    final key = _channelKey(host, port, useTls);
    final cached = _channelPool[key];
    if (cached != null) return cached;

    final channel = $grpc.ClientChannel(
      host,
      port: port,
      options: $grpc.ChannelOptions(
        credentials: useTls
            ? const $grpc.ChannelCredentials.secure()
            : const $grpc.ChannelCredentials.insecure(),
      ),
    );
    _channelPool[key] = channel;
    return channel;
  }

  GrpcFieldKind _kindForField($descriptor.FieldDescriptorProto field) {
    switch (field.type.value) {
      case 1: // TYPE_DOUBLE
      case 2: // TYPE_FLOAT
        return GrpcFieldKind.doubleType;
      case 3: // TYPE_INT64
      case 4: // TYPE_UINT64
      case 5: // TYPE_INT32
      case 6: // TYPE_FIXED64
      case 7: // TYPE_FIXED32
      case 13: // TYPE_UINT32
      case 15: // TYPE_SFIXED32
      case 16: // TYPE_SFIXED64
      case 17: // TYPE_SINT32
      case 18: // TYPE_SINT64
        return GrpcFieldKind.intType;
      case 8: // TYPE_BOOL
        return GrpcFieldKind.boolType;
      case 9: // TYPE_STRING
        return GrpcFieldKind.string;
      case 12: // TYPE_BYTES
        return GrpcFieldKind.bytes;
      case 11: // TYPE_MESSAGE
        return GrpcFieldKind.message;
      case 14: // TYPE_ENUM
        return GrpcFieldKind.enumType;
      default:
        return GrpcFieldKind.unknown;
    }
  }

  List<String> _resolveEnumValues(
    String typeName,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    var normalized = typeName;
    if (normalized.startsWith('.')) {
      normalized = normalized.substring(1);
    }

    for (final fd in descriptors.values) {
      for (final enumDesc in fd.enumType) {
        final fullName = fd.package.isEmpty
            ? enumDesc.name
            : '${fd.package}.${enumDesc.name}';
        if (fullName == normalized || enumDesc.name == normalized) {
          return enumDesc.value.map((v) => v.name).toList(growable: false);
        }
      }
    }
    return const [];
  }

  Future<void> disconnectEndpoint(String host, int port, bool useTls) async {
    final key = _channelKey(host, port, useTls);
    final channel = _channelPool.remove(key);
    if (channel != null) {
      await channel.shutdown();
    }
  }

  Future<void> shutdown() async {
    final channels = _channelPool.values.toList(growable: false);
    _channelPool.clear();
    await Future.wait(channels.map((c) => c.shutdown()));
  }
}

/// Simple dynamic message builder for JSON<->Protobuf conversion.
class _DynamicMessage {
  final $descriptor.DescriptorProto descriptor;
  final Map<int, dynamic> fields = {};

  _DynamicMessage(this.descriptor);

  void mergeFromJson(
    Map<String, dynamic> json,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    for (final field in descriptor.field) {
      final jsonKey = field.jsonName.isEmpty ? field.name : field.jsonName;
      if (!json.containsKey(jsonKey)) continue;

      final value = json[jsonKey];
      fields[field.number] = _coerceJsonValue(value, field, descriptors);
    }
  }

  void mergeFromBuffer(
    List<int> buffer,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    // Simple protobuf decoding: extract varint-encoded tag-value pairs.
    var offset = 0;
    final bufferView = Uint8List.fromList(buffer);
    while (offset < buffer.length) {
      final (tag, wireType, newOffset) = _readFieldTag(bufferView, offset);
      offset = newOffset;

      final fieldNum = tag >> 3;
      final field = descriptor.field.firstWhereOrNull((f) => f.number == fieldNum);
      if (field == null) {
        // Skip unknown field.
        (_, offset) = _skipField(bufferView, offset, wireType);
        continue;
      }

      final (value, newOff) = _readFieldValue(
        bufferView,
        offset,
        wireType,
        field,
        descriptors,
      );
      fields[fieldNum] = value;
      offset = newOff;
    }
  }

  List<int> toBuffer() {
    final result = <int>[];
    for (final entry in fields.entries) {
      final field = descriptor.field.firstWhereOrNull((f) => f.number == entry.key);
      if (field == null) continue;

      final fieldTag = (entry.key << 3) | _wireTypeForField(field);
      _appendVarint(result, fieldTag);

      final value = entry.value;
      if (value == null) continue;

      final labelValue = field.label.value;
      if (labelValue == 3) {
        // LABEL_REPEATED
        final list = value as List<dynamic>;
        for (final item in list) {
          _appendFieldValue(result, item, field);
        }
      } else {
        _appendFieldValue(result, value, field);
      }
    }
    return result;
  }

  Map<String, dynamic> toJson(
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    final result = <String, dynamic>{};
    for (final entry in fields.entries) {
      final field =
          descriptor.field.firstWhereOrNull((f) => f.number == entry.key);
      if (field == null) continue;

      final jsonKey = field.jsonName.isEmpty ? field.name : field.jsonName;
      result[jsonKey] = _valueToJson(entry.value, field, descriptors);
    }
    return result;
  }

  dynamic _coerceJsonValue(
    dynamic jsonValue,
    $descriptor.FieldDescriptorProto field,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    if (jsonValue == null) return null;

    final typeValue = field.type.value;
    switch (typeValue) {
      case 1: // TYPE_DOUBLE
      case 2: // TYPE_FLOAT
        return (jsonValue as num).toDouble();
      case 3: // TYPE_INT64
      case 4: // TYPE_UINT64
      case 5: // TYPE_INT32
      case 6: // TYPE_FIXED64
      case 7: // TYPE_FIXED32
      case 13: // TYPE_UINT32
      case 15: // TYPE_SFIXED32
      case 16: // TYPE_SFIXED64
      case 17: // TYPE_SINT32
      case 18: // TYPE_SINT64
        return (jsonValue as num).toInt();
      case 8: // TYPE_BOOL
        return jsonValue as bool;
      case 9: // TYPE_STRING
        return jsonValue.toString();
      case 12: // TYPE_BYTES
        if (jsonValue is List) {
          return Uint8List.fromList(jsonValue.whereType<num>().map((e) => e.toInt()).toList());
        }
        return utf8.encode(jsonValue.toString());
      case 11: // TYPE_MESSAGE
      case 14: // TYPE_ENUM
        return jsonValue;
      default:
        return jsonValue;
    }
  }

  dynamic _valueToJson(
    dynamic value,
    $descriptor.FieldDescriptorProto field,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    if (value == null) return null;
    final labelValue = field.label.value;
    if (labelValue == 3 && value is List) {
      // LABEL_REPEATED
      return value
          .map((v) => _valueToJson(v, field, descriptors))
          .toList();
    }

    if (field.type.value == 12) {
      final bytes = value is Uint8List
          ? value
          : (value is List<int>
              ? Uint8List.fromList(value)
              : Uint8List.fromList(utf8.encode(value.toString())));
      String? utf8Text;
      try {
        utf8Text = utf8.decode(bytes);
      } catch (_) {
        utf8Text = null;
      }
      return {
        '__apidashBytes': true,
        if (utf8Text != null) 'utf8': utf8Text,
        'base64': base64Encode(bytes),
        'raw': bytes.toList(growable: false),
      };
    }

    return value;
  }

  static (int, int, int) _readFieldTag(Uint8List buffer, int offset) {
    final (tag, newOff) = _readVarint(buffer, offset);
    final wireType = tag & 0x07;
    return (tag, wireType, newOff);
  }

  static (int, int) _readVarint(Uint8List buffer, int offset) {
    int value = 0;
    int shift = 0;
    int i = offset;
    while (i < buffer.length) {
      final byte = buffer[i++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return (value, i);
  }

  static void _appendVarint(List<int> buffer, int value) {
    while ((value & 0xffffff80) != 0) {
      buffer.add((value & 0x7f) | 0x80);
      value >>= 7;
    }
    buffer.add(value & 0x7f);
  }

  static (dynamic, int) _readFieldValue(
    Uint8List buffer,
    int offset,
    int wireType,
    $descriptor.FieldDescriptorProto field,
    Map<String, $descriptor.FileDescriptorProto> descriptors,
  ) {
    if (wireType == 0) {
      // Varint
      return _readVarint(buffer, offset);
    } else if (wireType == 1) {
      // Fixed64
      return (
        Uint8List.sublistView(buffer, offset, offset + 8),
        offset + 8
      );
    } else if (wireType == 2) {
      // Length-delimited
      final (len, newOff) = _readVarint(buffer, offset);
      final bytes = Uint8List.sublistView(buffer, newOff, newOff + len);
      final typeValue = field.type.value;

      if (typeValue == 9) {
        // TYPE_STRING
        try {
          return (utf8.decode(bytes), newOff + len);
        } catch (_) {
          return (bytes, newOff + len);
        }
      }

      if (typeValue == 12) {
        // TYPE_BYTES
        return (bytes, newOff + len);
      }

      return (bytes, newOff + len);
    } else if (wireType == 5) {
      // Fixed32
      return (
        Uint8List.sublistView(buffer, offset, offset + 4),
        offset + 4
      );
    }
    throw _GrpcServiceException('Unsupported wire type: $wireType');
  }

  static (dynamic, int) _skipField(
    Uint8List buffer,
    int offset,
    int wireType,
  ) {
    if (wireType == 0) {
      return _readVarint(buffer, offset);
    } else if (wireType == 1) {
      return (null, offset + 8);
    } else if (wireType == 2) {
      final (len, newOff) = _readVarint(buffer, offset);
      return (null, newOff + len);
    } else if (wireType == 5) {
      return (null, offset + 4);
    }
    throw _GrpcServiceException('Unsupported wire type: $wireType');
  }

  static void _appendFieldValue(
    List<int> buffer,
    dynamic value,
    $descriptor.FieldDescriptorProto field,
  ) {
    if (value is int) {
      _appendVarint(buffer, value);
    } else if (value is double) {
      final data = ByteData(8);
      data.setFloat64(0, value, Endian.little);
      buffer.addAll(data.buffer.asUint8List(0, 8));
    } else if (value is bool) {
      _appendVarint(buffer, value ? 1 : 0);
    } else if (value is String) {
      final bytes = utf8.encode(value);
      _appendVarint(buffer, bytes.length);
      buffer.addAll(bytes);
    } else if (value is List<int>) {
      _appendVarint(buffer, value.length);
      buffer.addAll(value);
    } else if (value is Uint8List) {
      _appendVarint(buffer, value.length);
      buffer.addAll(value);
    }
  }

  static int _wireTypeForField($descriptor.FieldDescriptorProto field) {
    final typeValue = field.type.value;
    switch (typeValue) {
      case 1:
      case 2:
        return 5; // 32-bit fixed or float
      case 3:
      case 4:
      case 5:
      case 6:
      case 7:
      case 13:
      case 15:
      case 16:
      case 17:
      case 18:
        return 0; // Varint
      case 8:
      case 9:
      case 12:
        return 2; // Length-delimited
      case 11:
      case 14:
        return 2; // MESSAGE or ENUM
      default:
        return 0;
    }
  }
}

class _GrpcServiceException implements Exception {
  const _GrpcServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
