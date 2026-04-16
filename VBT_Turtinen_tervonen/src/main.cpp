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
// Kalibroi tarvittaessa yleismittarilla
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
unsigned long lastVelMs = 0;
unsigned long lastBattMs = 0;

float battEmaVoltage = 3.9f;
int lastSentBattery = -1;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleConnected = true;
    Serial.println("BLE connected");
  }
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    Serial.println("BLE disconnected");
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
  updateBattery(false);

  Serial.println("VBT valmis");
}

void loop() {
  // Velocity
  if (imu.accelerationAvailable()) {
    float ax, ay, az;
    imu.readAcceleration(ax, ay, az);

    float totalAcc = sqrtf(ax * ax + ay * ay + az * az) * 9.81f;
    float dynamicAcc = fabsf(totalAcc - 9.81f);

    unsigned long now = millis();
    float dt = (now - lastVelMs) / 1000.0f;
    lastVelMs = now;

    if (dynamicAcc > 1.5f) velocity += dynamicAcc * dt;
    else {
      velocity *= 0.8f;
      if (velocity < 0.05f) velocity = 0.0f;
    }
    velocity = constrain(velocity, 0.0f, 3.0f);

    if (bleConnected) {
      char buf[16];
      dtostrf(velocity, 4, 3, buf);
      pVelocityCharacteristic->setValue(buf);
      pVelocityCharacteristic->notify();
    }
  }

  // Battery @ 5 s
  if (millis() - lastBattMs >= 5000) {
    lastBattMs = millis();
    updateBattery(true);
  }

  delay(40);
}