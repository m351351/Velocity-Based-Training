#ifndef BLE_HANDLER_H
#define BLE_HANDLER_H

#include <Arduino.h>
#include <BLEDevice.h>

void setupBLE();
void sendVelocityNotify(float velocity);

// Nämä rivit ovat kriittisiä: ne mahdollistavat muuttujien jaon tiedostojen välillä
extern bool bleConnected;
extern BLECharacteristic* pBatteryCharacteristic;

#endif