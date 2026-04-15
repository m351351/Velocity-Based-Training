#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "Arduino_BMI270_BMM150.h" // Käytetään tätä, koska se toimi!

#define I2C_SDA 8
#define I2C_SCL 9

#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHARACTERISTIC_UUID "abcd1234-ab12-ab12-ab12-abcdef123456"

BoschSensorClass imu(Wire);
BLECharacteristic* pCharacteristic = nullptr;
bool bleConnected = false;

float velocity = 0.0;
unsigned long lastTime = 0;
bool isLifting = false;

// CALLBACKS
class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* s) override { bleConnected = true; }
    void onDisconnect(BLEServer* s) override { 
        bleConnected = false; 
        s->startAdvertising(); 
    }
};

void setup() {
    Serial.begin(115200);
    // TÄRKEÄÄ: Jos Serial Monitor on tyhjä, kokeile lisätä: delay(2000);
    
    Wire.begin(I2C_SDA, I2C_SCL);
    
    if (!imu.begin()) {
        Serial.println("BMI270 ei vastaa!");
        // Älä jätä while(1) tähän, jotta BLE voi silti käynnistyä testausta varten
    }

    BLEDevice::init("VBT-Sensor");
    BLEServer* pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());
    BLEService* pService = pServer->createService(SERVICE_UUID);
    pCharacteristic = pService->createCharacteristic(
        CHARACTERISTIC_UUID,
        BLECharacteristic::PROPERTY_NOTIFY
    );
    pCharacteristic->addDescriptor(new BLE2902());
    pService->start();
    pServer->getAdvertising()->start();

    lastTime = millis();
    Serial.println("VBT Valmis!");
}

void loop() {
    if (!imu.accelerationAvailable()) return;

    float ax, ay, az;
    imu.readAcceleration(ax, ay, az);

    // Kiihtyvyyden laskenta
    float totalAcc = sqrt(ax*ax + ay*ay + az*az) * 9.81;
    float dynamicAcc = abs(totalAcc - 9.81);

    unsigned long now = millis();
    float dt = (now - lastTime) / 1000.0;
    lastTime = now;

    // Yksinkertainen integrointi
    if (dynamicAcc > 1.5) { // Jos kiihtyvyys yli 1.5 m/s2
        isLifting = true;
        velocity += dynamicAcc * dt;
    } else {
        isLifting = false;
        velocity *= 0.8; // Vaimennus kun liike loppuu
        if (velocity < 0.05) velocity = 0.0;
    }

    // LÄHETYS FLUTTERILLE
    if (bleConnected) {
        // MUUTOS: Ei lähetetä JSONia, vaan pelkkä numero tekstinä
        // Flutterin double.tryParse() vaatii tämän
        char buf[16];
        dtostrf(velocity, 4, 3, buf); 
        pCharacteristic->setValue(buf);
        pCharacteristic->notify();
    }

    // Monitorointi
    Serial.print("Acc: "); Serial.print(dynamicAcc);
    Serial.print(" Vel: "); Serial.println(velocity);
    
    delay(40); 
}