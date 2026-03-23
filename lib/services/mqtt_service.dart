import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart' hide MqttMessage;
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:better_networking/better_networking.dart';

/// Manages an MQTT broker connection, pub/sub, and message logging.
class MqttService {
  MqttServerClient? _client;
  final _messageController = StreamController<MqttMessage>.broadcast();
  StreamSubscription? _updatesSub;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  Stream<MqttMessage> get messageStream => _messageController.stream;

  /// Connects to the broker described by [model].
  ///
  /// Throws a [StateError] with a human-readable message on CONNACK failures.
  Future<void> connect(MqttRequestModel model) async {
    final client = MqttServerClient.withPort(
      model.brokerHost,
      model.clientId.isEmpty
          ? 'apidash_${DateTime.now().millisecondsSinceEpoch}'
          : model.clientId,
      model.port,
    );

    client.keepAlivePeriod = model.keepAliveSeconds;
    client.logging(on: false);
    client.secure = model.useTls;
    client.onDisconnected = _onDisconnected;

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);

    if (model.username != null && model.username!.isNotEmpty) {
      connMsg.authenticateAs(model.username!, model.password ?? '');
    }

    client.connectionMessage = connMsg;

    try {
      final status = await client.connect();
      if (status?.state != MqttConnectionState.connected) {
        final code = status?.returnCode;
        throw StateError(_connackError(code));
      }
    } catch (e) {
      rethrow;
    }

    _client = client;

    // Forward incoming messages to stream
    _updatesSub = client.updates?.listen((messages) {
      for (final msg in messages) {
        final r = msg.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
          r.payload.message,
        );
        _messageController.add(MqttMessage(
          topic: msg.topic,
          payload: payload,
          qos: r.header?.qos?.index ?? 0,
          timestamp: DateTime.now(),
          retain: r.header?.retain ?? false,
          isSent: false,
        ));
      }
    });
  }

  /// Subscribes to [topic] at the given [qos] level.
  void subscribe(String topic, {int qos = 0}) {
    _client?.subscribe(topic, MqttQos.values[qos.clamp(0, 2)]);
  }

  /// Unsubscribes from [topic].
  void unsubscribe(String topic) {
    _client?.unsubscribe(topic);
  }

  /// Publishes [payload] to [topic] with the given [qos] and [retain].
  ///
  /// Returns the published [MqttMessage] so callers can append it to the log.
  MqttMessage publish(
    String topic,
    String payload, {
    int qos = 0,
    bool retain = false,
  }) {
    if (_client == null || !isConnected) {
      throw StateError('Not connected to broker');
    }
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(
      topic,
      MqttQos.values[qos.clamp(0, 2)],
      builder.payload!,
      retain: retain,
    );
    return MqttMessage(
      topic: topic,
      payload: payload,
      qos: qos,
      timestamp: DateTime.now(),
      retain: retain,
      isSent: true,
    );
  }

  /// Disconnects from the broker and disposes resources.
  Future<void> disconnect() async {
    await _updatesSub?.cancel();
    _client?.disconnect();
    _client = null;
  }

  void _onDisconnected() {
    _updatesSub?.cancel();
    _client = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }

  static String _connackError(MqttConnectReturnCode? code) {
    return switch (code) {
      MqttConnectReturnCode.unacceptedProtocolVersion =>
        'CONNACK error: Unaccepted protocol version',
      MqttConnectReturnCode.identifierRejected =>
        'CONNACK error: Client identifier rejected',
      MqttConnectReturnCode.brokerUnavailable =>
        'CONNACK error: Broker unavailable',
      MqttConnectReturnCode.badUsernameOrPassword =>
        'CONNACK error: Bad username or password (code 4)',
      MqttConnectReturnCode.notAuthorized =>
        'CONNACK error: Not authorized (code 5)',
      _ => 'CONNACK error: Connection refused (code ${code?.index})',
    };
  }
}
