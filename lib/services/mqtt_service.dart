import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart' as mqtt3 hide MqttMessage;
import 'package:mqtt_client/mqtt_server_client.dart' as mqtt3_server;
import 'package:mqtt5_client/mqtt5_client.dart' as mqtt5 hide MqttMessage;
import 'package:mqtt5_client/mqtt5_server_client.dart' as mqtt5_server;
import 'package:better_networking/better_networking.dart';

/// Manages an MQTT broker connection, pub/sub, and message logging.
class MqttService {
  mqtt3_server.MqttServerClient? _clientV3;
  mqtt5_server.MqttServerClient? _clientV5;
  final _messageController = StreamController<MqttMessage>.broadcast();
  StreamSubscription? _updatesSub;

  bool get isConnected =>
      _clientV5?.connectionStatus?.state == mqtt5.MqttConnectionState.connected ||
      _clientV3?.connectionStatus?.state == mqtt3.MqttConnectionState.connected;

  Stream<MqttMessage> get messageStream => _messageController.stream;

  /// Connects to the broker described by [model].
  ///
  /// Throws a [StateError] with a human-readable message on CONNACK failures.
  Future<void> connect(MqttRequestModel model) async {
    await disconnect();
    switch (model.protocolVersion) {
      case MqttProtocolVersion.v31:
      case MqttProtocolVersion.v311:
        await _connectV3(model);
      case MqttProtocolVersion.v5:
        await _connectV5(model);
    }
  }

  Future<void> _connectV3(MqttRequestModel model) async {
    final client = mqtt3_server.MqttServerClient.withPort(
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

    switch (model.protocolVersion) {
      case MqttProtocolVersion.v31:
        client.setProtocolV31();
      case MqttProtocolVersion.v311:
      case MqttProtocolVersion.v5:
        client.setProtocolV311();
    }

    final connMsg = mqtt3.MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .startClean()
        .withWillQos(mqtt3.MqttQos.atMostOnce);

    if (model.username != null && model.username!.isNotEmpty) {
      connMsg.authenticateAs(model.username!, model.password ?? '');
    }

    client.connectionMessage = connMsg;

    final status = await client.connect();
    if (status?.state != mqtt3.MqttConnectionState.connected) {
      throw StateError(_connackErrorV3(status?.returnCode));
    }

    _clientV3 = client;
    _updatesSub = client.updates?.listen((messages) {
      for (final msg in messages) {
        final r = msg.payload as mqtt3.MqttPublishMessage;
        final payload = mqtt3.MqttPublishPayload.bytesToStringAsString(
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

  Future<void> _connectV5(MqttRequestModel model) async {
    final client = mqtt5_server.MqttServerClient.withPort(
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

    final connMsg = mqtt5.MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .startClean()
        .withWillQos(mqtt5.MqttQos.atMostOnce);

    if (model.username != null && model.username!.isNotEmpty) {
      connMsg.authenticateAs(model.username!, model.password ?? '');
    }

    client.connectionMessage = connMsg;

    final status = await client.connect();
    if (status?.state != mqtt5.MqttConnectionState.connected) {
      throw StateError(_connackErrorV5(status));
    }

    _clientV5 = client;
    _updatesSub = client.updates.listen((messages) {
      for (final msg in messages) {
        final r = msg.payload as mqtt5.MqttPublishMessage;
        final payloadBytes = r.payload.message;
        final payload = payloadBytes == null
            ? ''
            : mqtt5.MqttPublishPayload.bytesToStringAsString(payloadBytes);
        _messageController.add(MqttMessage(
          topic: msg.topic ?? '',
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
    final boundedQos = qos.clamp(0, 2);
    if (_clientV5 != null) {
      _clientV5!.subscribe(topic, mqtt5.MqttQos.values[boundedQos]);
      return;
    }
    _clientV3?.subscribe(topic, mqtt3.MqttQos.values[boundedQos]);
  }

  /// Unsubscribes from [topic].
  void unsubscribe(String topic) {
    _clientV5?.unsubscribeStringTopic(topic);
    _clientV3?.unsubscribe(topic);
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
    if (!isConnected) {
      throw StateError('Not connected to broker');
    }
    final boundedQos = qos.clamp(0, 2);
    if (_clientV5 != null) {
      final builder = mqtt5.MqttPayloadBuilder()..addString(payload);
      _clientV5!.publishMessage(
        topic,
        mqtt5.MqttQos.values[boundedQos],
        builder.payload!,
        retain: retain,
      );
    } else {
      final builder = mqtt3.MqttClientPayloadBuilder()..addString(payload);
      _clientV3!.publishMessage(
        topic,
        mqtt3.MqttQos.values[boundedQos],
        builder.payload!,
        retain: retain,
      );
    }
    return MqttMessage(
      topic: topic,
      payload: payload,
      qos: boundedQos,
      timestamp: DateTime.now(),
      retain: retain,
      isSent: true,
    );
  }

  /// Disconnects from the broker and disposes resources.
  Future<void> disconnect() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
    _clientV5?.disconnect();
    _clientV3?.disconnect();
    _clientV5 = null;
    _clientV3 = null;
  }

  void _onDisconnected() {
    _updatesSub?.cancel();
    _updatesSub = null;
    _clientV5 = null;
    _clientV3 = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }

  static String _connackErrorV3(mqtt3.MqttConnectReturnCode? code) {
    return switch (code) {
      mqtt3.MqttConnectReturnCode.unacceptedProtocolVersion =>
        'CONNACK error: Unaccepted protocol version',
      mqtt3.MqttConnectReturnCode.identifierRejected =>
        'CONNACK error: Client identifier rejected',
      mqtt3.MqttConnectReturnCode.brokerUnavailable =>
        'CONNACK error: Broker unavailable',
      mqtt3.MqttConnectReturnCode.badUsernameOrPassword =>
        'CONNACK error: Bad username or password (code 4)',
      mqtt3.MqttConnectReturnCode.notAuthorized =>
        'CONNACK error: Not authorized (code 5)',
      _ => 'CONNACK error: Connection refused (code ${code?.index})',
    };
  }

  static String _connackErrorV5(mqtt5.MqttConnectionStatus? status) {
    final reason = mqtt5.MqttConnectReasonCodeSupport
        .mqttConnectReasonCode
        .asString(status?.reasonCode);
    final reasonString = status?.reasonString;
    if (reasonString == null || reasonString.isEmpty) {
      return 'CONNACK error: $reason';
    }
    return 'CONNACK error: $reason ($reasonString)';
  }
}
