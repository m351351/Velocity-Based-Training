/*
Laitteisto: ESP32-C3 SuperMini + BMI270 IMU + MCP1700 LDO + TP4056 latauspiiri
Kirjastot:  NimBLE-Arduino, Arduino_BMI270_BMM150

Koodi käytännössä:
1. ESP mainostaa itseään bluetoothilla -> odottaa puhelimen yhdistämistä. 
2. Flutter-sovellus yhdistää BLE -> activeMode päällä -> mittaus alkaa.
3. BMI270 lukee kiihtyvyyttä -> integroidaan nopeudeksi.
4. Nopeus lähetetään BLE-notifyna n. 3x sekunnissa käyttöliittymään.
5. Akun jännite mitataan ADC (GPIO0) ja lähetetään erikseen käytttöliittymään.
 */

#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <NimBLE-Arduino.h>
#include "Arduino_BMI270_BMM150.h"

/* Pinnit ja BLE-tunnisteet */

#define I2C_SDA      8    // SDA 
#define I2C_SCL      9    // SCL
#define BATT_ADC_PIN 0    // ADC-pinni -> jännitteenjakaja -> akku

// UUID täsmättävä Flutter koodin kanssa (MUUTA MOLEMPIA YHDESSÄ!!)
#define SERVICE_UUID      "12345678-1234-1234-1234-123456789abc"
#define VELOCITY_CHAR_UUID "abcd1234-ab12-ab12-ab12-abcdef123456"
#define BATTERY_CHAR_UUID  "00002a19-0000-1000-8000-00805f9b34fb" // Standardi BLE UUID akullle

/* Vakiot */

// Akku -> ADC-mittaus -> prosentit BLE:lle 
// Kerrotaan kahdella takaisin todelliseen jännitteeseen
static constexpr float ADC_REF    = 3.3f;    // ESP32 ADC-referenssi (volttia)
static constexpr float ADC_MAX    = 4095.0f; // 12-bitin maksimi
static constexpr float BATT_SCALE = 2.0f;    // Jännitteenjakajan kerroin (1/(R2/(R1+R2)))
static constexpr float EMA_ALPHA  = 0.15f;   // EMA-suodatin akkujännitteen mittaukseen

// Akun jännitealue (TP4056 lataa 4.2V asti, MCP1700 vaatii n. 2.7V minimi)
static constexpr float BATT_MAX_V = 4.20f;
static constexpr float BATT_MIN_V = 3.30f;   // Turvallinen alaraja ennen sammutusta

// Ajastimet
static constexpr uint32_t IMU_INTERVAL_MS  = 10;    // 1000ms/10 = 100Hz IMU-luku
static constexpr uint32_t BLE_INTERVAL_MS  = 300;   // 1000ms/300 = 3.3Hz BLE-lähetys
static constexpr uint32_t BATT_ACTIVE_MS   = 15000; // Luetaan 15s välein aktiivitilassa
static constexpr uint32_t BATT_IDLE_MS     = 60000; // Luetaan 60s välein lepotilassa

// Nopeuden laskenta
static constexpr float ACCEL_THRESHOLD_G = 0.15f; // Alle tämän kiihtyvyys -> lepo (suodattaa tärinää)
static constexpr float VELOCITY_DECAY    = 0.85f;  // Vaimentaa lepotilassa nopeutta 15% IMU-lukujen välillä
static constexpr float VELOCITY_MIN      = 0.03f;  // Alle tämän -> nollataan estämään driftiä
static constexpr float VELOCITY_MAX      = 3.0f;   // Maksimi m/s (raja ihan varmuuden vuoksi)


/* Globaalit muuttujat */

BoschSensorClass imu(Wire);               // BMI270-anturiolio kirjastosta
NimBLECharacteristic* pVelChar  = nullptr; // BLE velocity characteristic
NimBLECharacteristic* pBattChar = nullptr; // BLE battery characteristic

bool bleConnected = false; // Puhelin yhdistetty?
bool activeMode   = false; // Mittaus päällä?

float velocity  = 0.0f;  // Laskettu nopeus (m/s)
float battEmaV  = 3.9f;  // EMA-suodatettu akkujännite (aloitusarvo n. puoliksi ladattu)

// Tallennetaan milloin toiminnot viimeksi suoritettiin
uint32_t t_imu = 0, t_ble = 0, t_batt = 0;
uint32_t t_vel = 0; // Erikseen, koska tarvitaan dt-laskentaan (aika edellisestä IMU-luvusta)

/* Akku-funktiot */

// Muunnetaan ADC-lukema jännitteeksi prosentteina
static int voltageToPercent(float v) {
  if (v >= BATT_MAX_V) return 100;
  if (v <= BATT_MIN_V) return 0;
  return (int)((v - BATT_MIN_V) / (BATT_MAX_V - BATT_MIN_V) * 100.0f);
}

/*
  Luetaan akku ADC -> EMA-suodatus -> Päivitä BLE-arvo
  EMA (Exponential Moving Average) = painotettu liukuva keskiarvo.
 */
void updateBattery(bool sendNotify) {
  int raw  = analogRead(BATT_ADC_PIN);
  float vNow = (raw / ADC_MAX) * ADC_REF * BATT_SCALE;

  battEmaV = EMA_ALPHA * vNow + (1.0f - EMA_ALPHA) * battEmaV; // EMA-suodatin

  uint8_t pct = (uint8_t)constrain(voltageToPercent(battEmaV), 0, 100);
  pBattChar->setValue(&pct, 1);

  if (sendNotify && bleConnected) pBattChar->notify();

  Serial.printf("[BATT] %.2fV → %d%%\n", battEmaV, pct);
}

/* BLE-YHTEYS */
// Funktiot kutsutaan kun BLE-yhteys muodostuu/katkeaa

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*) override {
    bleConnected = true;
    activeMode   = true;
    t_vel        = millis(); // Nollaa dt-laskennan lähtökohta
    Serial.println("BLE yhdistetty → mittaus alkaa");
  }

  void onDisconnect(NimBLEServer*) override {
    bleConnected = false;
    activeMode   = false;
    velocity     = 0.0f;
    NimBLEDevice::startAdvertising(); // Aloita mainostus uudelleen heti
    Serial.println("BLE katkaistu → odotetaan yhteyttä");
  }
};


void setup() {
  Serial.begin(115200);
  Wire.begin(I2C_SDA, I2C_SCL);
  analogReadResolution(12); // 12-bit ADC = 0–4095 (parempi tarkkuus kuin oletus 10-bit)

  // BMI270-anturin herätys
  if (!imu.begin()) {
    Serial.println("BMI270 ei löytynyt!");
    while (true) delay(1000);
  }

  // Bluetooth-alustus
  NimBLEDevice::init("VBT-Sensor");
  // ESP_PWR_LVL_N6 = -6 dBm lähetysteho akun säästämiseksi, otetaan pois tarvittaessa!
  NimBLEDevice::setPower(ESP_PWR_LVL_N6);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* svc = server->createService(SERVICE_UUID);

  // NOTIFY = laite voi lähettää arvon puhelimeen ilman pyyntöä
  pVelChar  = svc->createCharacteristic(VELOCITY_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY);

  // READ = puhelin voi kysyä arvoa itse
  //NOTIFY = laite voi myös lähettää ilman pyyntöä puhelimelta
  pBattChar = svc->createCharacteristic(BATTERY_CHAR_UUID,
                NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

  svc->start();
  NimBLEDevice::startAdvertising(); // Aloitetaan mainostus

  updateBattery(false); // Luetaan akku heti kättelyssä
  t_batt = millis();

  Serial.println("VBT-laite käynnistetty, odotetaan BLE-yhteyttä..");
}

void loop() {
  uint32_t now = millis();

  /* Lepotila */

  if (!activeMode) {
    if (now - t_batt >= BATT_IDLE_MS) {
      t_batt = now;
      updateBattery(false);
    }
    delay(100); // Vähentämään virrankulutusta
    return;     // Hypätään loopin alkuun
  }

  /* Aktiivitila */

  // IMU-LUKU
  if (now - t_imu >= IMU_INTERVAL_MS) {
    t_imu = now;

    // Tiedon haku BMI270:ltä
    if (imu.accelerationAvailable()) {
      float ax, ay, az;
      imu.readAcceleration(ax, ay, az);

      // Lasketaan kiihtyvyysvektori
      // Levossa 1G = painovoima
      float totalG = sqrtf(ax*ax + ay*ay + az*az);

      // Poistetaan painovoima
      float dynG = fabsf(totalG - 1.0f);

      // dt = aika sekunteina edellisestä IMU-luvusta
      float dt = (now - t_vel) / 1000.0f;
      t_vel = now;

      // Nopeuden laskenta
      if (dynG > ACCEL_THRESHOLD_G) {
        // Liikkeessä integroidaan kihtyvyys nopeudeksi
        velocity += dynG * 9.81f * dt;
      } else {
        // Levossa nopeus vaimenee (simuloidaan jarrutusta)
        velocity *= VELOCITY_DECAY;
        if (velocity < VELOCITY_MIN) velocity = 0.0f; // Estetään loputon lasku
      }

      // Rajoitetaan järkevään alueeseen
      velocity = constrain(velocity, 0.0f, VELOCITY_MAX);
    }
  }

  // BLE-LÄHETYS n. 3.3Hz
  if (bleConnected && (now - t_ble >= BLE_INTERVAL_MS)) {
    t_ble = now;
    char buf[10];
    dtostrf(velocity, 5, 3, buf); // Float -> string, esim. "0.523"
    pVelChar->setValue(buf);
    pVelChar->notify(); // Lähetä puhelimeen
  }

  // Battery check 15s välein aktiivitilassa
  if (now - t_batt >= BATT_ACTIVE_MS) {
    t_batt = now;
    updateBattery(true); // true = lähetä notify puhelimeen
  }

  delay(5);
}