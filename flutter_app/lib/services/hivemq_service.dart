import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class HiveMQService {
  // ===== HIVEMQ CLOUD CONFIGURATION =====
  static const String broker =
      '9ab7d2b2fca840559bb01e402f89a1ad.s1.eu.hivemq.cloud';
  static const int port = 8883;
  static const String username = 'farm_CLI';
  static const String password = 'Farm@1234';

  late MqttServerClient client;

  // Stream controllers
  final StreamController<DoorStatus> _doorStatusController =
      StreamController<DoorStatus>.broadcast();
  final StreamController<ScraperStatus> _scraperStatusController =
      StreamController<ScraperStatus>.broadcast();
  final StreamController<FeederStatus> _feederStatusController =
      StreamController<FeederStatus>.broadcast();
  final StreamController<bool> _lightStatusController =
      StreamController<bool>.broadcast();
  final StreamController<int> _inCountController =
      StreamController<int>.broadcast();
  final StreamController<int> _outCountController =
      StreamController<int>.broadcast();
  final StreamController<String> _connectionStatusController =
      StreamController<String>.broadcast();
  final StreamController<String> _commandResponseController =
      StreamController<String>.broadcast();
  final StreamController<Motor3Status> _motor3StatusController =
      StreamController<Motor3Status>.broadcast();
  final StreamController<Motor4Status> _motor4StatusController =
      StreamController<Motor4Status>.broadcast();
  final StreamController<bool> _estopController =
      StreamController<bool>.broadcast();
  final StreamController<String> _lockoutController =
      StreamController<String>.broadcast();
  final StreamController<String> _scheduleLogController =
      StreamController<String>.broadcast();

  // Public streams
  Stream<DoorStatus> get doorStatusStream => _doorStatusController.stream;
  Stream<ScraperStatus> get scraperStatusStream =>
      _scraperStatusController.stream;
  Stream<FeederStatus> get feederStatusStream => _feederStatusController.stream;
  Stream<bool> get lightStatusStream => _lightStatusController.stream;
  Stream<int> get inCountStream => _inCountController.stream;
  Stream<int> get outCountStream => _outCountController.stream;
  Stream<String> get connectionStatusStream =>
      _connectionStatusController.stream;
  Stream<String> get commandResponseStream => _commandResponseController.stream;
  Stream<Motor3Status> get motor3StatusStream => _motor3StatusController.stream;
  Stream<Motor4Status> get motor4StatusStream => _motor4StatusController.stream;
  Stream<bool> get estopStream => _estopController.stream;
  Stream<String> get lockoutStream => _lockoutController.stream;
  Stream<String> get scheduleLogStream => _scheduleLogController.stream;

  bool isConnected = false;

  // Topics
  static const String topicSystemStatus = 'farm/system/status';
  static const String topicDoorCmd = 'farm/door/cmd';
  static const String topicScraperCmd = 'farm/scraper/cmd';
  static const String topicFeederCmd = 'farm/feeder/cmd';
  static const String topicFeederStatus = 'farm/feeder/status';
  static const String topicLightCmd = 'farm/light/cmd';
  static const String topicLightStatus = 'farm/light/status';
  static const String topicEStop = 'farm/estop';
  static const String topicLockout = 'farm/lockout';
  static const String topicInCount = 'farm/chickens/in';
  static const String topicOutCount = 'farm/chickens/out';
  static const String topicMotor3Cmd = 'farm/motor3/cmd';
  static const String topicMotor4Cmd = 'farm/motor4/cmd';
  static const String topicMotor3Status = 'farm/motor3/status';
  static const String topicMotor4Status = 'farm/motor4/status';
  static const String topicScheduleLog = 'farm/schedule/log';
  static const String topicScheduleSet = 'farm/schedule/set';

  Future<void> connect() async {
    String clientIdentifier =
        'Farm_App_${DateTime.now().millisecondsSinceEpoch}';
    client = MqttServerClient(broker, clientIdentifier);
    client.port = port;
    client.useWebSocket = false;
    client.keepAlivePeriod = 240;
    client.autoReconnect = true;
    client.logging(on: false);

    client.secure = true;
    client.onBadCertificate = (dynamic cert) => true;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .authenticateAs(username, password)
        .withWillTopic(topicSystemStatus)
        .withWillMessage('ESP_OFFLINE')
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();

    client.connectionMessage = connMessage;

    client.onConnected = () {
      isConnected = true;
      print('✅ Connected to HiveMQ Cloud');
      _connectionStatusController.add('connected');
      _subscribeToTopics();
    };

    client.onDisconnected = () {
      isConnected = false;
      print('❌ Disconnected from HiveMQ');
      _connectionStatusController.add('disconnected');
    };

    client.onAutoReconnected = () {
      isConnected = true;
      print('🔄 Auto-reconnected to HiveMQ');
      _connectionStatusController.add('reconnected');
      _subscribeToTopics();
    };

    client.onAutoReconnect = () {
      print('🔄 Attempting auto-reconnect...');
      _connectionStatusController.add('reconnecting');
    };

    try {
      await client.connect();
    } catch (e) {
      print('❌ Connection failed: $e');
      isConnected = false;
      _connectionStatusController.add('error: $e');
      rethrow;
    }

    client.updates?.listen(_handleIncomingMessage);
  }

  void _subscribeToTopics() {
    const topics = [
      topicSystemStatus,
      topicFeederStatus,
      topicLightStatus,
      topicEStop,
      topicLockout,
      topicInCount,
      topicOutCount,
      topicMotor3Status,
      topicMotor4Status,
      topicScheduleLog,
    ];
    for (final topic in topics) {
      client.subscribe(topic, MqttQos.atLeastOnce);
    }
  }

  void _handleIncomingMessage(List<MqttReceivedMessage<MqttMessage?>>? events) {
    if (events == null) return;

    for (final event in events) {
      final topic = event.topic;
      final payload = event.payload as MqttPublishMessage;
      final message = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );

      print('📩 Received on $topic: $message');

      if (topic == topicSystemStatus) {
        _parseSystemStatus(message);
      } else if (topic == topicFeederStatus) {
        _parseFeederStatus(message);
      } else if (topic == topicLightStatus) {
        _lightStatusController.add(message == 'ON');
      } else if (topic == topicEStop) {
        _estopController.add(message == 'ACTIVE');
      } else if (topic == topicLockout) {
        _lockoutController.add(message);
      } else if (topic == topicInCount) {
        try {
          _inCountController.add(int.parse(message));
        } catch (e) {
          print('Error parsing in count: $e');
        }
      } else if (topic == topicOutCount) {
        try {
          _outCountController.add(int.parse(message));
        } catch (e) {
          print('Error parsing out count: $e');
        }
      } else if (topic == topicMotor3Status) {
        _parseMotor3Status(message);
      } else if (topic == topicMotor4Status) {
        _parseMotor4Status(message);
      } else if (topic == topicScheduleLog) {
        _scheduleLogController.add(message);
      }
    }
  }

  // Parse status format: "DOOR_LIMIT HIT|UP LIMIT|SCRAPER_READY|NONE"
  void _parseSystemStatus(String message) {
    try {
      final parts = message.split('|');

      DoorStatus doorStatus = DoorStatus();
      ScraperStatus scraperStatus = ScraperStatus();

      if (parts.length >= 2) {
        final doorPart = parts[0];
        if (doorPart.startsWith('DOOR_')) {
          doorStatus.status = doorPart.substring(5);
        }
        doorStatus.limitHit = parts[1];
      }

      if (parts.length >= 4) {
        final scraperPart = parts[2];
        if (scraperPart.startsWith('SCRAPER_')) {
          scraperStatus.status = scraperPart.substring(8);
        }
        scraperStatus.limitHit = parts[3];
      }

      _doorStatusController.add(doorStatus);
      _scraperStatusController.add(scraperStatus);
    } catch (e) {
      print('Error parsing system status: $e');
      _doorStatusController.add(DoorStatus());
      _scraperStatusController.add(ScraperStatus());
    }
  }

  void _parseFeederStatus(String message) {
    try {
      final parts = message.split('|');
      FeederStatus status = FeederStatus();

      if (parts.length >= 2) {
        status.status = parts[0];
        status.limitHit = parts[1];
      } else {
        status.status = message;
      }
      _feederStatusController.add(status);
    } catch (e) {
      print('Error parsing feeder status: $e');
      _feederStatusController.add(FeederStatus());
    }
  }

  void _parseMotor3Status(String message) {
    try {
      final parts = message.split('|');
      Motor3Status motor3Status = Motor3Status();
      if (parts.length >= 2) {
        final motorPart = parts[0];
        if (motorPart.startsWith('MOTOR3_')) {
          motor3Status.status = motorPart.substring(7);
        }
        motor3Status.limitHit = parts[1];
      }
      _motor3StatusController.add(motor3Status);
    } catch (e) {
      print('Error parsing motor3 status: $e');
      _motor3StatusController.add(Motor3Status());
    }
  }

  void _parseMotor4Status(String message) {
    try {
      final parts = message.split('|');
      Motor4Status motor4Status = Motor4Status();
      if (parts.length >= 2) {
        final motorPart = parts[0];
        if (motorPart.startsWith('MOTOR4_')) {
          motor4Status.status = motorPart.substring(7);
        }
        motor4Status.limitHit = parts[1];
      }
      _motor4StatusController.add(motor4Status);
    } catch (e) {
      print('Error parsing motor4 status: $e');
      _motor4StatusController.add(Motor4Status());
    }
  }

  // Command sending methods
  Future<void> sendCommand(String topic, String command) async {
    if (!isConnected) {
      print('⚠️ Not connected to MQTT broker');
      _commandResponseController.add('ERROR: Not connected');
      return;
    }

    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    print('📤 Command sent to $topic: $command');
    _commandResponseController.add('SENT: $command to $topic');
  }

  Future<void> sendDoorCommand(String command) async {
    await sendCommand(topicDoorCmd, command);
  }

  Future<void> sendScraperCommand(String command) async {
    await sendCommand(topicScraperCmd, command);
  }

  Future<void> sendFeederCommand(String command) async {
    await sendCommand(topicFeederCmd, command);
  }

  Future<void> sendLightCommand(String command) async {
    await sendCommand(topicLightCmd, command);
  }

  Future<void> triggerEStop() async {
    await sendCommand(topicEStop, 'TRIGGER');
    _estopController.add(true);
  }

  Future<void> resetEStop() async {
    await sendCommand(topicEStop, 'RESET');
  }

  Future<void> sendMotor3Command(String command) async {
    await sendCommand(topicMotor3Cmd, command);
  }

  Future<void> sendMotor4Command(String command) async {
    await sendCommand(topicMotor4Cmd, command);
  }

  void sendSchedule(String jsonPayload) {
    if (!isConnected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonPayload);
    client.publishMessage(topicScheduleSet, MqttQos.atLeastOnce, builder.payload!);
    print('📤 Schedule sent');
  }

  void disconnect() {
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      client.disconnect();
    }
    isConnected = false;
  }

  void dispose() {
    disconnect();
    _doorStatusController.close();
    _scraperStatusController.close();
    _feederStatusController.close();
    _lightStatusController.close();
    _inCountController.close();
    _outCountController.close();
    _connectionStatusController.close();
    _commandResponseController.close();
    _motor3StatusController.close();
    _motor4StatusController.close();
    _estopController.close();
    _lockoutController.close();
    _scheduleLogController.close();
  }
}

// ==================== STATUS CLASSES ====================
class DoorStatus {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') return '$limitHit HIT';
    if (status == 'OPENING') return 'OPENING';
    if (status == 'CLOSING') return 'CLOSING';
    if (status == 'LIMIT HIT') return 'LIMIT HIT';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'OPENING' || status == 'CLOSING') return Colors.blue;
    if (status == 'LIMIT HIT') return Colors.redAccent;
    return Colors.green;
  }

  bool get canMoveUp => limitHit != 'UP LIMIT';
  bool get canMoveDown => limitHit != 'DOWN LIMIT';
}

class ScraperStatus {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') return '$limitHit HIT';
    if (status == 'FORWARD') return 'FORWARD';
    if (status == 'REVERSE') return 'REVERSE';
    if (status == 'LIMIT HIT') return 'LIMIT HIT';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'FORWARD' || status == 'REVERSE') return Colors.blue;
    if (status == 'LIMIT HIT') return Colors.redAccent;
    return Colors.green;
  }

  bool get canMoveForward => limitHit != 'FRONT LIMIT';
  bool get canMoveReverse => limitHit != 'BACK LIMIT';
}

class FeederStatus {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') return '$limitHit HIT';
    if (status == 'OPENING') return 'OPENING';
    if (status == 'CLOSING') return 'CLOSING';
    if (status == 'LIMIT HIT') return 'LIMIT HIT';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'OPENING' || status == 'CLOSING') return Colors.blue;
    if (status == 'LIMIT HIT') return Colors.redAccent;
    return Colors.green;
  }

  bool get canMoveOpen => limitHit != 'OPEN LIMIT';
  bool get canMoveClose => limitHit != 'CLOSE LIMIT';
}

class Motor3Status {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') return '$limitHit HIT';
    if (status == 'RUNNING') return 'RUNNING';
    if (status == 'REVERSING') return 'REVERSING';
    if (status == 'STOPPED') return 'STOPPED';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'RUNNING' || status == 'REVERSING') return Colors.blue;
    if (status == 'READY') return Colors.green;
    if (status == 'STOPPED') return Colors.grey;
    return Colors.grey;
  }

  bool get canMoveForward => limitHit != 'FRONT LIMIT';
  bool get canMoveReverse => limitHit != 'BACK LIMIT';
}

class Motor4Status {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') return '$limitHit HIT';
    if (status == 'RUNNING') return 'RUNNING';
    if (status == 'REVERSING') return 'REVERSING';
    if (status == 'STOPPED') return 'STOPPED';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'RUNNING' || status == 'REVERSING') return Colors.blue;
    if (status == 'READY') return Colors.green;
    if (status == 'STOPPED') return Colors.grey;
    return Colors.grey;
  }

  bool get canMoveForward => limitHit != 'FRONT LIMIT';
  bool get canMoveReverse => limitHit != 'BACK LIMIT';
}
