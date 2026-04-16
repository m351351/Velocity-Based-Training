#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "Arduino_BMI270_BMM150.h" // Käytetään tätä, koska se toimi!

#define I2C_SDA 8
#define I2C_SCL 9

#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHARACTERISTIC_UUID "abcd1234-ab12-ab12-ab12-abcdef123456"

// Standardi BLE Battery Level characteristic UUID
#define BATTERY_CHAR_UUID   "00002a19-0000-1000-8000-00805f9b34fb"

// HUOM: tämä pitää olla oikea analoginen pinni juuri sun boardille.
// Jos GPIO0 ei anna arvoa, vaihda pinniin joka tukee ADC:tä.
#define BATT_ADC_PIN 0

BLECharacteristic* pBatteryCharacteristic = nullptr;

BoschSensorClass imu(Wire);
BLECharacteristic* pCharacteristic = nullptr;
bool bleConnected = false;

float velocity = 0.0;
unsigned long lastTime = 0;
bool isLifting = false;

// Akun päivitysajastin (ettei spamata BLE:tä joka kierroksella)
unsigned long lastBatteryUpdateMs = 0;

// ---------------------------------------------------------
// BLE callbackit
// ---------------------------------------------------------
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    bleConnected = true;
  }

  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    s->startAdvertising();
  }
};

// ---------------------------------------------------------
// Akun lukeminen + BLE-päivitys
// ---------------------------------------------------------
void updateBattery() {
  // Luetaan raakadata ADC:ltä
  int raw = analogRead(BATT_ADC_PIN);

  // Muunna jännitteeksi:
  // - 4095 = 12-bit ADC täysi asteikko (ESP32)
  // - *3.3 = ADC referenssijännite
  // - *2.0 = jännitejakajan kerroin (olettaen 1:1 jakaja)
  float voltage = (raw / 4095.0f) * 3.3f * 2.0f;

  // Muunnetaan prosentiksi:
  // 3.30V -> 0%
  // 4.20V -> 100%
  int percentage = (int)((voltage - 3.30f) * 100.0f / (4.20f - 3.30f));
  percentage = constrain(percentage, 0, 100);

  // Battery Level characteristic pitää lähettää 1 byte (uint8)
  uint8_t batt = (uint8_t)percentage;
  pBatteryCharacteristic->setValue(&batt, 1);

  if (bleConnected) {
    pBatteryCharacteristic->notify();
  }

  // Debug monitoriin
  Serial.print("Battery raw: ");
  Serial.print(raw);
  Serial.print(" voltage: ");
  Serial.print(voltage, 3);
  Serial.print(" V  -> ");
  Serial.print(percentage);
  Serial.println("%");
}

void setup() {
  Serial.begin(115200);
  // Jos serial ei näy heti, tämä auttaa:
  // delay(2000);

  Wire.begin(I2C_SDA, I2C_SCL);

  if (!imu.begin()) {
    Serial.println("BMI270 ei vastaa!");
    // Ei jäädä while(1):een, jotta BLE voi silti nousta testiä varten
  }

  BLEDevice::init("VBT-Sensor");
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  // Velocity-char (sun nykyinen data)
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());

  // Battery-char (0..100 %, standard UUID)
  pBatteryCharacteristic = pService->createCharacteristic(
    BATTERY_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pBatteryCharacteristic->addDescriptor(new BLE2902());

  pService->start();
  pServer->getAdvertising()->start();

  // Alustus aikamuuttujille
  lastTime = millis();
  lastBatteryUpdateMs = millis();

  // Ensimmäinen akun päivitys heti käynnistyksessä
  updateBattery();

  Serial.println("VBT Valmis!");
}

void loop() {
  if (!imu.accelerationAvailable()) return;

  float ax, ay, az;
  imu.readAcceleration(ax, ay, az);

  // Kiihtyvyyden laskenta
  float totalAcc = sqrt(ax * ax + ay * ay + az * az) * 9.81f;
  float dynamicAcc = fabs(totalAcc - 9.81f);

  unsigned long now = millis();
  float dt = (now - lastTime) / 1000.0f;
  lastTime = now;

  // Yksinkertainen integrointi
  if (dynamicAcc > 1.5f) { // jos kiihtyvyys yli 1.5 m/s^2
    isLifting = true;
    velocity += dynamicAcc * dt;
  } else {
    isLifting = false;
    velocity *= 0.8f; // vaimennus kun liike loppuu
    if (velocity < 0.05f) velocity = 0.0f;
  }

  // Rajataan järkevästi (suoja)
  velocity = constrain(velocity, 0.0f, 3.0f);

  // Lähetä velocity Flutterille (pelkkä numero tekstinä)
  if (bleConnected) {
    char buf[16];
    dtostrf(velocity, 4, 3, buf);
    pCharacteristic->setValue(buf);
    pCharacteristic->notify();
  }

  // Päivitä akku esim. 2 sek välein
  if (millis() - lastBatteryUpdateMs >= 2000) {
    lastBatteryUpdateMs = millis();
    updateBattery();
  }

  // Monitorointi
  Serial.print("Acc: ");
  Serial.print(dynamicAcc);
  Serial.print(" Vel: ");
  Serial.println(velocity);

  delay(40);
}