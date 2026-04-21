#include "Battery.h"
#include <BLEDevice.h>

#define BATT_ADC_PIN 0      // ADC-pinni

// Viittaukset main.cpp-tiedostossa oleviin globaaleihin muuttujiin
extern BLECharacteristic* pBatteryCharacteristic;
extern bool bleConnected;


static constexpr float ADC_REF       = 3.3f;
static constexpr float ADC_MAX       = 4095.0f;
static constexpr float BATT_SCALE    = 2.00f;   // Jännitteenjakajan kerroin
static constexpr float BATT_OFFSET   = 0.00f;   // Mahdollinen hienosäätö
static constexpr float EMA_ALPHA     = 0.15f;   // Suodattimen voimakkuus
static constexpr int   BATT_HYST_PCT = 2;       // Päivityskynnys (prosenttia)
static constexpr float BATT_MAX_V = 4.20f;
static constexpr float BATT_MIN_V = 3.30f;  

// Moduulin sisäiset muuttujat (eivät näy mainiin ilman externiä)
static float battEmaVoltage = 3.9f;
int lastSentBattery = -1;
static unsigned long lastBattMs = 0;


static float rawToBatteryVoltage(int raw) {
    return (raw / ADC_MAX) * ADC_REF * BATT_SCALE + BATT_OFFSET;
}


static int voltageToPercent(float v) {
  if (v >= BATT_MAX_V) return 100;
  if (v <= BATT_MIN_V) return 0;
  return (int)((v - BATT_MIN_V) / (BATT_MAX_V - BATT_MIN_V) * 100.0f);
}




uint8_t readBatteryPercent(float* outVoltage, int* outRaw) {
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
    // C) Null-check: Jos pointteri on tyhjä, poistutaan heti
    if (!pBatteryCharacteristic) return; 

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



void handleBattery(){
    unsigned long now = millis();
     // Battery @ 10 s
     if (now - lastBattMs >= 10000) {
    lastBattMs = now;
    updateBattery(true);
  }
}

