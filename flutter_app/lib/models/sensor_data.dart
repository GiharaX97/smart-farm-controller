import 'package:json_annotation/json_annotation.dart';

part 'sensor_data.g.dart';

@JsonSerializable()
class SensorData {
  final String deviceId;
  final int timestamp;
  final String doorStatus;
  final String scraperStatus;
  final String motor3Status;
  final String motor4Status;
  final int inCount;
  final int outCount;
  final String doorLimit;
  final String scraperLimit;

  SensorData({
    required this.deviceId,
    required this.timestamp,
    required this.doorStatus,
    required this.scraperStatus,
    required this.motor3Status,
    required this.motor4Status,
    required this.inCount,
    required this.outCount,
    required this.doorLimit,
    required this.scraperLimit,
  });

  factory SensorData.fromJson(Map<String, dynamic> json) =>
      _$SensorDataFromJson(json);
  Map<String, dynamic> toJson() => _$SensorDataToJson(this);

  // Empty/default sensor data for initial state
  static SensorData empty() {
    return SensorData(
      deviceId: '',
      timestamp: 0,
      doorStatus: 'READY',
      scraperStatus: 'READY',
      motor3Status: 'READY',
      motor4Status: 'READY',
      inCount: 0,
      outCount: 0,
      doorLimit: 'NONE',
      scraperLimit: 'NONE',
    );
  }
}
