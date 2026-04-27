#ifndef OTA_H
#define OTA_H

#include <Arduino.h>
#include <BLEServer.h>

void setupOTA(BLEServer* pServer);
void handleOTA();

// UUID:t OTA-palvelulle ja ominaisuuksille
#define OTA_SERVICE_UUID "8a05c742-df27-4632-a5ab-25ec3039d1b6"
#define OTA_CONTROL_UUID "8a05c743-df27-4632-a5ab-25ec3039d1b6"
#define OTA_DATA_UUID    "8a05c744-df27-4632-a5ab-25ec3039d1b6"

#endif