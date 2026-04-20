#include "BLEHandler.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLE2904.h>
#include "BLEHandler.h"

// ---------------- BLE UUIDs ----------------
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHARACTERISTIC_UUID "abcd1234-ab12-ab12-ab12-abcdef123456"
#define BATTERY_CHAR_UUID   "00002a19-0000-1000-8000-00805f9b34fb"

BLECharacteristic* pVelocityCharacteristic = nullptr;
BLECharacteristic* pBatteryCharacteristic  = nullptr;

bool bleConnected = false;

unsigned long lastVelNotifyMs = 0;
const uint32_t VEL_NOTIFY_INTERVAL_MS = 80; // max 12.5 Hz

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

void setupBLE() {
    
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

  svc->start();

  BLEAdvertising* adv = server->getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();

    Serial.println("VBT valmis");
}


void sendVelocityNotify(float velocity) {
    unsigned long now = millis();
  // BLE velocity notify @ 12.5 Hz
  if (bleConnected && (now - lastVelNotifyMs >= VEL_NOTIFY_INTERVAL_MS)) {
    
    lastVelNotifyMs = now;
    char buf[16];
    dtostrf(velocity, 4, 3, buf);
    pVelocityCharacteristic->setValue(buf);
    pVelocityCharacteristic->notify();
  }
}