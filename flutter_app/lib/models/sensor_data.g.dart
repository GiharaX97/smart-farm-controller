// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sensor_data.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SensorData _$SensorDataFromJson(Map<String, dynamic> json) => SensorData(
  deviceId: json['deviceId'] as String,
  timestamp: (json['timestamp'] as num).toInt(),
  doorStatus: json['doorStatus'] as String,
  scraperStatus: json['scraperStatus'] as String,
  motor3Status: json['motor3Status'] as String,
  motor4Status: json['motor4Status'] as String,
  inCount: (json['inCount'] as num).toInt(),
  outCount: (json['outCount'] as num).toInt(),
  doorLimit: json['doorLimit'] as String,
  scraperLimit: json['scraperLimit'] as String,
);

Map<String, dynamic> _$SensorDataToJson(SensorData instance) =>
    <String, dynamic>{
      'deviceId': instance.deviceId,
      'timestamp': instance.timestamp,
      'doorStatus': instance.doorStatus,
      'scraperStatus': instance.scraperStatus,
      'motor3Status': instance.motor3Status,
      'motor4Status': instance.motor4Status,
      'inCount': instance.inCount,
      'outCount': instance.outCount,
      'doorLimit': instance.doorLimit,
      'scraperLimit': instance.scraperLimit,
    };
