#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <VL53L0X.h>
#include <Wire.h>
#include <WiFiManager.h>

// ==================== PIN DEFINITIONS ====================
// Door Motor (Independent)
#define DOOR_RPWM 4
#define DOOR_LPWM 5
#define DOOR_REN 6
#define DOOR_LEN 7

// Scraper Motor (Independent)
#define SCRAPER_RPWM 15
#define SCRAPER_LPWM 16
#define SCRAPER_REN 40
#define SCRAPER_LEN 39

// Door Limit Switches (NC Mode - HIGH when pressed)
#define D_UP_LS    19
#define D_DOWN_LS  20

// Scraper Limit Switches (NC Mode - HIGH when pressed)
#define S_FRONT_LS 1
#define S_BACK_LS  2

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

#define MQTT_SYSTEM_STATUS   "farm/system/status"
#define MQTT_DOOR_CMD        "farm/door/cmd"
#define MQTT_SCRAPER_CMD     "farm/scraper/cmd"
#define MQTT_MOTOR3_CMD      "farm/motor3/cmd"
#define MQTT_MOTOR4_CMD      "farm/motor4/cmd"
#define MQTT_MOTOR3_STATUS   "farm/motor3/status"
#define MQTT_MOTOR4_STATUS   "farm/motor4/status"
#define MQTT_IN_COUNT        "farm/chickens/in"
#define MQTT_OUT_COUNT       "farm/chickens/out"

// ==================== MOTOR SETTINGS ====================
const int PWM_FREQ = 5000;
const int PWM_RES = 10;
const int DUTY = 800;
const unsigned long maxMotorRunTimeMs = 15000;

// ==================== DOOR STATE ====================
bool doorMoving = false;
bool doorForward = true;
unsigned long doorStartTime = 0;
String doorStatus = "READY";
String doorLimitHit = "NONE";

// ==================== SCRAPER STATE ====================
bool scraperMoving = false;
bool scraperForward = true;
unsigned long scraperStartTime = 0;
String scraperStatus = "READY";
String scraperLimitHit = "NONE";

// ==================== OTHER STATE ====================
String motor3Status = "READY";
String motor4Status = "READY";
unsigned long inCount = 0;
unsigned long outCount = 0;

// VL53L0X sensors
VL53L0X sensor1;
VL53L0X sensor2;

unsigned long lastReconnectAttempt = 0;
unsigned long lastSensorRead = 0;
unsigned long lastStatusPublish = 0;
unsigned long lastButtonPress = 0;
const unsigned long DEBOUNCE_DELAY = 200;

// ==================== LIMIT CHECK FUNCTIONS ====================
bool isDoorUpLimit() { return digitalRead(D_UP_LS) == HIGH; }
bool isDoorDownLimit() { return digitalRead(D_DOWN_LS) == HIGH; }
bool isScraperFrontLimit() { return digitalRead(S_FRONT_LS) == HIGH; }
bool isScraperBackLimit() { return digitalRead(S_BACK_LS) == HIGH; }

// Update door status and limit display
void updateDoorStatus() {
    if (doorMoving) {
        doorStatus = doorForward ? "OPENING" : "CLOSING";
        doorLimitHit = "NONE";
    } 
    else if (isDoorUpLimit()) {
        doorStatus = "LIMIT HIT";
        doorLimitHit = "UP LIMIT";
    }
    else if (isDoorDownLimit()) {
        doorStatus = "LIMIT HIT";
        doorLimitHit = "DOWN LIMIT";
    }
    else {
        doorStatus = "READY";
        doorLimitHit = "NONE";
    }
}

// Update scraper status and limit display
void updateScraperStatus() {
    if (scraperMoving) {
        scraperStatus = scraperForward ? "FORWARD" : "REVERSE";
        scraperLimitHit = "NONE";
    }
    else if (isScraperFrontLimit()) {
        scraperStatus = "LIMIT HIT";
        scraperLimitHit = "FRONT LIMIT";
    }
    else if (isScraperBackLimit()) {
        scraperStatus = "LIMIT HIT";
        scraperLimitHit = "BACK LIMIT";
    }
    else {
        scraperStatus = "READY";
        scraperLimitHit = "NONE";
    }
}

// ==================== MOTOR CONTROL ====================
void startDoor(bool forward) {
    digitalWrite(DOOR_REN, HIGH);
    digitalWrite(DOOR_LEN, HIGH);
    
    if (forward) {
        ledcWrite(DOOR_RPWM, DUTY);
        ledcWrite(DOOR_LPWM, 0);
        Serial.println("→ Door OPENING (moving UP)");
    } else {
        ledcWrite(DOOR_RPWM, 0);
        ledcWrite(DOOR_LPWM, DUTY);
        Serial.println("→ Door CLOSING (moving DOWN)");
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
    Serial.println("→ Door STOPPED");
    doorMoving = false;
    updateDoorStatus();
}

void startScraper(bool forward) {
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
    Serial.println("→ Scraper STOPPED");
    scraperMoving = false;
    updateScraperStatus();
}

// ==================== CHECK LIMITS (Independent) ====================
void checkDoorLimits() {
    if (!doorMoving) return;
    
    bool shouldStop = false;
    
    if (doorForward && isDoorUpLimit()) {
        Serial.println("[DOOR LIMIT] UP limit reached - STOPPING");
        shouldStop = true;
    }
    else if (!doorForward && isDoorDownLimit()) {
        Serial.println("[DOOR LIMIT] DOWN limit reached - STOPPING");
        shouldStop = true;
    }
    else if (millis() - doorStartTime > maxMotorRunTimeMs) {
        Serial.println("[DOOR TIMEOUT] Motor timeout - STOPPING");
        shouldStop = true;
    }
    
    if (shouldStop) {
        stopDoor();
        if (client.connected()) {
            publishSystemStatus();
        }
    }
}

void checkScraperLimits() {
    if (!scraperMoving) return;
    
    bool shouldStop = false;
    
    if (scraperForward && isScraperFrontLimit()) {
        Serial.println("[SCRAPER LIMIT] FRONT limit reached - STOPPING");
        shouldStop = true;
    }
    else if (!scraperForward && isScraperBackLimit()) {
        Serial.println("[SCRAPER LIMIT] BACK limit reached - STOPPING");
        shouldStop = true;
    }
    else if (millis() - scraperStartTime > maxMotorRunTimeMs) {
        Serial.println("[SCRAPER TIMEOUT] Motor timeout - STOPPING");
        shouldStop = true;
    }
    
    if (shouldStop) {
        stopScraper();
        if (client.connected()) {
            publishSystemStatus();
        }
    }
}

// ==================== PUBLISH STATUS TO MQTT ====================
void publishSystemStatus() {
    updateDoorStatus();
    updateScraperStatus();
    
    // Format: "DOOR_READY|UP_LIMIT|SCRAPER_READY|FRONT_LIMIT"
    String status = "DOOR_" + doorStatus + "|" + doorLimitHit + "|SCRAPER_" + scraperStatus + "|" + scraperLimitHit;
    if (client.connected()) {
        client.publish(MQTT_SYSTEM_STATUS, status.c_str(), true);
        Serial.print("📤 Published: ");
        Serial.println(status);
    }
    
    // Publish motor 3 & 4 status
    client.publish(MQTT_MOTOR3_STATUS, motor3Status.c_str(), true);
    client.publish(MQTT_MOTOR4_STATUS, motor4Status.c_str(), true);
}

// ==================== PROCESS SENSORS (Chicken Counting) ====================
void processSensors(int d1, int d2) {
    static unsigned long s1_time = 0, s2_time = 0;
    unsigned long now = millis();
    
    if (d1 >= 8190) d1 = 0;
    if (d2 >= 8190) d2 = 0;
    
    bool s1_act = (d1 > 20 && d1 < 300);
    bool s2_act = (d2 > 20 && d2 < 300);
    
    if (s1_act && s1_time == 0) {
        s1_time = now;
        Serial.printf("[SENSOR] S1 Hit - Distance: %dmm\n", d1);
    }
    
    if (s2_act && s2_time == 0) {
        s2_time = now;
        Serial.printf("[SENSOR] S2 Hit - Distance: %dmm\n", d2);
    }
    
    if (s1_time > 0 && s2_time > 0) {
        if (abs((long)s1_time - (long)s2_time) < 2000) {
            if (s1_time < s2_time) {
                inCount++;
                if (client.connected()) {
                    client.publish(MQTT_IN_COUNT, String(inCount).c_str(), true);
                }
                Serial.printf("[COUNT] IN: %d\n", inCount);
            } else {
                outCount++;
                if (client.connected()) {
                    client.publish(MQTT_OUT_COUNT, String(outCount).c_str(), true);
                }
                Serial.printf("[COUNT] OUT: %d\n", outCount);
            }
        }
        s1_time = 0;
        s2_time = 0;
    }
    
    if (s1_time > 0 && now - s1_time > 3000) s1_time = 0;
    if (s2_time > 0 && now - s2_time > 3000) s2_time = 0;
}

// ==================== HANDLE MANUAL SWITCHES ====================
void handleManualSwitches() {
    unsigned long now = millis();
    if (now - lastButtonPress < DEBOUNCE_DELAY) return;
    
    // Door OPEN button (can only move if NOT at UP limit)
    if (digitalRead(BTN_DOOR_OPEN) == LOW) {
        lastButtonPress = now;
        Serial.println("[BUTTON] Door OPEN pressed");
        
        if (!isDoorUpLimit()) {
            if (doorMoving) stopDoor();
            delay(50);
            startDoor(true);
            if (client.connected()) {
                client.publish(MQTT_DOOR_CMD, "START", true);
                publishSystemStatus();
            }
        } else {
            Serial.println("⚠️ Cannot OPEN - Already at UP limit!");
        }
    }
    
    // Door CLOSE button (can only move if NOT at DOWN limit)
    if (digitalRead(BTN_DOOR_CLOSE) == LOW) {
        lastButtonPress = now;
        Serial.println("[BUTTON] Door CLOSE pressed");
        
        if (!isDoorDownLimit()) {
            if (doorMoving) stopDoor();
            delay(50);
            startDoor(false);
            if (client.connected()) {
                client.publish(MQTT_DOOR_CMD, "REVERSE", true);
                publishSystemStatus();
            }
        } else {
            Serial.println("⚠️ Cannot CLOSE - Already at DOWN limit!");
        }
    }
    
    // Scraper FORWARD button (can only move if NOT at FRONT limit)
    if (digitalRead(BTN_SCRAPER_FWD) == LOW) {
        lastButtonPress = now;
        Serial.println("[BUTTON] Scraper FORWARD pressed");
        
        if (!isScraperFrontLimit()) {
            if (scraperMoving) stopScraper();
            delay(50);
            startScraper(true);
            if (client.connected()) {
                client.publish(MQTT_SCRAPER_CMD, "START", true);
                publishSystemStatus();
            }
        } else {
            Serial.println("⚠️ Cannot move FORWARD - Already at FRONT limit!");
        }
    }
    
    // Scraper REVERSE button (can only move if NOT at BACK limit)
    if (digitalRead(BTN_SCRAPER_REV) == LOW) {
        lastButtonPress = now;
        Serial.println("[BUTTON] Scraper REVERSE pressed");
        
        if (!isScraperBackLimit()) {
            if (scraperMoving) stopScraper();
            delay(50);
            startScraper(false);
            if (client.connected()) {
                client.publish(MQTT_SCRAPER_CMD, "REVERSE", true);
                publishSystemStatus();
            }
        } else {
            Serial.println("⚠️ Cannot move REVERSE - Already at BACK limit!");
        }
    }
}

// ==================== MQTT CALLBACK ====================
void callback(char* topic, byte* payload, unsigned int length) {
    String msg = "";
    for (unsigned int i = 0; i < length; i++) {
        msg += (char)payload[i];
    }
    msg.toUpperCase();
    msg.trim();
    
    Serial.print("📩 Command on ");
    Serial.print(topic);
    Serial.print(": ");
    Serial.println(msg);
    
    // Door commands (Independent)
    if (String(topic) == MQTT_DOOR_CMD) {
        if (msg == "START") {
            if (!isDoorUpLimit()) {
                if (doorMoving) stopDoor();
                delay(50);
                startDoor(true);
                publishSystemStatus();
            } else {
                Serial.println("⚠️ Cannot OPEN - Already at UP limit");
                client.publish(MQTT_SYSTEM_STATUS, "DOOR_AT_UP_LIMIT", true);
            }
        }
        else if (msg == "REVERSE") {
            if (!isDoorDownLimit()) {
                if (doorMoving) stopDoor();
                delay(50);
                startDoor(false);
                publishSystemStatus();
            } else {
                Serial.println("⚠️ Cannot CLOSE - Already at DOWN limit");
                client.publish(MQTT_SYSTEM_STATUS, "DOOR_AT_DOWN_LIMIT", true);
            }
        }
        else if (msg == "STOP") {
            stopDoor();
            publishSystemStatus();
        }
    }
    
    // Scraper commands (Independent)
    else if (String(topic) == MQTT_SCRAPER_CMD) {
        if (msg == "START") {
            if (!isScraperFrontLimit()) {
                if (scraperMoving) stopScraper();
                delay(50);
                startScraper(true);
                publishSystemStatus();
            } else {
                Serial.println("⚠️ Cannot move FORWARD - Already at FRONT limit");
                client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_AT_FRONT_LIMIT", true);
            }
        }
        else if (msg == "REVERSE") {
            if (!isScraperBackLimit()) {
                if (scraperMoving) stopScraper();
                delay(50);
                startScraper(false);
                publishSystemStatus();
            } else {
                Serial.println("⚠️ Cannot move REVERSE - Already at BACK limit");
                client.publish(MQTT_SYSTEM_STATUS, "SCRAPER_AT_BACK_LIMIT", true);
            }
        }
        else if (msg == "STOP") {
            stopScraper();
            publishSystemStatus();
        }
    }
    
    // Motor 3 commands (for ESP8266)
    else if (String(topic) == MQTT_MOTOR3_CMD) {
        if (msg == "START") motor3Status = "RUNNING";
        else if (msg == "REVERSE") motor3Status = "REVERSING";
        else if (msg == "STOP") motor3Status = "STOPPED";
        client.publish(MQTT_MOTOR3_STATUS, motor3Status.c_str(), true);
        Serial.println("→ Motor 3 command forwarded to ESP8266");
    }
    
    // Motor 4 commands (for ESP8266)
    else if (String(topic) == MQTT_MOTOR4_CMD) {
        if (msg == "START") motor4Status = "RUNNING";
        else if (msg == "REVERSE") motor4Status = "REVERSING";
        else if (msg == "STOP") motor4Status = "STOPPED";
        client.publish(MQTT_MOTOR4_STATUS, motor4Status.c_str(), true);
        Serial.println("→ Motor 4 command forwarded to ESP8266");
    }
}

// ==================== MQTT RECONNECT ====================
void reconnectMQTT() {
    Serial.print("Connecting to HiveMQ...");
    if (client.connect("ESP32_Farm_S3", MQTT_USER, MQTT_PASS)) {
        Serial.println(" ✅ Connected!");
        
        client.subscribe(MQTT_DOOR_CMD);
        client.subscribe(MQTT_SCRAPER_CMD);
        client.subscribe(MQTT_MOTOR3_CMD);
        client.subscribe(MQTT_MOTOR4_CMD);
        
        client.publish(MQTT_SYSTEM_STATUS, "ESP32_ONLINE_READY", true);
        client.publish(MQTT_MOTOR3_STATUS, "READY", true);
        client.publish(MQTT_MOTOR4_STATUS, "READY", true);
        publishSystemStatus();
        client.publish(MQTT_IN_COUNT, String(inCount).c_str(), true);
        client.publish(MQTT_OUT_COUNT, String(outCount).c_str(), true);
    } else {
        Serial.print(" ❌ Failed, rc=");
        Serial.println(client.state());
    }
}

// ==================== PRINT LOCAL STATUS ====================
void printLocalStatus() {
    static unsigned long lastPrint = 0;
    if (millis() - lastPrint > 2000) {
        lastPrint = millis();
        
        Serial.println("\n┌─────────────────────────────────────────────────┐");
        Serial.println("│              SYSTEM STATUS                       │");
        Serial.println("├─────────────────────────────────────────────────┤");
        
        // Door status
        Serial.print("│ DOOR:    ");
        if (doorMoving) {
            Serial.print(doorForward ? "OPENING ↑" : "CLOSING ↓");
        } else if (isDoorUpLimit()) {
            Serial.print("⚠️ UP LIMIT HIT");
        } else if (isDoorDownLimit()) {
            Serial.print("⚠️ DOWN LIMIT HIT");
        } else {
            Serial.print("READY      ");
        }
        
        // Show which limit is hit
        if (isDoorUpLimit()) Serial.print(" (CAN ONLY MOVE DOWN)");
        if (isDoorDownLimit()) Serial.print(" (CAN ONLY MOVE UP)");
        Serial.println();
        
        // Scraper status
        Serial.print("│ SCRAPER: ");
        if (scraperMoving) {
            Serial.print(scraperForward ? "FORWARD →" : "REVERSE ←");
        } else if (isScraperFrontLimit()) {
            Serial.print("⚠️ FRONT LIMIT HIT");
        } else if (isScraperBackLimit()) {
            Serial.print("⚠️ BACK LIMIT HIT");
        } else {
            Serial.print("READY      ");
        }
        
        if (isScraperFrontLimit()) Serial.print(" (CAN ONLY MOVE REVERSE)");
        if (isScraperBackLimit()) Serial.print(" (CAN ONLY MOVE FORWARD)");
        Serial.println();
        
        // Counters
        Serial.print("│ COUNTERS: IN=");
        Serial.print(inCount);
        Serial.print("  OUT=");
        Serial.println(outCount);
        
        Serial.println("└─────────────────────────────────────────────────┘");
    }
}

// ==================== SETUP ====================
void setup() {
    Serial.begin(115200);
    delay(1000);
    
    Serial.println("\n╔════════════════════════════════════════╗");
    Serial.println("║      SMART FARM CONTROLLER v5.0       ║");
    Serial.println("║    Independent Door & Scraper         ║");
    Serial.println("║    Limit switches work separately     ║");
    Serial.println("╚════════════════════════════════════════╝\n");
    
    // Configure limit switches
    pinMode(D_UP_LS, INPUT_PULLUP);
    pinMode(D_DOWN_LS, INPUT_PULLUP);
    pinMode(S_FRONT_LS, INPUT_PULLUP);
    pinMode(S_BACK_LS, INPUT_PULLUP);
    
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
    
    digitalWrite(DOOR_REN, LOW);
    digitalWrite(DOOR_LEN, LOW);
    digitalWrite(SCRAPER_REN, LOW);
    digitalWrite(SCRAPER_LEN, LOW);
    
    // Configure PWM
    ledcAttach(DOOR_RPWM, PWM_FREQ, PWM_RES);
    ledcAttach(DOOR_LPWM, PWM_FREQ, PWM_RES);
    ledcAttach(SCRAPER_RPWM, PWM_FREQ, PWM_RES);
    ledcAttach(SCRAPER_LPWM, PWM_FREQ, PWM_RES);
 
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
    
    Serial.print("[WiFi] Connected! IP: ");
    Serial.println(WiFi.localIP());
    
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
    
    sensor1.init();
    sensor2.init();
    sensor1.startContinuous();
    sensor2.startContinuous();
    
    Serial.println("[SENSORS] VL53L0X ready\n");
    
    updateDoorStatus();
    updateScraperStatus();
    
    Serial.println("✅ SYSTEM READY");
    Serial.println("   Door and Scraper work independently");
    Serial.println("   Each motor only stops at its own limits\n");
}

// ==================== MAIN LOOP ====================
void loop() {
    unsigned long now = millis();
    
    // Handle manual switches
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
    checkDoorLimits();    // Only affects door
    checkScraperLimits(); // Only affects scraper
    
    // Read VL53L0X sensors (every 100ms)
    if (now - lastSensorRead > 100) {
        int d1 = sensor1.readRangeContinuousMillimeters();
        int d2 = sensor2.readRangeContinuousMillimeters();
        processSensors(d1, d2);
        lastSensorRead = now;
    }
    
    // Publish status every 5 seconds
    if (now - lastStatusPublish > 5000) {
        if (client.connected()) {
            publishSystemStatus();
        }
        lastStatusPublish = now;
    }
    
    // Print local status for debugging
    printLocalStatus();
    
    delay(50);
}