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
    this.publishedCount = 0,
    this.receivedCount = 0,
    this.totalBytes = 0,
    this.rollingMessagesPerSec,
    this.rollingBytesPerSec,
    this.lastMessageAt,
  });

  final MqttClientConnectionState connectionState;
  final List<String> subscribedTopics;
  final List<MqttMessage> messageLog;
  final String? error;
  final int connectAttempts;
  final DateTime? connectedAt;
  final int? connectLatencyMs;
  final int? publishedCount;
  final int? receivedCount;
  final int? totalBytes;
  final double? rollingMessagesPerSec;
  final double? rollingBytesPerSec;
  final DateTime? lastMessageAt;

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
    int? publishedCount,
    int? receivedCount,
    int? totalBytes,
    double? rollingMessagesPerSec,
    double? rollingBytesPerSec,
    DateTime? lastMessageAt,
  }) {
    return MqttSessionState(
      connectionState: connectionState ?? this.connectionState,
      subscribedTopics: subscribedTopics ?? this.subscribedTopics,
      messageLog: messageLog ?? this.messageLog,
      error: error,
      connectAttempts: connectAttempts ?? this.connectAttempts,
      connectedAt: connectedAt ?? this.connectedAt,
      connectLatencyMs: connectLatencyMs ?? this.connectLatencyMs,
        publishedCount: publishedCount ?? this.publishedCount ?? 0,
        receivedCount: receivedCount ?? this.receivedCount ?? 0,
        totalBytes: totalBytes ?? this.totalBytes ?? 0,
      rollingMessagesPerSec:
          rollingMessagesPerSec ?? this.rollingMessagesPerSec,
      rollingBytesPerSec: rollingBytesPerSec ?? this.rollingBytesPerSec,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
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
      publishedCount: 0,
      receivedCount: 0,
      totalBytes: 0,
      rollingMessagesPerSec: null,
      rollingBytesPerSec: null,
      lastMessageAt: null,
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
          final nextLog = [...state.messageLog, msg];
          final rolling = _rollingRates(nextLog);
          state = state.copyWith(
            messageLog: nextLog,
            receivedCount: (state.receivedCount ?? 0) + 1,
            totalBytes: (state.totalBytes ?? 0) + msg.sizeBytes,
            rollingMessagesPerSec: rolling.$1,
            rollingBytesPerSec: rolling.$2,
            lastMessageAt: msg.timestamp,
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
      final nextLog = [...state.messageLog, msg];
      final rolling = _rollingRates(nextLog);
      state = state.copyWith(
        messageLog: nextLog,
        publishedCount: (state.publishedCount ?? 0) + 1,
        totalBytes: (state.totalBytes ?? 0) + msg.sizeBytes,
        rollingMessagesPerSec: rolling.$1,
        rollingBytesPerSec: rolling.$2,
        lastMessageAt: msg.timestamp,
      );
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

  (double, double) _rollingRates(List<MqttMessage> log) {
    final now = DateTime.now();
    const window = Duration(seconds: 10);
    final recent = log.where((m) => now.difference(m.timestamp) <= window);
    final count = recent.length;
    if (count == 0) {
      return (0, 0);
    }
    final bytes = recent.fold<int>(0, (sum, m) => sum + m.sizeBytes);
    return (count / window.inSeconds, bytes / window.inSeconds);
  }
}

final mqttNotifierProvider =
    StateNotifierProvider.autoDispose<MqttNotifier, MqttSessionState>(
  (ref) => MqttNotifier(),
);
