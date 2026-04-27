
#include <ESP8266WiFi.h>
#include <PubSubClient.h>
#include <WiFiManager.h>

// ==================== PIN MAPPING ====================
#define L298_ENA D5
#define L298_IN1 D6
#define L298_IN2 D7

#define LIM_FRONT D1
#define LIM_BACK  D2

// ==================== MQTT CONFIGURATION ====================
// HiveMQ Cloud - REPLACE WITH YOUR CREDENTIALS
const char* MQTT_SERVER = "9ab7d2b2fca840559bb01e402f89a1ad.s1.eu.hivemq.cloud";
const int MQTT_PORT = 8883;
const char* MQTT_USER = "farm_CLI";
const char* MQTT_PASS = "Farm@1234";

#define MQTT_CMD_TOPIC   "farm/motor3/cmd"
#define MQTT_STATUS_TOPIC "farm/motor3/status"

// ==================== GLOBAL OBJECTS ====================
WiFiClientSecure espClient;
PubSubClient client(espClient);

// ==================== SETTINGS ====================
const int MOTOR_SPEED = 1023;
const unsigned long maxMotorRunTimeMs = 15000;

// ==================== STATE VARIABLES ====================
bool motorActive = false;
bool motorForward = true;
unsigned long motorStartTime = 0;
String motorStatus = "READY";
String limitHit = "NONE";
unsigned long lastReconnectAttempt = 0;

// ==================== FUNCTIONS ====================
bool isFrontLimitTriggered() { return digitalRead(LIM_FRONT) == HIGH; }
bool isBackLimitTriggered()  { return digitalRead(LIM_BACK) == HIGH; }

void startMotor(bool forward) {
    if (forward) {
        digitalWrite(L298_IN1, HIGH);
        digitalWrite(L298_IN2, LOW);
        motorStatus = "RUNNING";
        Serial.println("→ Motor moving FORWARD");
    } else {
        digitalWrite(L298_IN1, LOW);
        digitalWrite(L298_IN2, HIGH);
        motorStatus = "REVERSING";
        Serial.println("→ Motor moving REVERSE");
    }
    analogWrite(L298_ENA, MOTOR_SPEED);
    motorActive = true;
    motorForward = forward;
    motorStartTime = millis();
}

void stopMotor(String reason) {
    digitalWrite(L298_IN1, LOW);
    digitalWrite(L298_IN2, LOW);
    analogWrite(L298_ENA, 0);
    motorActive = false;
    motorStatus = "STOPPED";
    Serial.print("→ Motor STOPPED: ");
    Serial.println(reason);
}

void updateAndPublishStatus() {
    if (isFrontLimitTriggered()) {
        limitHit = "FRONT LIMIT";
        if (!motorActive) motorStatus = "LIMIT HIT";
    } 
    else if (isBackLimitTriggered()) {
        limitHit = "BACK LIMIT";
        if (!motorActive) motorStatus = "LIMIT HIT";
    } 
    else {
        limitHit = "NONE";
        if (!motorActive && motorStatus != "RUNNING" && motorStatus != "REVERSING") {
            motorStatus = "READY";
        }
    }
    
    String statusMessage = "MOTOR3_" + motorStatus + "|" + limitHit;
    
    if (client.connected()) {
        client.publish(MQTT_STATUS_TOPIC, statusMessage.c_str(), true);
        Serial.print("📤 Published: ");
        Serial.println(statusMessage);
    }
}

void checkSafety() {
    if (!motorActive) return;
    
    if (motorForward && isFrontLimitTriggered()) {
        stopMotor("FRONT_LIMIT_HIT");
        motorStatus = "LIMIT HIT";
        limitHit = "FRONT LIMIT";
        updateAndPublishStatus();
    }
    else if (!motorForward && isBackLimitTriggered()) {
        stopMotor("BACK_LIMIT_HIT");
        motorStatus = "LIMIT HIT";
        limitHit = "BACK LIMIT";
        updateAndPublishStatus();
    }
    else if (millis() - motorStartTime > maxMotorRunTimeMs) {
        stopMotor("TIMEOUT");
        motorStatus = "TIMEOUT";
        limitHit = "NONE";
        updateAndPublishStatus();
    }
}

void callback(char* topic, byte* payload, unsigned int length) {
    String msg = "";
    for (unsigned int i = 0; i < length; i++) {
        msg += (char)payload[i];
    }
    msg.toUpperCase();
    msg.trim();
    
    Serial.print("📩 Command: ");
    Serial.println(msg);
    
    if (String(topic) == MQTT_CMD_TOPIC) {
        if (msg == "START") {
            if (!isFrontLimitTriggered()) {
                if (motorActive) stopMotor("NEW_COMMAND");
                delay(50);
                startMotor(true);
                updateAndPublishStatus();
            } else {
                Serial.println("⚠️ Already at FRONT limit");
                if (client.connected()) {
                    client.publish(MQTT_STATUS_TOPIC, "MOTOR3_LIMIT HIT|FRONT LIMIT", true);
                }
            }
        }
        else if (msg == "REVERSE") {
            if (!isBackLimitTriggered()) {
                if (motorActive) stopMotor("NEW_COMMAND");
                delay(50);
                startMotor(false);
                updateAndPublishStatus();
            } else {
                Serial.println("⚠️ Already at BACK limit");
                if (client.connected()) {
                    client.publish(MQTT_STATUS_TOPIC, "MOTOR3_LIMIT HIT|BACK LIMIT", true);
                }
            }
        }
        else if (msg == "STOP") {
            stopMotor("BY_USER");
            updateAndPublishStatus();
        }
    }
}

void reconnectMQTT() {
    if (millis() - lastReconnectAttempt < 5000) return;
    lastReconnectAttempt = millis();
    
    Serial.print("Connecting to HiveMQ...");
    if (client.connect("ESP8266_Motor3", MQTT_USER, MQTT_PASS)) {
        Serial.println(" ✅ Connected!");
        client.subscribe(MQTT_CMD_TOPIC);
        updateAndPublishStatus();
    } else {
        Serial.print(" ❌ Failed, rc=");
        Serial.println(client.state());
    }
}

void printLocalStatus() {
    static unsigned long lastPrint = 0;
    if (millis() - lastPrint > 3000) {
        lastPrint = millis();
        
        Serial.print("📊 Motor 3 | ");
        if (motorActive) {
            Serial.print(motorForward ? "FORWARD →" : "REVERSE ←");
        } else {
            Serial.print("STOPPED   ");
        }
        
        Serial.print(" | Limits: ");
        Serial.print(isFrontLimitTriggered() ? "FRONT✓ " : "FRONT_ ");
        Serial.print(isBackLimitTriggered() ? "BACK✓" : "BACK_");
        
        Serial.print(" | State: ");
        Serial.print(motorStatus);
        Serial.print(" | Limit: ");
        Serial.println(limitHit);
    }
}

// ==================== SETUP ====================
void setup() {
    Serial.begin(115200);
    delay(1000);
    
    Serial.println("\n╔════════════════════════════════════╗");
    Serial.println("║      MOTOR 3 CONTROLLER v1.0       ║");
    Serial.println("╚════════════════════════════════════╝\n");
    
    pinMode(L298_ENA, OUTPUT);
    pinMode(L298_IN1, OUTPUT);
    pinMode(L298_IN2, OUTPUT);
    pinMode(LIM_FRONT, INPUT_PULLUP);
    pinMode(LIM_BACK, INPUT_PULLUP);
    
    digitalWrite(L298_IN1, LOW);
    digitalWrite(L298_IN2, LOW);
    analogWrite(L298_ENA, 0);
    
    WiFiManager wm;
    wm.setDarkMode(true);
    wm.setConfigPortalTimeout(180);
    wm.setTitle("Motor 3 Setup");
    
    Serial.println("[WiFi] Connecting...");
    if (!wm.autoConnect("Motor3_Setup")) {
        Serial.println("[WiFi] Failed, restarting...");
        delay(3000);
        ESP.restart();
    }
    
    Serial.print("[WiFi] Connected! IP: ");
    Serial.println(WiFi.localIP());
    
    espClient.setInsecure();
    client.setServer(MQTT_SERVER, MQTT_PORT);
    client.setCallback(callback);
    client.setKeepAlive(240);
    
    Serial.println("✅ SYSTEM READY\n");
}

// ==================== LOOP ====================
void loop() {
    if (!client.connected()) {
        reconnectMQTT();
    } else {
        client.loop();
    }
    
    checkSafety();
    
    static unsigned long lastStatusPublish = 0;
    if (millis() - lastStatusPublish > 5000) {
        if (client.connected()) {
            updateAndPublishStatus();
        }
        lastStatusPublish = millis();
    }
    
    printLocalStatus();
    delay(50);
}