#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLE2904.h>
#include "Arduino_BMI270_BMM150.h"

// ---------------- Pins ----------------
#define I2C_SDA 8
#define I2C_SCL 9
#define BATT_ADC_PIN 0

// ---------------- BLE UUIDs ----------------
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHARACTERISTIC_UUID "abcd1234-ab12-ab12-ab12-abcdef123456"
#define BATTERY_CHAR_UUID   "00002a19-0000-1000-8000-00805f9b34fb"

// ---------------- Battery tuning ----------------
static constexpr float ADC_REF       = 3.3f;
static constexpr float ADC_MAX       = 4095.0f;
static constexpr float BATT_SCALE    = 2.00f;   // 1:1 jännitejakaja ~2.00
static constexpr float BATT_OFFSET   = 0.00f;   // esim +0.03f
static constexpr float EMA_ALPHA     = 0.15f;   // 0.10..0.20
static constexpr int   BATT_HYST_PCT = 2;       // BLE päivitys jos muutos >=2%

BoschSensorClass imu(Wire);

BLECharacteristic* pVelocityCharacteristic = nullptr;
BLECharacteristic* pBatteryCharacteristic  = nullptr;

bool bleConnected = false;
float velocity = 0.0f;
bool activeMode = false; // true kun BLE connected

const uint32_t ACTIVE_IMU_INTERVAL_MS   = 40;   // 25 Hz
const uint32_t ACTIVE_NOTIFY_MS         = 200;  // 5 Hz
const uint32_t ACTIVE_BATT_MS           = 15000;

const uint32_t IDLE_BATT_MS             = 60000; // 60 s
const uint32_t IDLE_LOOP_DELAY_MS       = 200;   // iso säästö

unsigned long lastImuMs = 0;
unsigned long lastVelNotifyMs = 0;
unsigned long lastBattMs = 0;
unsigned long lastVelMs = 0;
float lastSentVelocity = -999.0f;
const float VEL_EPS = 0.02f;

float battEmaVoltage = 3.9f;
int lastSentBattery = -1;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleConnected = true;
    activeMode = true;
    Serial.println("BLE connected -> ACTIVE MODE");
  }
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    activeMode = false;
    velocity = 0.0f;
    Serial.println("BLE disconnected -> IDLE MODE");
    s->startAdvertising();
  }
};

// ---------- Battery helpers ----------
static float rawToBatteryVoltage(int raw) {
  return (raw / ADC_MAX) * ADC_REF * BATT_SCALE + BATT_OFFSET;
}

// Yksinkertainen Li-ion käyrä (realistisempi kuin suora lineaarinen)
static int voltageToPercent(float v) {
  if (v >= 4.20f) return 100;
  if (v >= 4.10f) return 90 + (int)((v - 4.10f) * 100.0f);
  if (v >= 4.00f) return 80 + (int)((v - 4.00f) * 100.0f);
  if (v >= 3.90f) return 65 + (int)((v - 3.90f) * 150.0f);
  if (v >= 3.80f) return 45 + (int)((v - 3.80f) * 200.0f);
  if (v >= 3.70f) return 30 + (int)((v - 3.70f) * 150.0f);
  if (v >= 3.60f) return 20 + (int)((v - 3.60f) * 100.0f);
  if (v >= 3.50f) return 10 + (int)((v - 3.50f) * 100.0f);
  if (v >= 3.30f) return (int)((v - 3.30f) * 50.0f);
  return 0;
}

uint8_t readBatteryPercent(float* outVoltage = nullptr, int* outRaw = nullptr) {
  // 9 näytettä + mediaani kohinan rauhoittamiseen
  const int N = 9;
  int s[N];
  for (int i = 0; i < N; i++) {
    s[i] = analogRead(BATT_ADC_PIN);
    delay(2);
  }
  for (int i = 0; i < N - 1; i++) {
    for (int j = i + 1; j < N; j++) {
      if (s[j] < s[i]) { int t = s[i]; s[i] = s[j]; s[j] = t; }
    }
  }
  int median = s[N / 2];

  float vNow = rawToBatteryVoltage(median);
  battEmaVoltage = (1.0f - EMA_ALPHA) * battEmaVoltage + EMA_ALPHA * vNow;

  int pct = constrain(voltageToPercent(battEmaVoltage), 0, 100);

  if (outVoltage) *outVoltage = battEmaVoltage;
  if (outRaw) *outRaw = median;
  return (uint8_t)pct;
}

void updateBattery(bool doNotify = true) {
  float voltage = 0.0f;
  int raw = 0;
  int batt = readBatteryPercent(&voltage, &raw);

  bool shouldSend = (lastSentBattery < 0) || (abs(batt - lastSentBattery) >= BATT_HYST_PCT);
  if (shouldSend) {
    uint8_t b = (uint8_t)batt;
    pBatteryCharacteristic->setValue(&b, 1);
    if (doNotify && bleConnected) pBatteryCharacteristic->notify();
    lastSentBattery = batt;
  }

  Serial.print("Battery raw=");
  Serial.print(raw);
  Serial.print(" V=");
  Serial.print(voltage, 3);
  Serial.print(" pct=");
  Serial.print(batt);
  Serial.println("%");
}

void setup() {
  Serial.begin(115200);
  delay(300);

  Wire.begin(I2C_SDA, I2C_SCL);
  analogReadResolution(12);

  if (!imu.begin()) {
    Serial.println("BMI270 ei vastaa! Jatketaan BLE:llä.");
  }

  BLEDevice::init("VBT-Sensor");
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* svc = server->createService(SERVICE_UUID);

  pVelocityCharacteristic = svc->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pVelocityCharacteristic->addDescriptor(new BLE2902());

  pBatteryCharacteristic = svc->createCharacteristic(
    BATTERY_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pBatteryCharacteristic->addDescriptor(new BLE2902());

  BLE2904* p2904 = new BLE2904();
  p2904->setFormat(BLE2904::FORMAT_UINT8);
  p2904->setNamespace(1);
  p2904->setUnit(0x27AD); // percentage
  pBatteryCharacteristic->addDescriptor(p2904);

  uint8_t initBatt = readBatteryPercent();
  pBatteryCharacteristic->setValue(&initBatt, 1);
  lastSentBattery = initBatt;

  svc->start();

  BLEAdvertising* adv = server->getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();

  lastVelMs = millis();
  lastBattMs = millis();
  lastVelNotifyMs = millis();
  lastImuMs = millis();
  activeMode = false; // odotetaan yhteyttä ennen mittausta
  updateBattery(false);

  Serial.println("VBT valmis");
  
}

void loop() {
  const unsigned long now = millis();

  if (!activeMode) {
    // -------- IDLE: minimikulutus --------
    if (now - lastBattMs >= IDLE_BATT_MS) {
      lastBattMs = now;
      updateBattery(false); // ei notifya ilman yhteyttä
    }

    delay(IDLE_LOOP_DELAY_MS);
    return;
  }

  // -------- ACTIVE: yhteys päällä --------

  // IMU + velocity
  if (now - lastImuMs >= ACTIVE_IMU_INTERVAL_MS) {
    lastImuMs = now;

    if (imu.accelerationAvailable()) {
      float ax, ay, az;
      imu.readAcceleration(ax, ay, az);

      float totalAccG = sqrtf(ax * ax + ay * ay + az * az);
      float dynamicAccG = fabsf(totalAccG - 1.0f);

      float dt = (now - lastVelMs) / 1000.0f;
      lastVelMs = now;

      if (dynamicAccG > 0.15f) {
        velocity += (dynamicAccG * 9.81f) * dt;
      } else {
        velocity *= 0.85f;
        if (velocity < 0.03f) velocity = 0.0f;
      }

      velocity = constrain(velocity, 0.0f, 3.0f);
    }
  }

  // Velocity notify harvemmin
  if (bleConnected && (now - lastVelNotifyMs >= ACTIVE_NOTIFY_MS)) {
    lastVelNotifyMs = now; // päivitä aina kun aikaväli täyttyy
    if (fabsf(velocity - lastSentVelocity) >= VEL_EPS) {
    char buf[16];
    dtostrf(velocity, 4, 3, buf);
    pVelocityCharacteristic->setValue(buf);
    pVelocityCharacteristic->notify();
    lastSentVelocity = velocity;
  }
  }

  // Akku ACTIVE-tilassa
  if (now - lastBattMs >= ACTIVE_BATT_MS) {
    lastBattMs = now;
    updateBattery(true);
  }

  delay(5);
}