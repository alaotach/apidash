/// A single message in an MQTT session (published or received).
class MqttMessage {
  const MqttMessage({
    required this.topic,
    required this.payload,
    required this.qos,
    required this.timestamp,
    this.retain = false,
    this.isSent = false,
  });

  final String topic;
  final String payload;

  /// Quality of Service level: 0, 1, or 2.
  final int qos;

  final DateTime timestamp;

  /// Whether the RETAIN flag was set.
  final bool retain;

  /// `true` = ↑ PUB (published), `false` = ↓ SUB (received).
  final bool isSent;

  int get sizeBytes => payload.length;

  MqttMessage copyWith({
    String? topic,
    String? payload,
    int? qos,
    DateTime? timestamp,
    bool? retain,
    bool? isSent,
  }) {
    return MqttMessage(
      topic: topic ?? this.topic,
      payload: payload ?? this.payload,
      qos: qos ?? this.qos,
      timestamp: timestamp ?? this.timestamp,
      retain: retain ?? this.retain,
      isSent: isSent ?? this.isSent,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MqttMessage &&
          other.topic == topic &&
          other.payload == payload &&
          other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(topic, payload, timestamp);
}

enum MqttProtocolVersion {
  v31,
  v311,
  v5,
}

/// Model representing the configuration and session log for an MQTT request.
class MqttRequestModel {
  const MqttRequestModel({
    this.brokerHost = '',
    this.port = 1883,
    this.clientId = '',
    this.username,
    this.password,
    this.cleanSession = true,
    this.protocolVersion = MqttProtocolVersion.v311,
    this.keepAliveSeconds = 60,
    this.useTls = false,
    this.subscribedTopics = const [],
    this.publishTopic = '',
    this.publishPayload = '',
    this.publishQos = 0,
    this.publishRetain = false,
    this.messageLog = const [],
  });

  final String brokerHost;
  final int port;
  final String clientId;
  final String? username;
  final String? password;
  final bool cleanSession;
  final MqttProtocolVersion protocolVersion;
  final int keepAliveSeconds;
  final bool useTls;

  /// Currently active subscriptions.
  final List<String> subscribedTopics;

  // Publish form fields
  final String publishTopic;
  final String publishPayload;
  final int publishQos;
  final bool publishRetain;

  /// Chronological log of all published/received messages.
  final List<MqttMessage> messageLog;

  MqttRequestModel copyWith({
    String? brokerHost,
    int? port,
    String? clientId,
    String? username,
    String? password,
    bool? cleanSession,
    MqttProtocolVersion? protocolVersion,
    int? keepAliveSeconds,
    bool? useTls,
    List<String>? subscribedTopics,
    String? publishTopic,
    String? publishPayload,
    int? publishQos,
    bool? publishRetain,
    List<MqttMessage>? messageLog,
  }) {
    return MqttRequestModel(
      brokerHost: brokerHost ?? this.brokerHost,
      port: port ?? this.port,
      clientId: clientId ?? this.clientId,
      username: username ?? this.username,
      password: password ?? this.password,
      cleanSession: cleanSession ?? this.cleanSession,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      keepAliveSeconds: keepAliveSeconds ?? this.keepAliveSeconds,
      useTls: useTls ?? this.useTls,
      subscribedTopics: subscribedTopics ?? this.subscribedTopics,
      publishTopic: publishTopic ?? this.publishTopic,
      publishPayload: publishPayload ?? this.publishPayload,
      publishQos: publishQos ?? this.publishQos,
      publishRetain: publishRetain ?? this.publishRetain,
      messageLog: messageLog ?? this.messageLog,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MqttRequestModel &&
          other.brokerHost == brokerHost &&
          other.port == port &&
          other.clientId == clientId;

  @override
  int get hashCode => Object.hash(brokerHost, port, clientId);
}
