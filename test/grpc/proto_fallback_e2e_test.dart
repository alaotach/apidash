import 'dart:io';

import 'package:apidash/generated/google/protobuf/descriptor.pb.dart' as $descriptor;
import 'package:apidash/services/grpc_service.dart';
import 'package:better_networking/better_networking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' as $grpc;

class _EchoService extends $grpc.Service {
  @override
  String get $name => 'apidash.test.EchoService';

  _EchoService() {
    $addMethod(
      $grpc.ServiceMethod<$descriptor.FileDescriptorSet, $descriptor.FileDescriptorSet>(
        'Echo',
        _echo,
        false,
        false,
        (List<int> value) => $descriptor.FileDescriptorSet.fromBuffer(value),
        ($descriptor.FileDescriptorSet value) => value.writeToBuffer(),
      ),
    );
  }

  Future<$descriptor.FileDescriptorSet> _echo(
    $grpc.ServiceCall call,
    Future<$descriptor.FileDescriptorSet> request,
  ) async {
    return request;
  }
}

void main() {
  test('proto fallback works with nested imported protos against reflection-disabled server', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final server = $grpc.Server.create(services: [_EchoService()]);
    await server.serve(address: '127.0.0.1', port: port);

    final grpc = GrpcService();
    final protoA = File('test/grpc/fixtures/protos/services/echo_service.proto').absolute.path;
    final protoB = File('test/grpc/fixtures/protos/common/nested/imports.proto').absolute.path;

    final baseModel = GrpcRequestModel(
      host: '127.0.0.1',
      port: port,
      useTls: false,
      serviceName: 'apidash.test.EchoService',
      methodName: 'Echo',
      requestJson: '{}',
      protoFiles: [protoA, protoB],
    );

    try {
      final discovered = await grpc.discoverFromProtoFiles(baseModel);
      expect(discovered.statusCode, 'OK');
      expect(discovered.availableServices, contains('apidash.test.EchoService'));

      final result = await grpc.callUnary(discovered);
      expect(result.errorMessage, isNull);
      expect(result.statusCode, 'OK');
      expect(result.responseJson, isNotNull);
      expect(result.timeline.containsKey('invoke'), isTrue);
    } finally {
      await grpc.shutdown();
      await server.shutdown();
    }
  });
}
