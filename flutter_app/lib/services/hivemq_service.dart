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

  // Public streams
  Stream<DoorStatus> get doorStatusStream => _doorStatusController.stream;
  Stream<ScraperStatus> get scraperStatusStream =>
      _scraperStatusController.stream;
  Stream<int> get inCountStream => _inCountController.stream;
  Stream<int> get outCountStream => _outCountController.stream;
  Stream<String> get connectionStatusStream =>
      _connectionStatusController.stream;
  Stream<String> get commandResponseStream => _commandResponseController.stream;
  Stream<Motor3Status> get motor3StatusStream => _motor3StatusController.stream;
  Stream<Motor4Status> get motor4StatusStream => _motor4StatusController.stream;

  bool isConnected = false;

  // Topics
  static const String topicSystemStatus = 'farm/system/status';
  static const String topicDoorCmd = 'farm/door/cmd';
  static const String topicScraperCmd = 'farm/scraper/cmd';
  static const String topicInCount = 'farm/chickens/in';
  static const String topicOutCount = 'farm/chickens/out';
  static const String topicMotor3Cmd = 'farm/motor3/cmd';
  static const String topicMotor4Cmd = 'farm/motor4/cmd';
  static const String topicMotor3Status = 'farm/motor3/status';
  static const String topicMotor4Status = 'farm/motor4/status';

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
      topicInCount,
      topicOutCount,
      topicMotor3Status,
      topicMotor4Status,
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
      } else if (topic == topicInCount) {
        try {
          final count = int.parse(message);
          _inCountController.add(count);
        } catch (e) {
          print('Error parsing in count: $e');
        }
      } else if (topic == topicOutCount) {
        try {
          final count = int.parse(message);
          _outCountController.add(count);
        } catch (e) {
          print('Error parsing out count: $e');
        }
      } else if (topic == topicMotor3Status) {
        _parseMotor3Status(message);
      } else if (topic == topicMotor4Status) {
        _parseMotor4Status(message);
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
        // Parse door part: "DOOR_LIMIT HIT" or "DOOR_OPENING" or "DOOR_READY"
        final doorPart = parts[0];
        if (doorPart.startsWith('DOOR_')) {
          String status = doorPart.substring(5); // Remove "DOOR_"
          doorStatus.status = status;
        }
        // Parse door limit: "UP LIMIT" or "DOWN LIMIT" or "NONE"
        doorStatus.limitHit = parts[1];
      }

      if (parts.length >= 4) {
        // Parse scraper part: "SCRAPER_READY" or "SCRAPER_LIMIT HIT"
        final scraperPart = parts[2];
        if (scraperPart.startsWith('SCRAPER_')) {
          String status = scraperPart.substring(8); // Remove "SCRAPER_"
          scraperStatus.status = status;
        }
        // Parse scraper limit: "FRONT LIMIT" or "BACK LIMIT" or "NONE"
        scraperStatus.limitHit = parts[3];
      }

      _doorStatusController.add(doorStatus);
      _scraperStatusController.add(scraperStatus);
    } catch (e) {
      print('Error parsing system status: $e');
      // Fallback: send default values
      DoorStatus doorStatus = DoorStatus();
      ScraperStatus scraperStatus = ScraperStatus();
      doorStatus.status = 'READY';
      doorStatus.limitHit = 'NONE';
      scraperStatus.status = 'READY';
      scraperStatus.limitHit = 'NONE';
      _doorStatusController.add(doorStatus);
      _scraperStatusController.add(scraperStatus);
    }
  }

  void _parseMotor3Status(String message) {
    try {
      final parts = message.split('|');
      Motor3Status motor3Status = Motor3Status();

      if (parts.length >= 2) {
        final motorPart = parts[0];
        if (motorPart.startsWith('MOTOR3_')) {
          String status = motorPart.substring(7);
          motor3Status.status = status;
        }
        motor3Status.limitHit = parts[1];
      }
      _motor3StatusController.add(motor3Status);
    } catch (e) {
      print('Error parsing motor3 status: $e');
      Motor3Status motor3Status = Motor3Status();
      motor3Status.status = message;
      motor3Status.limitHit = 'NONE';
      _motor3StatusController.add(motor3Status);
    }
  }

  void _parseMotor4Status(String message) {
    try {
      final parts = message.split('|');
      Motor4Status motor4Status = Motor4Status();

      if (parts.length >= 2) {
        final motorPart = parts[0];
        if (motorPart.startsWith('MOTOR4_')) {
          String status = motorPart.substring(7);
          motor4Status.status = status;
        }
        motor4Status.limitHit = parts[1];
      }
      _motor4StatusController.add(motor4Status);
    } catch (e) {
      print('Error parsing motor4 status: $e');
      Motor4Status motor4Status = Motor4Status();
      motor4Status.status = message;
      motor4Status.limitHit = 'NONE';
      _motor4StatusController.add(motor4Status);
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

  Future<void> sendMotor3Command(String command) async {
    await sendCommand(topicMotor3Cmd, command);
  }

  Future<void> sendMotor4Command(String command) async {
    await sendCommand(topicMotor4Cmd, command);
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
    _inCountController.close();
    _outCountController.close();
    _connectionStatusController.close();
    _commandResponseController.close();
    _motor3StatusController.close();
    _motor4StatusController.close();
  }
}

// ==================== STATUS CLASSES ====================
class DoorStatus {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') {
      return '$limitHit HIT';
    }
    if (status == 'OPENING') return 'OPENING';
    if (status == 'CLOSING') return 'CLOSING';
    if (status == 'LIMIT HIT') return 'LIMIT HIT';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'OPENING' || status == 'CLOSING') return Colors.blue;
    if (status == 'READY') return Colors.green;
    if (status == 'LIMIT HIT') return Colors.redAccent;
    return Colors.grey;
  }

  bool get canMoveUp {
    return limitHit != 'UP LIMIT';
  }

  bool get canMoveDown {
    return limitHit != 'DOWN LIMIT';
  }
}

class ScraperStatus {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') {
      return '$limitHit HIT';
    }
    if (status == 'FORWARD') return 'FORWARD';
    if (status == 'REVERSE') return 'REVERSE';
    if (status == 'LIMIT HIT') return 'LIMIT HIT';
    return 'READY';
  }

  Color get color {
    if (limitHit != 'NONE') return Colors.redAccent;
    if (status == 'FORWARD' || status == 'REVERSE') return Colors.blue;
    if (status == 'READY') return Colors.green;
    if (status == 'LIMIT HIT') return Colors.redAccent;
    return Colors.grey;
  }

  bool get canMoveForward {
    return limitHit != 'FRONT LIMIT';
  }

  bool get canMoveReverse {
    return limitHit != 'BACK LIMIT';
  }
}

// Add these after ScraperStatus class
class Motor3Status {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') {
      return '$limitHit HIT';
    }
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

  bool get canMoveForward {
    return limitHit != 'FRONT LIMIT';
  }

  bool get canMoveReverse {
    return limitHit != 'BACK LIMIT';
  }
}

class Motor4Status {
  String status = 'READY';
  String limitHit = 'NONE';

  String get displayText {
    if (limitHit != 'NONE') {
      return '$limitHit HIT';
    }
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

  bool get canMoveForward {
    return limitHit != 'FRONT LIMIT';
  }

  bool get canMoveReverse {
    return limitHit != 'BACK LIMIT';
  }
}
