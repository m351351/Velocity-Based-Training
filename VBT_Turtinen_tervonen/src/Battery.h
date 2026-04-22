#ifndef BATTERY_H
#define BATTERY_H

#include <Arduino.h>

uint8_t readBatteryPercent(float* outVoltage = nullptr, int* outRaw = nullptr);
void updateBattery(bool doNotify);
void handleBattery();

#endif