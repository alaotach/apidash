import 'dart:io';

import 'package:apidash/generated/google/protobuf/descriptor.pb.dart' as $descriptor;
import 'package:apidash/services/grpc_service.dart';
import 'package:better_networking/better_networking.dart';
import 'package:grpc/grpc.dart' as $grpc;

class EchoService extends $grpc.Service {
  @override
  String get $name => 'apidash.test.EchoService';

  EchoService() {
    $addMethod(
      $grpc.ServiceMethod<$descriptor.FileDescriptorSet, $descriptor.FileDescriptorSet>(
        'Echo',
        echo,
        false,
        false,
        (List<int> value) => $descriptor.FileDescriptorSet.fromBuffer(value),
        ($descriptor.FileDescriptorSet value) => value.writeToBuffer(),
      ),
    );
  }

  Future<$descriptor.FileDescriptorSet> echo(
    $grpc.ServiceCall call,
    Future<$descriptor.FileDescriptorSet> request,
  ) async {
    final incoming = await request;
    return incoming;
  }
}

Future<void> main() async {
  final server = $grpc.Server.create(services: [EchoService()]);
  await server.serve(address: '127.0.0.1', port: 50071);

  final service = GrpcService();
  final protoA = File('tool/grpc_fallback_e2e/protos/services/echo_service.proto').absolute.path;
  final protoB = File('tool/grpc_fallback_e2e/protos/common/nested/imports.proto').absolute.path;

  final baseModel = GrpcRequestModel(
    host: '127.0.0.1',
    port: 50071,
    useTls: false,
    serviceName: 'apidash.test.EchoService',
    methodName: 'Echo',
    requestJson: '{"file":[{"name":"nested.proto"}]}',
    protoFiles: [protoA, protoB],
  );

  try {
    final discovered = await service.discoverFromProtoFiles(baseModel);
    if (discovered.statusCode != 'OK' || discovered.availableServices.isEmpty) {
      stderr.writeln('DISCOVERY_FAILED: ${discovered.statusMessage} :: ${discovered.errorMessage}');
      exitCode = 1;
      return;
    }

    final result = await service.callUnary(discovered);
    if (result.errorMessage != null) {
      stderr.writeln('CALL_FAILED: ${result.errorMessage}');
      exitCode = 1;
      return;
    }

    stdout.writeln('DISCOVERY_SOURCE=${discovered.descriptorSource.name}');
    stdout.writeln('DISCOVERED_SERVICES=${discovered.availableServices.join(',')}');
    stdout.writeln('RESPONSE_JSON=${result.responseJson}');
    stdout.writeln('TIMELINE_KEYS=${result.timeline.keys.toList()..sort()}');
  } finally {
    await service.shutdown();
    await server.shutdown();
  }
}
