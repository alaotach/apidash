import 'package:flutter_riverpod/legacy.dart';
import 'package:better_networking/better_networking.dart';
import '../services/grpc_service.dart';

enum GrpcCallStatus { idle, calling, done, error }

enum GrpcConnectionState { disconnected, connecting, connected }

enum GrpcDiscoveryStatus {
  idle,
  discovering,
  discovered,
  requiresProtoUpload,
  error,
}

class GrpcSessionState {
  const GrpcSessionState({
    this.status = GrpcCallStatus.idle,
    this.connectionState = GrpcConnectionState.disconnected,
    this.discoveryStatus = GrpcDiscoveryStatus.idle,
    this.discoveredServices = const [],
    this.methodsByService = const {},
    this.requestSchema = const [],
    this.isSchemaLoading = false,
    this.schemaError,
    this.discoveryMessage,
    this.result,
  });

  final GrpcCallStatus status;
  final GrpcConnectionState connectionState;
  final GrpcDiscoveryStatus discoveryStatus;
  final List<String> discoveredServices;
  final Map<String, List<String>> methodsByService;
  final List<GrpcRequestFieldSchema> requestSchema;
  final bool isSchemaLoading;
  final String? schemaError;
  final String? discoveryMessage;

  /// The model is populated with response fields after a successful call.
  final GrpcRequestModel? result;

  bool get isLoading => status == GrpcCallStatus.calling;
  bool get isConnected => connectionState == GrpcConnectionState.connected;

  GrpcSessionState copyWith({
    GrpcCallStatus? status,
    GrpcConnectionState? connectionState,
    GrpcDiscoveryStatus? discoveryStatus,
    List<String>? discoveredServices,
    Map<String, List<String>>? methodsByService,
    List<GrpcRequestFieldSchema>? requestSchema,
    bool? isSchemaLoading,
    String? schemaError,
    String? discoveryMessage,
    GrpcRequestModel? result,
  }) {
    return GrpcSessionState(
      status: status ?? this.status,
      connectionState: connectionState ?? this.connectionState,
      discoveryStatus: discoveryStatus ?? this.discoveryStatus,
      discoveredServices: discoveredServices ?? this.discoveredServices,
      methodsByService: methodsByService ?? this.methodsByService,
      requestSchema: requestSchema ?? this.requestSchema,
      isSchemaLoading: isSchemaLoading ?? this.isSchemaLoading,
      schemaError: schemaError,
      discoveryMessage: discoveryMessage ?? this.discoveryMessage,
      result: result ?? this.result,
    );
  }
}

class GrpcNotifier extends StateNotifier<GrpcSessionState> {
  GrpcNotifier() : super(const GrpcSessionState());

  final _service = GrpcService();

  Future<void> discover(GrpcRequestModel model) async {
    state = state.copyWith(
      connectionState: GrpcConnectionState.connecting,
      discoveryStatus: GrpcDiscoveryStatus.discovering,
      discoveryMessage: null,
    );
    try {
      final discoveredModel = await _service.discover(model);
      final requiresUpload =
          discoveredModel.descriptorSource == GrpcDescriptorSource.protoUploadRequired;
      state = state.copyWith(
        connectionState: requiresUpload
            ? GrpcConnectionState.disconnected
            : GrpcConnectionState.connected,
        discoveryStatus: requiresUpload
            ? GrpcDiscoveryStatus.requiresProtoUpload
            : GrpcDiscoveryStatus.discovered,
        discoveredServices: discoveredModel.availableServices,
        methodsByService: discoveredModel.methodsByService,
        discoveryMessage: discoveredModel.statusMessage,
        result: discoveredModel,
      );

      if (!requiresUpload &&
          discoveredModel.serviceName.isNotEmpty &&
          discoveredModel.methodName.isNotEmpty) {
        await loadRequestSchema(discoveredModel);
      }
    } catch (e) {
      state = state.copyWith(
        connectionState: GrpcConnectionState.disconnected,
        discoveryStatus: GrpcDiscoveryStatus.error,
        discoveryMessage: e.toString(),
      );
    }
  }

  Future<void> executeUnary(GrpcRequestModel model) async {
    final previousState = state;
    state = previousState.copyWith(
      status: GrpcCallStatus.calling,
      discoveryMessage: null,
    );
    try {
      final result = await _service.callUnary(model);
      state = GrpcSessionState(
        status: result.errorMessage != null
            ? GrpcCallStatus.error
            : GrpcCallStatus.done,
        connectionState: previousState.connectionState,
        discoveryStatus:
            result.descriptorSource == GrpcDescriptorSource.protoUploadRequired
                ? GrpcDiscoveryStatus.requiresProtoUpload
                : previousState.discoveryStatus,
        discoveredServices: previousState.discoveredServices,
        methodsByService: previousState.methodsByService,
        requestSchema: previousState.requestSchema,
        isSchemaLoading: false,
        schemaError: previousState.schemaError,
        discoveryMessage: result.statusMessage,
        result: result,
      );
    } catch (e) {
      state = GrpcSessionState(
        status: GrpcCallStatus.error,
        connectionState: previousState.connectionState,
        discoveryStatus: previousState.discoveryStatus,
        discoveredServices: previousState.discoveredServices,
        methodsByService: previousState.methodsByService,
        requestSchema: previousState.requestSchema,
        isSchemaLoading: false,
        schemaError: previousState.schemaError,
        discoveryMessage: previousState.discoveryMessage,
        result: model.copyWith(errorMessage: e.toString(), statusCode: 'UNKNOWN'),
      );
    }
  }

  Future<void> loadRequestSchema(GrpcRequestModel model) async {
    if (model.serviceName.trim().isEmpty || model.methodName.trim().isEmpty) {
      state = state.copyWith(
        requestSchema: const [],
        isSchemaLoading: false,
        schemaError: null,
      );
      return;
    }

    state = state.copyWith(isSchemaLoading: true, schemaError: null);
    try {
      final schema = await _service.getRequestSchema(model);
      state = state.copyWith(
        requestSchema: schema,
        isSchemaLoading: false,
        schemaError: null,
      );
    } catch (e) {
      state = state.copyWith(
        requestSchema: const [],
        isSchemaLoading: false,
        schemaError: e.toString(),
      );
    }
  }

  Future<void> disconnect(GrpcRequestModel model) async {
    await _service.disconnectEndpoint(model.host, model.port, model.useTls);
    state = state.copyWith(
      connectionState: GrpcConnectionState.disconnected,
      discoveryStatus: GrpcDiscoveryStatus.idle,
      discoveredServices: const [],
      methodsByService: const {},
      requestSchema: const [],
      isSchemaLoading: false,
      schemaError: null,
      discoveryMessage: 'Disconnected',
    );
  }

  void reset() => state = const GrpcSessionState();

  @override
  void dispose() {
    _service.shutdown();
    super.dispose();
  }
}

final grpcNotifierProvider =
    StateNotifierProvider.autoDispose<GrpcNotifier, GrpcSessionState>(
  (ref) => GrpcNotifier(),
);
