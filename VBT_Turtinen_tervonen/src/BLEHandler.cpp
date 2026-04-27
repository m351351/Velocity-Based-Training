#include "BLEHandler.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLE2904.h>
#include "Exercise.h"
#include "OTA.h"

// BLE UUIDs 
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc" // Pääpalvelu
#define CHARACTERISTIC_UUID "abcd1234-ab12-ab12-ab12-abcdef123456" // Live-nopeuskäyrä
#define BATTERY_CHAR_UUID   "00002a19-0000-1000-8000-00805f9b34fb" // Akku
#define EXERCISE_SELECT_UUID "12345678-1234-1234-1234-123456789def" // Liikevalinta
#define REP_RESULTS_UUID    "12345678-1234-1234-1234-123456789fff" // Toiston tarkat tulokset

// Globaalit osoittimet
BLECharacteristic* pVelocityCharacteristic = nullptr;
BLECharacteristic* pBatteryCharacteristic  = nullptr;
BLECharacteristic* pExerciseCharacteristic = nullptr;
BLECharacteristic* pRepResultsCharacteristic = nullptr; // Uusi muuttuja

// Liikevalinta
ExerciseType currentExercise = CLEAN;

// BLE-yhteyden tilamuuttuja
bool bleConnected = false;

// Ajoitusmuuttuja nopeusilmoituksille
unsigned long lastVelNotifyMs = 0;
const uint32_t VEL_NOTIFY_INTERVAL_MS = 20; // 50 Hz

// Tätä kutsutaan kun puhelin kirjoittaa liikevalinta-kenttään
class ExerciseCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pChar) override {
        uint8_t* value = pChar->getData();
        if (pChar->getLength() > 0) {
            currentExercise = (ExerciseType)value[0];
            Serial.print("Liike vaihdettu ID:ksi: ");
            Serial.println(value[0]);
        }
    }
};

// BLE-palvelimen callbackit
class ServerCallbacks : public BLEServerCallbacks {
  // Puhelin yhdistetty -> Aktiivitila
  void onConnect(BLEServer*) override {
    bleConnected = true;
    setCpuFrequencyMhz(160); //  Palautetaan prosssorin tehot mittausta varten
    Serial.println("BLE Yhdistetty -> Aktiivitila");
  }

  // Puhelin katkaissut yhteyden -> Lepotila (IDLE)
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    Serial.println("BLE disconnected -> IDLE MODE");
    // Tiputetaan prosessorin tehot puoleen ja hidastetaan BLE
    setCpuFrequencyMhz(80);
    // Hidastetaan mainostusväli IDLE-tilassa n. 1280 ms
    BLEAdvertising* adv = s->getAdvertising();
    adv->setMinInterval(0x800);
    adv->setMaxInterval(0x800);
    adv->start();
  }
};

// BLE palvelun logiikka
void setupBLE() {
  BLEDevice::init("VBT-Sensor"); // <- Laitteen nimi BLE-verkossa
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  // TÄMÄ POIS NYT TOISTAISEKSI EI VIELÄ KÄYTÖSSÄ
  //setupOTA(server);

  BLEService* svc = server->createService(SERVICE_UUID);

  // LIVE NOPEUSKÄYRÄ: Lähettää nopeuden puhelimeen reaaliajassa
  pVelocityCharacteristic = svc->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pVelocityCharacteristic->addDescriptor(new BLE2902());

  // AKKU: Lähettää akun varaustason puhelimeen
  pBatteryCharacteristic = svc->createCharacteristic(
    BATTERY_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pBatteryCharacteristic->addDescriptor(new BLE2902());

  // LIIKEVALINTA: Puhelin kirjoittaa valitun liikkeen ID:n
  pExerciseCharacteristic = svc->createCharacteristic(
    EXERCISE_SELECT_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ
  );
  pExerciseCharacteristic->setCallbacks(new ExerciseCallbacks());

  // TOISTON TULOKSET (Peak & Mean)
  pRepResultsCharacteristic = svc->createCharacteristic(
    REP_RESULTS_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pRepResultsCharacteristic->addDescriptor(new BLE2902());

  // Akun kuvaus
  BLE2904* p2904 = new BLE2904();
  p2904->setFormat(BLE2904::FORMAT_UINT8);
  p2904->setNamespace(1);
  p2904->setUnit(0x27AD); // Yksikkö = Prosentti (0-100)
  pBatteryCharacteristic->addDescriptor(p2904);

  svc->start();

  // Käynnistetään mainostus
  BLEAdvertising* adv = server->getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();

  Serial.println("VBT valmis");
}

static float lastSentVel = -1.0f; // Muistetaan edellinen arvo turhan lähetyksen estämiseksi

// Lähetetään nopeusilmoitus puhelimeen
void sendVelocityNotify(float velocity) {
  unsigned long now = millis();
  // Tarkistetaan yhteys ja aikaraja ennen lähetystä
  if (bleConnected && (now - lastVelNotifyMs >= VEL_NOTIFY_INTERVAL_MS)) {
    lastVelNotifyMs += VEL_NOTIFY_INTERVAL_MS;

    if (!pVelocityCharacteristic) return;

if (velocity > 0.01f || lastSentVel > 0.01f) {
      
      pVelocityCharacteristic->setValue((uint8_t*)&velocity, sizeof(float));
      pVelocityCharacteristic->notify();
      
      lastSentVel = velocity;
    }
  }
}

// Lähettää valmiin toiston tarkan Peak- ja Mean-nopeuden puhelimelle
void sendRepResults(float peak, float mean) {
    if (bleConnected && pRepResultsCharacteristic) {
        char buf[32];
        // Pakataan data muotoon "peak,mean" esim. "1.25,0.85"
        snprintf(buf, sizeof(buf), "%.2f,%.2f", peak, mean);
        pRepResultsCharacteristic->setValue(buf);
        pRepResultsCharacteristic->notify();
        Serial.printf("Lähetetty toiston tulos puhelimeen: %s\n", buf);
    }
}