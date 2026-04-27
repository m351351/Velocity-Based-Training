#include "Battery.h"
#include <BLEDevice.h>
#include "Motion.h"

#define BATT_ADC_PIN 0      // ADC-pinni

// Viittaukset main.cpp-tiedostossa oleviin globaaleihin muuttujiin
extern BLECharacteristic* pBatteryCharacteristic;
extern bool bleConnected;

// LASKENTAVAKIOT JA PARAMETRIT
static constexpr float ADC_REF       = 3.3f;  //ESP32:n ADC referenssijännite
static constexpr float ADC_MAX       = 4095.0f;   // 12-bittinen ADC = 4095 maksimiarvo
static constexpr float BATT_SCALE    = 2.00f;   // Jännitteenjakajan kerroin (Jännite puolitetaan ennen mittausta, joten kerrotaan takaisin 2:lla)
static constexpr float BATT_OFFSET   = 0.00f;   // Mahdollinen hienosäätö
// EMA-SUODATIN = Exponential Moving Average = eksponentiaalinen liukuva keskiarvo
static constexpr float EMA_ALPHA     = 0.15f;   // Suodattimen voimakkuus
static constexpr int   BATT_HYST_PCT = 2;       // Päivityskynnys (prosenttia)
static constexpr float BATT_MAX_V = 4.20f; // Täyteen ladatun akun jännite
static constexpr float BATT_MIN_V = 3.30f;  // Tyhjän akun jännite (turvallinen raja 3.3V)

// Moduulin sisäiset muuttujat (eivät näy mainiin ilman externiä)
static float battEmaVoltage = 3.9f;   // EMA-suodattimen nykyinen arvo, alustettu keskimääräisellä jännitteellä
int lastSentBattery = -1;   // Viimeisin lähetetty prosenttilukema
static unsigned long lastBattMs = 0; // Akun päivitysajastin

// ADC-raakadata -> Jännite volteissa
static float rawToBatteryVoltage(int raw) {
    return (raw / ADC_MAX) * ADC_REF * BATT_SCALE + BATT_OFFSET;
}

// Jännite -> Prosentti
static int voltageToPercent(float v) {
    // Epälineaarinen mappaus: useimmat LiPo-akut ovat 50% kohdalla n. 3.7V - 3.8V välissä
    if (v >= 4.15f) return 100; // Täysi akku
    if (v <= 3.30f) return 0; // Tyhjä akku
    
    if (v > 3.80f) {
        // Alue 4.15V - 3.80V (n. 80% kapasiteetista on tässä välissä)
        return 50 + (int)((v - 3.80f) / (4.15f - 3.80f) * 50.0f);
    } else {
        // Alue 3.80V - 3.30V (viimeiset 20-50% putoavat jyrkemmin)
        return (int)((v - 3.30f) / (3.80f - 3.30f) * 50.0f);
    }
}


// PÄÄFUNKTIO - Mittaa ja palauttaa prosentin
uint8_t readBatteryPercent(float* outVoltage, int* outRaw) {
  // Luetaan 9 näytettä ja otetaan mediaani kohinan vähentämiseksi
  const int N = 9;
  int s[N];
  for (int i = 0; i < N; i++) {
    s[i] = analogRead(BATT_ADC_PIN);
    delayMicroseconds(200); // Pieni viive näytteiden väliin
  }
  
  // Lajitellaan taulukko mediaania varten
  for (int i = 0; i < N - 1; i++) {
    for (int j = i + 1; j < N; j++) {
      if (s[j] < s[i]) { 
        int t = s[i]; 
        s[i] = s[j]; 
        s[j] = t; 
      }
    }
  }
  int median = s[N / 2];

  float vNow = rawToBatteryVoltage(median);

  // EMA-SUODATUS: ensimmäisellä mittauksella asetetaan suodattimen arvo suoraan = vältetään hidas reagointi alussa
  static bool isFirstRead = true;
  if (isFirstRead) {
    battEmaVoltage = vNow;
    isFirstRead = false;
  } else {
    // Tavallinen EMA-suodatus
    battEmaVoltage = (1.0f - EMA_ALPHA) * battEmaVoltage + EMA_ALPHA * vNow;
  }

  // Muunnetaan suodatettu jännite prosenteiksi (raja-arvot tässä)
  int pct = constrain(voltageToPercent(battEmaVoltage), 0, 100);

  if (outVoltage) *outVoltage = battEmaVoltage;
  if (outRaw) *outRaw = median;
  
  return (uint8_t)pct;
}


// Mittaa akun tilan ja lähettää BLE-ilmoituksen
void updateBattery(bool doNotify = true) {
  float voltage = 0.0f;
  int raw = 0;
  int batt = readBatteryPercent(&voltage, &raw);
  // LÄHETETÄÄN VAIN JOS PROSENTTI ON MUUTTUNUT TARPEEKSI
  bool shouldSend = (lastSentBattery < 0) || (abs(batt - lastSentBattery) >= BATT_HYST_PCT);

  if (shouldSend) {
    // Jos pointteri on tyhjä, ei yritetä lähettää
    if (!pBatteryCharacteristic) return; 

    uint8_t b = (uint8_t)batt;
    pBatteryCharacteristic->setValue(&b, 1);
    if (doNotify && bleConnected) pBatteryCharacteristic->notify();

    lastSentBattery = batt; // Päivitetään viimeisin lähetetty arvo
  }
  /* DEBUG TULOSTUSTA KEHITYSTÄ VARTEN: OTA KÄYTTÖÖN TÄMÄ POIS TARVITTAESSA
  Serial.print("Battery raw=");
  Serial.print(raw);
  Serial.print(" V=");
  Serial.print(voltage, 3);
  Serial.print(" pct=");
  Serial.print(batt);
  Serial.println("%"); */
}


void handleBattery(){
  // EI LUETA AKKUA JOS LIIKE KESKEN
  if (inRep) return;
  
    unsigned long now = millis();
     // Tarkistetaaan akku 10 sekunnin välein
     if (now - lastBattMs >= 10000) {
    lastBattMs = now;
    updateBattery(true);
  }
}