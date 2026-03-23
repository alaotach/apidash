import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:better_networking/better_networking.dart';
import '../services/mqtt_service.dart';

enum MqttClientConnectionState { disconnected, connecting, connected }

class MqttSessionState {
  const MqttSessionState({
    this.connectionState = MqttClientConnectionState.disconnected,
    this.subscribedTopics = const [],
    this.messageLog = const [],
    this.error,
  });

  final MqttClientConnectionState connectionState;
  final List<String> subscribedTopics;
  final List<MqttMessage> messageLog;
  final String? error;

  bool get isConnected =>
      connectionState == MqttClientConnectionState.connected;

  MqttSessionState copyWith({
    MqttClientConnectionState? connectionState,
    List<String>? subscribedTopics,
    List<MqttMessage>? messageLog,
    String? error,
  }) {
    return MqttSessionState(
      connectionState: connectionState ?? this.connectionState,
      subscribedTopics: subscribedTopics ?? this.subscribedTopics,
      messageLog: messageLog ?? this.messageLog,
      error: error,
    );
  }
}

class MqttNotifier extends StateNotifier<MqttSessionState> {
  MqttNotifier() : super(const MqttSessionState());

  final _service = MqttService();
  StreamSubscription<MqttMessage>? _sub;

  Future<void> connect(MqttRequestModel model) async {
    state = state.copyWith(
      connectionState: MqttClientConnectionState.connecting,
      messageLog: [],
      error: null,
    );
    try {
      await _service.connect(model);
      state = state.copyWith(
        connectionState: MqttClientConnectionState.connected,
      );

      _sub = _service.messageStream.listen(
        (msg) {
          state = state.copyWith(
            messageLog: [...state.messageLog, msg],
          );
        },
        onDone: () {
          state = state.copyWith(
            connectionState: MqttClientConnectionState.disconnected,
          );
        },
        onError: (e) {
          state = MqttSessionState(
            connectionState: MqttClientConnectionState.disconnected,
            messageLog: state.messageLog,
            error: e.toString(),
          );
        },
      );
    } catch (e) {
      state = MqttSessionState(
        connectionState: MqttClientConnectionState.disconnected,
        error: e.toString(),
      );
    }
  }

  void subscribe(String topic, {int qos = 0}) {
    if (!state.isConnected) return;
    _service.subscribe(topic, qos: qos);
    if (!state.subscribedTopics.contains(topic)) {
      state = state.copyWith(
        subscribedTopics: [...state.subscribedTopics, topic],
      );
    }
  }

  void unsubscribe(String topic) {
    _service.unsubscribe(topic);
    state = state.copyWith(
      subscribedTopics:
          state.subscribedTopics.where((t) => t != topic).toList(),
    );
  }

  void publish(String topic, String payload, {int qos = 0, bool retain = false}) {
    if (!state.isConnected) return;
    try {
      final msg = _service.publish(topic, payload, qos: qos, retain: retain);
      state = state.copyWith(messageLog: [...state.messageLog, msg]);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _service.disconnect();
    state = state.copyWith(
      connectionState: MqttClientConnectionState.disconnected,
      subscribedTopics: [],
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _service.dispose();
    super.dispose();
  }
}

final mqttNotifierProvider =
    StateNotifierProvider.autoDispose<MqttNotifier, MqttSessionState>(
  (ref) => MqttNotifier(),
);
