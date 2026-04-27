#ifndef BLE_HANDLER_H
#define BLE_HANDLER_H
#include <esp32-hal-cpu.h>
#include <Arduino.h>
#include <BLEDevice.h>

void setupBLE();
void sendVelocityNotify(float velocity);

// UUSI FUNKTIO: Lähettää tarkan Peak- ja Mean-nopeuden toiston päätteeksi
void sendRepResults(float peak, float mean);

// Nämä rivit ovat kriittisiä: ne mahdollistavat muuttujien jaon tiedostojen välillä
extern bool bleConnected;
extern BLECharacteristic* pBatteryCharacteristic;

#endif