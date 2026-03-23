/// Supported gRPC call types.
enum GrpcCallType {
  unary('Unary'),
  serverStreaming('Server Streaming'),
  clientStreaming('Client Streaming'),
  bidirectionalStreaming('Bidirectional Streaming');

  const GrpcCallType(this.label);
  final String label;
}

/// How service/method descriptors were resolved for a gRPC endpoint.
enum GrpcDescriptorSource {
  unknown,
  reflection,
  protoUploadRequired,
  protoUpload,
}

/// Model representing the configuration and result for a gRPC request.
class GrpcRequestModel {
  const GrpcRequestModel({
    this.host = '',
    this.port = 443,
    this.useTls = true,
    this.serviceName = '',
    this.methodName = '',
    this.requestJson = '',
    this.metadata = const {},
    this.callType = GrpcCallType.unary,
    this.descriptorSource = GrpcDescriptorSource.unknown,
    this.availableServices = const [],
    this.methodsByService = const {},
    this.protoFiles = const [],
    this.responseJson,
    this.statusCode,
    this.statusMessage,
    this.trailers = const {},
    this.errorMessage,
    this.responseDurationMs,
  });

  // ── Connection ──────────────────────────────────────────
  /// Host without scheme, e.g. `grpc.example.com` or `localhost`.
  final String host;
  final int port;

  /// Use TLS (`grpcs://`) if true, plain-text (`grpc://`) if false.
  final bool useTls;

  // ── Method ───────────────────────────────────────────────
  /// Fully-qualified service name, e.g. `helloworld.Greeter`.
  final String serviceName;

  /// RPC method name, e.g. `SayHello`.
  final String methodName;

  /// JSON-encoded request body, mirroring the Protobuf message structure.
  final String requestJson;

  /// Per-call gRPC metadata (equivalent to HTTP headers).
  final Map<String, String> metadata;

  final GrpcCallType callType;

  /// Indicates where method descriptors came from.
  final GrpcDescriptorSource descriptorSource;

  /// Service names discovered from reflection or uploaded proto files.
  final List<String> availableServices;

  /// Methods grouped by fully-qualified service name.
  final Map<String, List<String>> methodsByService;

  /// Uploaded proto file paths used as a fallback when reflection is unavailable.
  final List<String> protoFiles;

  // ── Response ─────────────────────────────────────────────
  /// JSON-decoded response from the server (null until a call completes).
  final String? responseJson;

  /// gRPC status code string, e.g. `"OK"`, `"NOT_FOUND"`.
  final String? statusCode;

  final String? statusMessage;

  /// Response trailers returned by the server.
  final Map<String, String> trailers;

  /// Populated when the call fails with a gRPC or transport error.
  final String? errorMessage;

  final int? responseDurationMs;

  bool get hasResponse => responseJson != null || errorMessage != null;

  GrpcRequestModel copyWith({
    String? host,
    int? port,
    bool? useTls,
    String? serviceName,
    String? methodName,
    String? requestJson,
    Map<String, String>? metadata,
    GrpcCallType? callType,
    GrpcDescriptorSource? descriptorSource,
    List<String>? availableServices,
    Map<String, List<String>>? methodsByService,
    List<String>? protoFiles,
    String? responseJson,
    String? statusCode,
    String? statusMessage,
    Map<String, String>? trailers,
    String? errorMessage,
    int? responseDurationMs,
  }) {
    return GrpcRequestModel(
      host: host ?? this.host,
      port: port ?? this.port,
      useTls: useTls ?? this.useTls,
      serviceName: serviceName ?? this.serviceName,
      methodName: methodName ?? this.methodName,
      requestJson: requestJson ?? this.requestJson,
      metadata: metadata ?? this.metadata,
      callType: callType ?? this.callType,
      descriptorSource: descriptorSource ?? this.descriptorSource,
      availableServices: availableServices ?? this.availableServices,
      methodsByService: methodsByService ?? this.methodsByService,
      protoFiles: protoFiles ?? this.protoFiles,
      responseJson: responseJson ?? this.responseJson,
      statusCode: statusCode ?? this.statusCode,
      statusMessage: statusMessage ?? this.statusMessage,
      trailers: trailers ?? this.trailers,
      errorMessage: errorMessage ?? this.errorMessage,
      responseDurationMs: responseDurationMs ?? this.responseDurationMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GrpcRequestModel &&
          other.host == host &&
          other.port == port &&
          other.serviceName == serviceName &&
          other.methodName == methodName;

  @override
  int get hashCode =>
      Object.hash(host, port, serviceName, methodName);
}
