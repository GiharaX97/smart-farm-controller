#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <VL53L0X.h>
#include <Wire.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <time.h>

// ==================== VERSION ====================
#define FW_VERSION "v2.0"

// ==================== PIN DEFINITIONS ====================

// Door Motor (BTS7960B)
#define DOOR_RPWM 4
#define DOOR_LPWM 5
#define DOOR_REN  6
#define DOOR_LEN  7

// Scraper Motor (BTS7960B)
#define SCRAPER_RPWM 15
#define SCRAPER_LPWM 16
#define SCRAPER_REN  40
#define SCRAPER_LEN  39

// Door Limit Switches (NC Mode - HIGH when pressed)
#define D_UP_LS    19
#define D_DOWN_LS  20

// Scraper Limit Switches (NC Mode - HIGH when pressed)
#define S_FRONT_LS 1
#define S_BACK_LS  2

// Feeder Motor (L293D via CD4050BE)
#define FEEDER_IN1   9
#define FEEDER_IN2   10
#define FEEDER_EN    3
#define FEEDER_OPEN  41   // NC limit - HIGH when open
#define FEEDER_CLOSE 42   // NC limit - HIGH when closed

// Light Relay (12V 1CH with optocoupler)
#define LIGHT_RELAY 38

// E-Stop Button (NC contact, hardware interrupt)
#define BTN_ESTOP   48

// VL53L0X Sensors
#define S1_SDA 18
#define S1_SCL 8
#define S2_SDA 21
#define S2_SCL 17

// Manual Switches
#define BTN_DOOR_OPEN      14
#define BTN_DOOR_CLOSE     13
#define BTN_SCRAPER_FWD    12
#define BTN_SCRAPER_REV    11

// ==================== MQTT CONFIGURATION ====================
const char* MQTT_SERVER = "9ab7d2b2fca840559bb01e402f89a1ad.s1.eu.hivemq.cloud";
const int MQTT_PORT = 8883;
const char* MQTT_USER = "farm_CLI";
const char* MQTT_PASS = "Farm@1234";

WiFiClientSecure espClient;
PubSubClient client(espClient);

#define MQTT_SYSTEM_STATUS    "farm/system/status"
#define MQTT_DOOR_CMD         "farm/door/cmd"
#define MQTT_SCRAPER_CMD      "farm/scraper/cmd"
#define MQTT_FEEDER_CMD       "farm/feeder/cmd"
#define MQTT_FEEDER_STATUS    "farm/feeder/status"
#define MQTT_LIGHT_CMD        "farm/light/cmd"
#define MQTT_LIGHT_STATUS     "farm/light/status"
#define MQTT_ESTOP            "farm/estop"
#define MQTT_LOCKOUT          "farm/lockout"
#define MQTT_SYNC             "farm/sync"
#define MQTT_HEARTBEAT        "farm/heartbeat"
#define MQTT_SCHEDULE_SET     "farm/schedule/set"
#define MQTT_SCHEDULE_LOG     "farm/schedule/log"
#define MQTT_MOTOR3_CMD       "farm/motor3/cmd"
#define MQTT_MOTOR4_CMD       "farm/motor4/cmd"
#define MQTT_MOTOR3_STATUS    "farm/motor3/status"
#define MQTT_MOTOR4_STATUS    "farm/motor4/status"
#define MQTT_IN_COUNT         "farm/chickens/in"
#define MQTT_OUT_COUNT        "farm/chickens/out"

// ==================== MOTOR SETTINGS ====================
const int PWM_FREQ = 5000;
const int PWM_RES = 10;
const int DUTY = 800;
const unsigned long maxMotorRunTimeMs = 15000;
const unsigned long FEEDER_TIMEOUT = 10000;

// ==================== NVS PREFERENCES ====================
Preferences prefs;

// ==================== STATE - DOOR ====================
bool doorMoving = false;
bool doorForward = true;
unsigned long doorStartTime = 0;
String doorStatus = "READY";
String doorLimitHit = "NONE";

// ==================== STATE - SCRAPER ====================
bool scraperMoving = false;
bool scraperForward = true;
unsigned long scraperStartTime = 0;
String scraperStatus = "READY";
String scraperLimitHit = "NONE";

// Scraper Auto-Cycle
bool scraperAutoCycling = false;
int scraperCyclesTarget = 0;
int scraperCyclesCompleted = 0;

// ==================== STATE - FEEDER ====================
bool feederMoving = false;
bool feederForward = true;
unsigned long feederStartTime = 0;
String feederStatus = "READY";
String feederLimitHit = "NONE";

// ==================== STATE - LIGHT ====================
bool lightOn = false;

// ==================== STATE - OTHER ====================
String motor3Status = "READY";
String motor4Status = "READY";
unsigned long inCount = 0;
unsigned long outCount = 0;

// ==================== LOCKOUT STATE ====================
String lockoutState = "NONE";  // NONE, SCHEDULE, SCRAPER_CYCLE, ALL, ESTOP
unsigned long scheduleLockoutEnd = 0;
const unsigned long SCHEDULE_LOCKOUT_MS = 2000;
bool emergencyStopped = false;

// ==================== VL53L0X ====================
VL53L0X sensor1;
VL53L0X sensor2;

// ==================== TIMING ====================
unsigned long lastReconnectAttempt = 0;
unsigned long lastSensorRead = 0;
unsigned long lastStatusPublish = 0;
unsigned long lastButtonPress = 0;
unsigned long lastHeartbeat = 0;
unsigned long lastScheduleCheck = 0;
unsigned long lastNtpSync = 0;
const unsigned long DEBOUNCE_DELAY = 200;
const unsigned long HEARTBEAT_INTERVAL = 30000;
const unsigned long NTP_SYNC_INTERVAL = 3600000;  // Every hour

// ==================== TIME / NTP ====================
bool timeSynced = false;
const char* NTP_SERVER = "pool.ntp.org";
const long GMT_OFFSET_SEC = 19800;  // +5:30 (Sri Lanka)
const int DAYLIGHT_OFFSET_SEC = 0;

// ==================== SCHEDULE SYSTEM ====================
#define MAX_ALARMS 15

struct Alarm {
  String id;
  String device;
  String action;
  int hour;
  int minute;
  int cycles;
  bool enabled;
};

Alarm alarms[MAX_ALARMS];
int alarmCount = 0;
bool scheduleActive = false;

// ==================== E-STOP ISR ====================
volatile bool eStopTriggered = false;

void IRAM_ATTR handleEStop() {
  eStopTriggered = true;
  // Kill ALL motor outputs immediately
  digitalWrite(DOOR_REN, LOW);
  digitalWrite(DOOR_LEN, LOW);
  ledcWrite(DOOR_RPWM, 0);
  ledcWrite(DOOR_LPWM, 0);
  digitalWrite(SCRAPER_REN, LOW);
  digitalWrite(SCRAPER_LEN, LOW);
  ledcWrite(SCRAPER_RPWM, 0);
  ledcWrite(SCRAPER_LPWM, 0);
  digitalWrite(FEEDER_EN, LOW);
  digitalWrite(FEEDER_IN1, LOW);
  digitalWrite(FEEDER_IN2, LOW);
  digitalWrite(LIGHT_RELAY, LOW);
}

// ==================== LIMIT CHECK FUNCTIONS ====================
bool isDoorUpLimit() { return digitalRead(D_UP_LS) == HIGH; }
bool isDoorDownLimit() { return digitalRead(D_DOWN_LS) == HIGH; }
bool isScraperFrontLimit() { return digitalRead(S_FRONT_LS) == HIGH; }
bool isScraperBackLimit() { return digitalRead(S_BACK_LS) == HIGH; }
bool isFeederOpenLimit() { return digitalRead(FEEDER_OPEN) == HIGH; }
bool isFeederCloseLimit() { return digitalRead(FEEDER_CLOSE) == HIGH; }
bool isEStopPressed() { return digitalRead(BTN_ESTOP) == LOW; }

// ==================== LOCKOUT CHECKS ====================
bool isManualBlocked(String device) {
  if (emergencyStopped || eStopTriggered) return true;
  if (lockoutState == "ESTOP" || lockoutState == "ALL") return true;
  if (lockoutState == "SCRAPER_CYCLE" && device == "scraper") return true;
  if (scheduleActive && millis() < scheduleLockoutEnd) return true;
  return false;
}

void setLockout(String state) {
  lockoutState = state;
  client.publish(MQTT_LOCKOUT, state.c_str(), true);
}

// ==================== E-STOP HANDLING ====================
void triggerEStop() {
  if (emergencyStopped) return;
  
  emergencyStopped = true;
  eStopTriggered = false;
  
  // Stop all motors
  stopDoor();
  stopScraper();
  stopFeeder();
  digitalWrite(LIGHT_RELAY, LOW);
  lightOn = false;
  
  setLockout("ESTOP");
  client.publish(MQTT_ESTOP, "ACTIVE", true);
  Serial.println("🚨 E-STOP TRIGGERED — ALL MOTORS STOPPED");
}

void resetEStop() {
  if (digitalRead(BTN_ESTOP) == LOW) {
    Serial.println("⚠️ E-Stop reset failed — button still pressed!");
    client.publish(MQTT_SYSTEM_STATUS, "ESTOP_RESET_FAILED_PRESSED", true);
    return;
  }
  
  emergencyStopped = false;
  eStopTriggered = false;
  setLockout("NONE");
  client.publish(MQTT_ESTOP, "READY", true);
  Serial.println("✅ E-STOP RESET — System ready");
}

void checkEStopHardware() {
  if (eStopTriggered && !emergencyStopped) {
    triggerEStop();
  }
  // Redundant software check
  if (!emergencyStopped && isEStopPressed()) {
    triggerEStop();
  }
}

// ==================== UPDATE STATUS ====================
void updateDoorStatus() {
  if (doorMoving) {
    doorStatus = doorForward ? "OPENING" : "CLOSING";
    doorLimitHit = "NONE";
  } else if (isDoorUpLimit()) {
    doorStatus = "LIMIT HIT";
    doorLimitHit = "UP LIMIT";
  } else if (isDoorDownLimit()) {
    doorStatus = "LIMIT HIT";
    doorLimitHit = "DOWN LIMIT";
  } else {
    doorStatus = "READY";
    doorLimitHit = "NONE";
  }
}

void updateScraperStatus() {
  if (scraperMoving) {
    scraperStatus = scraperForward ? "FORWARD" : "REVERSE";
    scraperLimitHit = "NONE";
  } else if (isScraperFrontLimit()) {
    scraperStatus = "LIMIT HIT";
    scraperLimitHit = "FRONT LIMIT";
  } else if (isScraperBackLimit()) {
    scraperStatus = "LIMIT HIT";
    scraperLimitHit = "BACK LIMIT";
  } else {
    scraperStatus = "READY";
    scraperLimitHit = "NONE";
  }
}

void updateFeederStatus() {
  if (feederMoving) {
    feederStatus = feederForward ? "OPENING" : "CLOSING";
    feederLimitHit = "NONE";
  } else if (isFeederOpenLimit()) {
    feederStatus = "LIMIT HIT";
    feederLimitHit = "OPEN LIMIT";
  } else if (isFeederCloseLimit()) {
    feederStatus = "LIMIT HIT";
    feederLimitHit = "CLOSE LIMIT";
  } else {
    feederStatus = "READY";
    feederLimitHit = "NONE";
  }
}

// ==================== MOTOR CONTROL - DOOR ====================
void startDoor(bool forward) {
  if (isManualBlocked("door")) {
    Serial.println("⛔ Door blocked by lockout!");
    return;
  }
  digitalWrite(DOOR_REN, HIGH);
  digitalWrite(DOOR_LEN, HIGH);
  if (forward) {
    ledcWrite(DOOR_RPWM, DUTY);
    ledcWrite(DOOR_LPWM, 0);
    Serial.println("→ Door OPENING");
  } else {
    ledcWrite(DOOR_RPWM, 0);
    ledcWrite(DOOR_LPWM, DUTY);
    Serial.println("→ Door CLOSING");
  }
  doorMoving = true;
  doorForward = forward;
  doorStartTime = millis();
  updateDoorStatus();
}

void stopDoor() {
  digitalWrite(DOOR_REN, LOW);
  digitalWrite(DOOR_LEN, LOW);
  ledcWrite(DOOR_RPWM, 0);
  ledcWrite(DOOR_LPWM, 0);
  doorMoving = false;
  updateDoorStatus();
  Serial.println("→ Door STOPPED");
}

// ==================== MOTOR CONTROL - SCRAPER ====================
void startScraper(bool forward) {
  if (isManualBlocked("scraper")) {
    Serial.println("⛔ Scraper blocked by lockout!");
    return;
  }
  digitalWrite(SCRAPER_REN, HIGH);
  digitalWrite(SCRAPER_LEN, HIGH);
  if (forward) {
    ledcWrite(SCRAPER_RPWM, DUTY);
    ledcWrite(SCRAPER_LPWM, 0);
    Serial.println("→ Scraper FORWARD");
  } else {
    ledcWrite(SCRAPER_RPWM, 0);
    ledcWrite(SCRAPER_LPWM, DUTY);
    Serial.println("→ Scraper REVERSE");
  }
  scraperMoving = true;
  scraperForward = forward;
  scraperStartTime = millis();
  updateScraperStatus();
}

void stopScraper() {
  digitalWrite(SCRAPER_REN, LOW);
  digitalWrite(SCRAPER_LEN, LOW);
  ledcWrite(SCRAPER_RPWM, 0);
  ledcWrite(SCRAPER_LPWM, 0);
  scraperMoving = false;
  updateScraperStatus();
  Serial.println("→ Scraper STOPPED");
}

// ==================== MOTOR CONTROL - FEEDER ====================
void startFeeder(bool openDir) {
  if (isManualBlocked("feeder")) {
    Serial.println("⛔ Feeder blocked by lockout!");
    return;
  }
  digitalWrite(FEEDER_EN, HIGH);
  if (openDir) {
    digitalWrite(FEEDER_IN1, HIGH);
    digitalWrite(FEEDER_IN2, LOW);
    Serial.println("→ Feeder OPENING");
  } else {
    digitalWrite(FEEDER_IN1, LOW);
    digitalWrite(FEEDER_IN2, HIGH);
    Serial.println("→ Feeder CLOSING");
  }
  feederMoving = true;
  feederForward = openDir;
  feederStartTime = millis();
  updateFeederStatus();
}

void stopFeeder() {
  digitalWrite(FEEDER_EN, LOW);
  digitalWrite(FEEDER_IN1, LOW);
  digitalWrite(FEEDER_IN2, LOW);
  feederMoving = false;
  updateFeederStatus();
  Serial.println("→ Feeder STOPPED");
}

// ==================== LIGHT CONTROL ====================
void setLight(bool on) {
  digitalWrite(LIGHT_RELAY, on ? HIGH : LOW);
  lightOn = on;
  client.publish(MQTT_LIGHT_STATUS, on ? "ON" : "OFF", true);
  Serial.printf("→ Light %s\n", on ? "ON" : "OFF");
}

// ==================== CHECK LIMITS ====================
void checkDoorLimits() {
  if (!doorMoving) return;
  bool shouldStop = false;
  if (doorForward && isDoorUpLimit()) { shouldStop = true; }
  else if (!doorForward && isDoorDownLimit()) { shouldStop = true; }
  else if (millis() - doorStartTime > maxMotorRunTimeMs) { shouldStop = true; }
  if (shouldStop) { stopDoor(); publishSystemStatus(); }
}

void checkScraperLimits() {
  if (!scraperMoving) return;
  bool hitLimit = false;
  
  if (scraperForward && isScraperFrontLimit()) { hitLimit = true; }
  else if (!scraperForward && isScraperBackLimit()) { hitLimit = true; }
  else if (millis() - scraperStartTime > maxMotorRunTimeMs) { hitLimit = true; }
  
  if (hitLimit) {
    stopScraper();
    
    // Auto-cycle logic — only if active and NOT timeout
    if (scraperAutoCycling && scraperCyclesCompleted < scraperCyclesTarget) {
      scraperCyclesCompleted++;
      Serial.printf("[CYCLE] %d/%d completed\n", scraperCyclesCompleted, scraperCyclesTarget);
      
      if (scraperCyclesCompleted < scraperCyclesTarget) {
        delay(300);
        // Reverse direction
        startScraper(!scraperForward);
        // If blocked by limit on the other side, force complete
        if (!scraperMoving) {
          scraperAutoCycling = false;
          setLockout("NONE");
          scheduleActive = false;
          client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_CYCLE_DONE", true);
        }
        return;
      }
    }
    
    // Cycle complete
    if (scraperAutoCycling && scraperCyclesCompleted >= scraperCyclesTarget) {
      scraperAutoCycling = false;
      Serial.println("✅ SCRAPER CYCLE COMPLETE");
      setLockout("NONE");
      scheduleActive = false;
      client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_CYCLE_DONE", true);
    }
    
    publishSystemStatus();
  }
}

void checkFeederLimits() {
  if (!feederMoving) return;
  bool shouldStop = false;
  if (feederForward && isFeederOpenLimit()) { shouldStop = true; }
  else if (!feederForward && isFeederCloseLimit()) { shouldStop = true; }
  else if (millis() - feederStartTime > FEEDER_TIMEOUT) { shouldStop = true; }
  if (shouldStop) {
    stopFeeder();
    publishFeederStatus();
  }
}

// ==================== PUBLISH STATUS ====================
void publishSystemStatus() {
  updateDoorStatus();
  updateScraperStatus();
  String status = "DOOR_" + doorStatus + "|" + doorLimitHit + "|SCRAPER_" + scraperStatus + "|" + scraperLimitHit;
  if (client.connected()) {
    client.publish(MQTT_SYSTEM_STATUS, status.c_str(), true);
  }
  client.publish(MQTT_MOTOR3_STATUS, motor3Status.c_str(), true);
  client.publish(MQTT_MOTOR4_STATUS, motor4Status.c_str(), true);
}

void publishFeederStatus() {
  updateFeederStatus();
  String status = feederStatus + "|" + feederLimitHit;
  client.publish(MQTT_FEEDER_STATUS, status.c_str(), true);
}

// ==================== SCRAPER CYCLE START ====================
void startScraperCycle(int cycles) {
  if (emergencyStopped) return;
  if (scraperAutoCycling) {
    Serial.println("⛔ Cycle already running!");
    return;
  }
  
  scraperAutoCycling = true;
  scraperCyclesTarget = cycles;
  scraperCyclesCompleted = 0;
  setLockout("SCRAPER_CYCLE");
  scheduleActive = true;
  
  Serial.printf("🔁 Starting scraper cycle: %dx\n", cycles);
  client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_CYCLE_START", true);
  
  // Start forward if not at front limit
  if (!isScraperFrontLimit()) {
    startScraper(true);
  } else {
    startScraper(false);  // Start reverse instead
  }
}

// ==================== CHICKEN SENSORS ====================
void processSensors(int d1, int d2) {
  static unsigned long s1_time = 0, s2_time = 0;
  unsigned long now = millis();
  
  if (d1 >= 8190) d1 = 0;
  if (d2 >= 8190) d2 = 0;
  
  bool s1_act = (d1 > 20 && d1 < 300);
  bool s2_act = (d2 > 20 && d2 < 300);
  
  if (s1_act && s1_time == 0) { s1_time = now; }
  if (s2_act && s2_time == 0) { s2_time = now; }
  
  if (s1_time > 0 && s2_time > 0 && abs((long)s1_time - (long)s2_time) < 2000) {
    if (s1_time < s2_time) {
      inCount++;
      client.publish(MQTT_IN_COUNT, String(inCount).c_str(), true);
      saveCounts();
      Serial.printf("[COUNT] IN: %llu\n", inCount);
    } else {
      outCount++;
      client.publish(MQTT_OUT_COUNT, String(outCount).c_str(), true);
      saveCounts();
      Serial.printf("[COUNT] OUT: %llu\n", outCount);
    }
    s1_time = 0;
    s2_time = 0;
  }
  
  if (s1_time > 0 && now - s1_time > 3000) s1_time = 0;
  if (s2_time > 0 && now - s2_time > 3000) s2_time = 0;
}

// ==================== NVS PERSISTENCE ====================
void saveCounts() {
  prefs.putULong64("inCount", inCount);
  prefs.putULong64("outCount", outCount);
}

void loadCounts() {
  inCount = prefs.getULong64("inCount", 0);
  outCount = prefs.getULong64("outCount", 0);
  Serial.printf("[NVS] Loaded counts: IN=%llu OUT=%llu\n", inCount, outCount);
}

void saveSchedules() {
  String json = "[";
  for (int i = 0; i < alarmCount; i++) {
    if (i > 0) json += ",";
    json += "{\"id\":\"" + alarms[i].id + "\",";
    json += "\"device\":\"" + alarms[i].device + "\",";
    json += "\"action\":\"" + alarms[i].action + "\",";
    json += "\"hour\":" + String(alarms[i].hour) + ",";
    json += "\"minute\":" + String(alarms[i].minute) + ",";
    json += "\"cycles\":" + String(alarms[i].cycles) + ",";
    json += "\"enabled\":" + (alarms[i].enabled ? "true" : "false") + "}";
  }
  json += "]";
  prefs.putString("schedules", json);
  Serial.println("[NVS] Schedules saved");
}

void loadSchedules() {
  String json = prefs.getString("schedules", "[]");
  alarmCount = 0;
  
  // Simple JSON parser for schedule array
  int pos = 0;
  while ((pos = json.indexOf('{', pos)) >= 0 && alarmCount < MAX_ALARMS) {
    int endPos = json.indexOf('}', pos);
    if (endPos < 0) break;
    String obj = json.substring(pos, endPos + 1);
    pos = endPos + 1;
    
    Alarm a;
    a.id = extractJsonStr(obj, "id");
    a.device = extractJsonStr(obj, "device");
    a.action = extractJsonStr(obj, "action");
    a.hour = extractJsonInt(obj, "hour");
    a.minute = extractJsonInt(obj, "minute");
    a.cycles = extractJsonInt(obj, "cycles");
    a.enabled = extractJsonBool(obj, "enabled");
    
    alarms[alarmCount++] = a;
  }
  Serial.printf("[NVS] Loaded %d schedules\n", alarmCount);
}

String extractJsonStr(String json, String key) {
  String search = "\"" + key + "\":\"";
  int start = json.indexOf(search);
  if (start < 0) return "";
  start += search.length();
  int end = json.indexOf('"', start);
  if (end < 0) return "";
  return json.substring(start, end);
}

int extractJsonInt(String json, String key) {
  String search = "\"" + key + "\":";
  int start = json.indexOf(search);
  if (start < 0) return 0;
  start += search.length();
  int end = json.indexOf(',', start);
  if (end < 0) end = json.indexOf('}', start);
  if (end < 0) return 0;
  return json.substring(start, end).toInt();
}

bool extractJsonBool(String json, String key) {
  String search = "\"" + key + "\":";
  int start = json.indexOf(search);
  if (start < 0) return false;
  start += search.length();
  return json.substring(start, start + 4) == "true";
}

// ==================== NTP / TIME ====================
void syncNTP() {
  Serial.print("[NTP] Syncing...");
  configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
  
  struct tm timeinfo;
  int attempts = 0;
  while (!getLocalTime(&timeinfo, 5000) && attempts < 5) {
    delay(500);
    attempts++;
  }
  
  if (getLocalTime(&timeinfo, 1000)) {
    timeSynced = true;
    lastNtpSync = millis();
    Serial.println(" ✅ Synced");
    Serial.printf("[TIME] %04d-%02d-%02d %02d:%02d:%02d\n",
      timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
      timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
  } else {
    Serial.println(" ❌ Failed");
  }
}

// ==================== SCHEDULE CHECKER ====================
void checkAlarms() {
  if (!timeSynced) {
    if (millis() - lastNtpSync > NTP_SYNC_INTERVAL) syncNTP();
    return;
  }
  
  if (emergencyStopped) return;
  if (scheduleActive && millis() < scheduleLockoutEnd) return;
  
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo, 500)) return;
  
  static int lastCheckedMin = -1;
  int currentMin = timeinfo.tm_hour * 60 + timeinfo.tm_min;
  if (lastCheckedMin == currentMin) return;
  lastCheckedMin = currentMin;
  
  // Sync NTP every hour
  if (timeinfo.tm_min == 0 && millis() - lastNtpSync > NTP_SYNC_INTERVAL) {
    syncNTP();
  }
  
  for (int i = 0; i < alarmCount; i++) {
    if (!alarms[i].enabled) continue;
    if (alarms[i].hour == timeinfo.tm_hour && alarms[i].minute == timeinfo.tm_min) {
      executeAlarm(alarms[i]);
    }
  }
}

void executeAlarm(Alarm &alarm) {
  scheduleActive = true;
  scheduleLockoutEnd = millis() + SCHEDULE_LOCKOUT_MS;
  setLockout("SCHEDULE");
  
  String logMsg = "[SCHEDULE] " + alarm.device + " → " + alarm.action;
  Serial.println(logMsg);
  client.publish(MQTT_SCHEDULE_LOG, logMsg.c_str(), true);
  
  // Publish sync
  String syncMsg = "{\"from\":\"esp32s3\",\"device\":\"" + alarm.device + "\",\"action\":\"" + alarm.action + "\"}";
  client.publish(MQTT_SYNC, syncMsg.c_str(), true);
  
  if (alarm.device == "door1") {
    if (alarm.action == "open" && !isDoorUpLimit()) startDoor(true);
    else if (alarm.action == "close" && !isDoorDownLimit()) startDoor(false);
  }
  else if (alarm.device == "scraper") {
    if (alarm.action == "cycle") {
      startScraperCycle(alarm.cycles > 0 ? alarm.cycles : 3);
    } else if (alarm.action == "forward" && !isScraperFrontLimit()) startScraper(true);
    else if (alarm.action == "reverse" && !isScraperBackLimit()) startScraper(false);
  }
  else if (alarm.device == "feeder") {
    if (alarm.action == "open" && !isFeederOpenLimit()) startFeeder(true);
    else if (alarm.action == "close" && !isFeederCloseLimit()) startFeeder(false);
  }
  else if (alarm.device == "light") {
    setLight(alarm.action == "on");
  }
  else if (alarm.device == "door2") {
    client.publish(MQTT_SYNC, syncMsg.c_str(), true);
  }
}

// ==================== HANDLE MANUAL SWITCHES ====================
void handleManualSwitches() {
  unsigned long now = millis();
  if (now - lastButtonPress < DEBOUNCE_DELAY) return;
  if (emergencyStopped) return;
  
  // Door OPEN button
  if (digitalRead(BTN_DOOR_OPEN) == LOW) {
    lastButtonPress = now;
    if (!isDoorUpLimit() && !isManualBlocked("door")) {
      if (doorMoving) stopDoor();
      delay(50);
      startDoor(true);
      client.publish(MQTT_DOOR_CMD, "START", true);
      publishSystemStatus();
    }
  }
  
  // Door CLOSE button
  if (digitalRead(BTN_DOOR_CLOSE) == LOW) {
    lastButtonPress = now;
    if (!isDoorDownLimit() && !isManualBlocked("door")) {
      if (doorMoving) stopDoor();
      delay(50);
      startDoor(false);
      client.publish(MQTT_DOOR_CMD, "REVERSE", true);
      publishSystemStatus();
    }
  }
  
  // Scraper FORWARD button
  if (digitalRead(BTN_SCRAPER_FWD) == LOW) {
    lastButtonPress = now;
    if (!isScraperFrontLimit() && !isManualBlocked("scraper")) {
      if (scraperMoving) stopScraper();
      delay(50);
      startScraper(true);
      client.publish(MQTT_SCRAPER_CMD, "START", true);
      publishSystemStatus();
    }
  }
  
  // Scraper REVERSE button
  if (digitalRead(BTN_SCRAPER_REV) == LOW) {
    lastButtonPress = now;
    if (!isScraperBackLimit() && !isManualBlocked("scraper")) {
      if (scraperMoving) stopScraper();
      delay(50);
      startScraper(false);
      client.publish(MQTT_SCRAPER_CMD, "REVERSE", true);
      publishSystemStatus();
    }
  }
}

// ==================== MQTT CALLBACK ====================
void callback(char* topic, byte* payload, unsigned int length) {
  if (emergencyStopped) return;
  
  String msg = "";
  for (unsigned int i = 0; i < length; i++) msg += (char)payload[i];
  msg.toUpperCase();
  msg.trim();
  
  String topicStr = String(topic);
  
  // --- E-Stop ---
  if (topicStr == MQTT_ESTOP) {
    if (msg == "TRIGGER") { triggerEStop(); return; }
    if (msg == "RESET") { resetEStop(); return; }
  }
  if (emergencyStopped) return;
  
  // --- Door ---
  if (topicStr == MQTT_DOOR_CMD) {
    if (msg == "START" && !isDoorUpLimit()) {
      if (doorMoving) stopDoor();
      delay(50);
      startDoor(true);
      publishSystemStatus();
    } else if (msg == "REVERSE" && !isDoorDownLimit()) {
      if (doorMoving) stopDoor();
      delay(50);
      startDoor(false);
      publishSystemStatus();
    } else if (msg == "STOP") {
      stopDoor();
      publishSystemStatus();
    }
  }
  
  // --- Scraper ---
  else if (topicStr == MQTT_SCRAPER_CMD) {
    if (msg == "CYCLE") {
      int cycles = 3;
      // Try to parse cycles from message like "CYCLE:5"
      int colonIdx = msg.indexOf(':');
      if (colonIdx > 0) cycles = msg.substring(colonIdx + 1).toInt();
      startScraperCycle(cycles > 0 ? cycles : 3);
    } else if (scraperAutoCycling) {
      Serial.println("⛔ Scraper locked — auto-cycle in progress!");
      client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_LOCKED_CYCLE", true);
    } else if (msg == "START" && !isScraperFrontLimit()) {
      if (scraperMoving) stopScraper();
      delay(50);
      startScraper(true);
      publishSystemStatus();
    } else if (msg == "REVERSE" && !isScraperBackLimit()) {
      if (scraperMoving) stopScraper();
      delay(50);
      startScraper(false);
      publishSystemStatus();
    } else if (msg == "STOP") {
      stopScraper();
      publishSystemStatus();
    }
  }
  
  // --- Feeder ---
  else if (topicStr == MQTT_FEEDER_CMD) {
    if (msg == "START" && !isFeederOpenLimit()) {
      if (feederMoving) stopFeeder();
      delay(50);
      startFeeder(true);
      publishFeederStatus();
    } else if (msg == "REVERSE" && !isFeederCloseLimit()) {
      if (feederMoving) stopFeeder();
      delay(50);
      startFeeder(false);
      publishFeederStatus();
    } else if (msg == "STOP") {
      stopFeeder();
      publishFeederStatus();
    }
  }
  
  // --- Light ---
  else if (topicStr == MQTT_LIGHT_CMD) {
    if (msg == "ON") setLight(true);
    else if (msg == "OFF") setLight(false);
    else if (msg == "TOGGLE") setLight(!lightOn);
  }
  
  // --- Schedule ---
  else if (topicStr == MQTT_SCHEDULE_SET) {
    String original = "";
    for (unsigned int i = 0; i < length; i++) original += (char)payload[i];
    prefs.putString("schedules", original);
    loadSchedules();
    client.publish(MQTT_SCHEDULE_LOG, "SCHEDULES_UPDATED", true);
  }
  
  // --- Motor 3 & 4 ---
  else if (topicStr == MQTT_MOTOR3_CMD) {
    if (msg == "START") motor3Status = "RUNNING";
    else if (msg == "REVERSE") motor3Status = "REVERSING";
    else if (msg == "STOP") motor3Status = "STOPPED";
    client.publish(MQTT_MOTOR3_STATUS, motor3Status.c_str(), true);
  }
  else if (topicStr == MQTT_MOTOR4_CMD) {
    if (msg == "START") motor4Status = "RUNNING";
    else if (msg == "REVERSE") motor4Status = "REVERSING";
    else if (msg == "STOP") motor4Status = "STOPPED";
    client.publish(MQTT_MOTOR4_STATUS, motor4Status.c_str(), true);
  }
}

// ==================== MQTT RECONNECT ====================
void reconnectMQTT() {
  Serial.print("Connecting to HiveMQ...");
  if (client.connect("ESP32_Farm_S3", MQTT_USER, MQTT_PASS)) {
    Serial.println(" ✅ Connected!");
    
    client.subscribe(MQTT_DOOR_CMD);
    client.subscribe(MQTT_SCRAPER_CMD);
    client.subscribe(MQTT_FEEDER_CMD);
    client.subscribe(MQTT_LIGHT_CMD);
    client.subscribe(MQTT_ESTOP);
    client.subscribe(MQTT_SCHEDULE_SET);
    client.subscribe(MQTT_MOTOR3_CMD);
    client.subscribe(MQTT_MOTOR4_CMD);
    client.subscribe(MQTT_SYNC);
    
    client.publish(MQTT_SYSTEM_STATUS, "ESP32_ONLINE_" + String(FW_VERSION), true);
    client.publish(MQTT_MOTOR3_STATUS, "READY", true);
    client.publish(MQTT_MOTOR4_STATUS, "READY", true);
    client.publish(MQTT_ESTOP, emergencyStopped ? "ACTIVE" : "READY", true);
    client.publish(MQTT_LOCKOUT, lockoutState.c_str(), true);
    client.publish(MQTT_IN_COUNT, String(inCount).c_str(), true);
    client.publish(MQTT_OUT_COUNT, String(outCount).c_str(), true);
    client.publish(MQTT_LIGHT_STATUS, lightOn ? "ON" : "OFF", true);
    publishFeederStatus();
    publishSystemStatus();
    
    // Sync time on reconnect
    syncNTP();
  } else {
    Serial.printf(" ❌ Failed, rc=%d\n", client.state());
  }
}

// ==================== SERIAL STATUS ====================
void printLocalStatus() {
  static unsigned long lastPrint = 0;
  if (millis() - lastPrint > 2000) {
    lastPrint = millis();
    Serial.println("\n┌──────────────────────────────────────────────────────┐");
    Serial.println("│              SMART FARM CONTROLLER " + String(FW_VERSION) + "              │");
    Serial.println("├──────────────────────────────────────────────────────┤");
    
    Serial.print("│ DOOR:    ");
    if (doorMoving) Serial.print(doorForward ? "OPENING ↑" : "CLOSING ↓");
    else if (isDoorUpLimit()) Serial.print("UP LIMIT");
    else if (isDoorDownLimit()) Serial.print("DOWN LIMIT");
    else Serial.print("READY");
    Serial.println("                          │");
    
    Serial.print("│ SCRAPER: ");
    if (scraperMoving) Serial.print(scraperForward ? "FORWARD →" : "REVERSE ←");
    else if (scraperAutoCycling) Serial.printf("CYCLE %d/%d ", scraperCyclesCompleted, scraperCyclesTarget);
    else if (isScraperFrontLimit()) Serial.print("FRONT LIMIT");
    else if (isScraperBackLimit()) Serial.print("BACK LIMIT");
    else Serial.print("READY");
    if (scraperAutoCycling) Serial.printf("(%d/%d)", scraperCyclesCompleted, scraperCyclesTarget);
    Serial.println("                      │");
    
    Serial.print("│ FEEDER:  ");
    if (feederMoving) Serial.print(feederForward ? "OPENING ↑" : "CLOSING ↓");
    else if (isFeederOpenLimit()) Serial.print("OPEN LIMIT");
    else if (isFeederCloseLimit()) Serial.print("CLOSE LIMIT");
    else Serial.print("READY");
    Serial.println("                         │");
    
    Serial.printf("│ LIGHT:   %s                              │\n", lightOn ? "ON " : "OFF");
    Serial.printf("│ COUNTERS: IN=%llu  OUT=%llu                  │\n", inCount, outCount);
    
    Serial.print("│ LOCKOUT: ");
    if (emergencyStopped) Serial.print("🚨 E-STOP");
    else if (lockoutState == "SCRAPER_CYCLE") Serial.print("🔄 CYCLE");
    else if (lockoutState == "SCHEDULE") Serial.print("⏰ SCHEDULE");
    else if (lockoutState == "ALL") Serial.print("⛔ ALL");
    else Serial.print("✅ NONE");
    Serial.println("                         │");
    
    Serial.print("│ TIME:    ");
    if (timeSynced) {
      struct tm timeinfo;
      getLocalTime(&timeinfo, 500);
      Serial.printf("%02d:%02d:%02d", timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
    } else {
      Serial.print("Not synced");
    }
    Serial.println("                         │");
    
    Serial.println("└──────────────────────────────────────────────────────┘");
  }
}

// ==================== SETUP ====================
void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n╔════════════════════════════════════════╗");
  Serial.printf("║   SMART FARM CONTROLLER %s          ║\n", FW_VERSION);
  Serial.println("║   Door + Scraper + Feeder + Light    ║");
  Serial.println("║   E-Stop + Schedules + Lockout       ║");
  Serial.println("╚════════════════════════════════════════╝\n");
  
  // Initialize NVS
  prefs.begin("farm-nvs", false);
  loadCounts();
  loadSchedules();
  
  // Configure limit switch pins
  pinMode(D_UP_LS, INPUT_PULLUP);
  pinMode(D_DOWN_LS, INPUT_PULLUP);
  pinMode(S_FRONT_LS, INPUT_PULLUP);
  pinMode(S_BACK_LS, INPUT_PULLUP);
  pinMode(FEEDER_OPEN, INPUT_PULLUP);
  pinMode(FEEDER_CLOSE, INPUT_PULLUP);
  pinMode(BTN_ESTOP, INPUT_PULLUP);
  
  // Configure manual buttons
  pinMode(BTN_DOOR_OPEN, INPUT_PULLUP);
  pinMode(BTN_DOOR_CLOSE, INPUT_PULLUP);
  pinMode(BTN_SCRAPER_FWD, INPUT_PULLUP);
  pinMode(BTN_SCRAPER_REV, INPUT_PULLUP);
  
  // Configure motor enable pins
  pinMode(DOOR_REN, OUTPUT);
  pinMode(DOOR_LEN, OUTPUT);
  pinMode(SCRAPER_REN, OUTPUT);
  pinMode(SCRAPER_LEN, OUTPUT);
  pinMode(FEEDER_IN1, OUTPUT);
  pinMode(FEEDER_IN2, OUTPUT);
  pinMode(FEEDER_EN, OUTPUT);
  pinMode(LIGHT_RELAY, OUTPUT);
  
  // Set all to LOW/0 on startup
  digitalWrite(DOOR_REN, LOW);
  digitalWrite(DOOR_LEN, LOW);
  digitalWrite(SCRAPER_REN, LOW);
  digitalWrite(SCRAPER_LEN, LOW);
  digitalWrite(FEEDER_IN1, LOW);
  digitalWrite(FEEDER_IN2, LOW);
  digitalWrite(FEEDER_EN, LOW);
  digitalWrite(LIGHT_RELAY, LOW);
  
  // Configure PWM
  ledcAttach(DOOR_RPWM, PWM_FREQ, PWM_RES);
  ledcAttach(DOOR_LPWM, PWM_FREQ, PWM_RES);
  ledcAttach(SCRAPER_RPWM, PWM_FREQ, PWM_RES);
  ledcAttach(SCRAPER_LPWM, PWM_FREQ, PWM_RES);
  
  // E-Stop interrupt (FALLING edge — NC goes LOW when pressed)
  pinMode(BTN_ESTOP, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(BTN_ESTOP), handleEStop, FALLING);
  
  // WiFi Setup
  WiFiManager wm;
  wm.setDarkMode(true);
  wm.setConfigPortalTimeout(180);
  
  Serial.println("\n[WiFi] Connecting...");
  if (!wm.autoConnect("Farm_Controller_Setup")) {
    Serial.println("[WiFi] Failed, restarting...");
    delay(3000);
    ESP.restart();
  }
  
  Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
  
  // MQTT Setup
  espClient.setInsecure();
  client.setServer(MQTT_SERVER, MQTT_PORT);
  client.setCallback(callback);
  client.setKeepAlive(240);
  
  // VL53L0X Sensors
  Wire.begin(S1_SDA, S1_SCL, 400000);
  Wire1.begin(S2_SDA, S2_SCL, 400000);
  
  sensor1.setBus(&Wire);
  sensor2.setBus(&Wire1);
  
  if (sensor1.init()) { sensor1.startContinuous(); Serial.println("[SENSOR1] VL53L0X ready"); }
  else { Serial.println("[SENSOR1] VL53L0X FAILED"); }
  
  if (sensor2.init()) { sensor2.startContinuous(); Serial.println("[SENSOR2] VL53L0X ready"); }
  else { Serial.println("[SENSOR2] VL53L0X FAILED"); }
  
  // Initial NTP sync
  syncNTP();
  
  updateDoorStatus();
  updateScraperStatus();
  updateFeederStatus();
  
  Serial.println("\n✅ SYSTEM READY — All systems operational\n");
}

// ==================== MAIN LOOP ====================
void loop() {
  unsigned long now = millis();
  
  // E-Stop check (ISR + redundant polling)
  checkEStopHardware();
  
  // Handle manual switches (skip if E-Stopped)
  handleManualSwitches();
  
  // MQTT connection management
  if (!client.connected()) {
    if (now - lastReconnectAttempt > 5000) {
      lastReconnectAttempt = now;
      reconnectMQTT();
    }
  } else {
    client.loop();
  }
  
  // Check motors independently
  checkDoorLimits();
  checkScraperLimits();
  checkFeederLimits();
  
  // Read VL53L0X sensors (every 100ms)
  if (now - lastSensorRead > 100) {
    int d1 = sensor1.readRangeContinuousMillimeters();
    int d2 = sensor2.readRangeContinuousMillimeters();
    processSensors(d1, d2);
    lastSensorRead = now;
  }
  
  // Check schedules (every minute)
  if (now - lastScheduleCheck > 10000) {
    checkAlarms();
    lastScheduleCheck = now;
  }
  
  // Publish status every 5 seconds
  if (now - lastStatusPublish > 5000) {
    if (client.connected()) {
      publishSystemStatus();
    }
    lastStatusPublish = now;
  }
  
  // Heartbeat every 30 seconds
  if (now - lastHeartbeat > HEARTBEAT_INTERVAL) {
    if (client.connected()) {
      String hb = "{\"fw\":\"" + String(FW_VERSION) + "\",\"lockout\":\"" + lockoutState + "\",\"estop\":" + (emergencyStopped ? "true" : "false") + "}";
      client.publish(MQTT_HEARTBEAT, hb.c_str(), false);
    }
    lastHeartbeat = now;
  }
  
  // Schedule lockout auto-expiry
  if (scheduleActive && now >= scheduleLockoutEnd) {
    if (lockoutState == "SCHEDULE" && !scraperAutoCycling) {
      scheduleActive = false;
      setLockout("NONE");
    }
  }
  
  // Print local status for debugging
  printLocalStatus();
  
  delay(50);
}
