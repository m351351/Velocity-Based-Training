#include "OTA.h"
#include <Update.h>

BLECharacteristic* pOtaControlChar = nullptr;
BLECharacteristic* pOtaDataChar = nullptr;

bool otaUpdating = false;
bool shouldRestart = false;
size_t otaTotalBytes = 0;

// ----- CONTROL-KANAVAN LOGIIKKA -----
class OtaControlCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pChar) override {
        uint8_t* val = pChar->getData();
        if (pChar->getLength() > 0) {
            
            // KOMENTO 1: ALOITA PÄIVITYS (0x01)
            if (val[0] == 0x01) { 
                Serial.println("\n[OTA] >>> PÄIVITYS ALKAA >>>");
                // UPDATE_SIZE_UNKNOWN antaa ESP:n ottaa vastaan dataa, kunnes sanomme seis
                if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
                    Update.printError(Serial);
                } else {
                    otaUpdating = true;
                    otaTotalBytes = 0;
                    Serial.println("[OTA] Valmiina vastaanottamaan dataa...");
                }
            } 
            // KOMENTO 2: LOPETA JA ASENNA (0x02)
            else if (val[0] == 0x02) { 
                Serial.println("\n[OTA] <<< DATA VASTAANOTETTU, ASENNETAAN... <<<");
                if (Update.end(true)) {
                    Serial.println("[OTA] Asennus onnistui! Laite käynnistyy uudelleen.");
                    shouldRestart = true;
                } else {
                    Update.printError(Serial);
                    otaUpdating = false;
                }
            }
            // KOMENTO 3: KESKEYTÄ/PERUUTA (0x03)
            else if (val[0] == 0x03) {
                Serial.println("\n[OTA] --- PÄIVITYS KESKEYTETTY! ---");
                Update.abort();
                otaUpdating = false;
                otaTotalBytes = 0;
            }
        }
    }
};

// ----- DATA-KANAVAN LOGIIKKA -----
class OtaDataCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pChar) override {
        if (!otaUpdating) return;
        
        size_t len = pChar->getLength();
        uint8_t* data = pChar->getData();
        
        if (len > 0) {
            // Kirjoitetaan saapunut palanen suoraan ESP32:n Flash-muistiin
            size_t written = Update.write(data, len);
            if (written == len) {
                otaTotalBytes += len;
                // Tulostetaan tilannepäivitys aina n. 10 kt välein
                if (otaTotalBytes % 10240 < 500) {
                    Serial.printf("[OTA] Ladattu: %d tavua\n", otaTotalBytes);
                }
            } else {
                Update.printError(Serial);
            }
        }
    }
};

void setupOTA(BLEServer* pServer) {
    // Luodaan erillinen Service päivityksiä varten
    BLEService* pOtaService = pServer->createService(OTA_SERVICE_UUID);
    
    // Control = WRITE & NOTIFY (Komennot puhelimelta ja kuittaukset ESP:ltä)
    pOtaControlChar = pOtaService->createCharacteristic(
        OTA_CONTROL_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY
    );
    pOtaControlChar->setCallbacks(new OtaControlCallbacks());

    // Data = WRITE_NR (Write No Response maksimoi tiedonsiirtonopeuden)
    pOtaDataChar = pOtaService->createCharacteristic(
        OTA_DATA_UUID,
        BLECharacteristic::PROPERTY_WRITE_NR 
    );
    pOtaDataChar->setCallbacks(new OtaDataCallbacks());

    pOtaService->start();
    Serial.println("[OTA] Päivityspalvelu aktivoitu!");
}

void handleOTA() {
    // Tehdään uudelleenkäynnistys turvallisesti pääloopissa, ei BLE-keskeytyksen sisällä
    if (shouldRestart) {
        delay(1000); // Annetaan BLE-pinon sulkeutua rauhassa
        ESP.restart();
    }
}