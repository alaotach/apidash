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
    this.connectAttempts = 0,
    this.connectedAt,
    this.connectLatencyMs,
  });

  final MqttClientConnectionState connectionState;
  final List<String> subscribedTopics;
  final List<MqttMessage> messageLog;
  final String? error;
  final int connectAttempts;
  final DateTime? connectedAt;
  final int? connectLatencyMs;

  bool get isConnected =>
      connectionState == MqttClientConnectionState.connected;

  MqttSessionState copyWith({
    MqttClientConnectionState? connectionState,
    List<String>? subscribedTopics,
    List<MqttMessage>? messageLog,
    String? error,
    int? connectAttempts,
    DateTime? connectedAt,
    int? connectLatencyMs,
  }) {
    return MqttSessionState(
      connectionState: connectionState ?? this.connectionState,
      subscribedTopics: subscribedTopics ?? this.subscribedTopics,
      messageLog: messageLog ?? this.messageLog,
      error: error,
      connectAttempts: connectAttempts ?? this.connectAttempts,
      connectedAt: connectedAt ?? this.connectedAt,
      connectLatencyMs: connectLatencyMs ?? this.connectLatencyMs,
    );
  }
}

class MqttNotifier extends StateNotifier<MqttSessionState> {
  MqttNotifier() : super(const MqttSessionState());

  final _service = MqttService();
  StreamSubscription<MqttMessage>? _sub;

  Future<void> connect(MqttRequestModel model) async {
    final stopwatch = Stopwatch()..start();
    state = state.copyWith(
      connectionState: MqttClientConnectionState.connecting,
      messageLog: [],
      error: null,
      connectAttempts: state.connectAttempts + 1,
      connectedAt: null,
      connectLatencyMs: null,
    );
    try {
      await _service.connect(model);
      stopwatch.stop();
      state = state.copyWith(
        connectionState: MqttClientConnectionState.connected,
        connectedAt: DateTime.now(),
        connectLatencyMs: stopwatch.elapsedMilliseconds,
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
            connectedAt: null,
          );
        },
        onError: (e) {
          state = MqttSessionState(
            connectionState: MqttClientConnectionState.disconnected,
            messageLog: state.messageLog,
            error: e.toString(),
            connectAttempts: state.connectAttempts,
            connectedAt: null,
            connectLatencyMs: state.connectLatencyMs,
          );
        },
      );
    } catch (e) {
      stopwatch.stop();
      state = MqttSessionState(
        connectionState: MqttClientConnectionState.disconnected,
        error: e.toString(),
        connectAttempts: state.connectAttempts,
        connectedAt: null,
        connectLatencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  void subscribe(String topic, {int qos = 0}) {
    if (!state.isConnected || !_service.isConnected) {
      state = state.copyWith(
        connectionState: MqttClientConnectionState.disconnected,
        error: 'Not connected to broker. Reconnect and try again.',
        connectedAt: null,
      );
      return;
    }
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
    if (!state.isConnected || !_service.isConnected) {
      state = state.copyWith(
        connectionState: MqttClientConnectionState.disconnected,
        error: 'Not connected to broker. Reconnect and try again.',
        connectedAt: null,
      );
      return;
    }
    try {
      final msg = _service.publish(topic, payload, qos: qos, retain: retain);
      state = state.copyWith(messageLog: [...state.messageLog, msg]);
    } catch (e) {
      final errorText = e.toString();
      final disconnected = errorText.contains('Not connected to broker');
      state = state.copyWith(
        error: disconnected
            ? 'Not connected to broker. Reconnect and try again.'
            : errorText,
        connectionState: disconnected
            ? MqttClientConnectionState.disconnected
            : state.connectionState,
        connectedAt: disconnected ? null : state.connectedAt,
      );
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _service.disconnect();
    state = state.copyWith(
      connectionState: MqttClientConnectionState.disconnected,
      subscribedTopics: [],
      connectedAt: null,
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
