#include <Arduino.h>
#include <Wire.h> // I2C-VÄYLÄKIRJASTO
#include <math.h>
#include <BLEUtils.h>
#include "Arduino_BMI270_BMM150.h" // Kiihtyvyysanturin ajurikirjasto
#include "Battery.h" // Akun mittausmoduuli
#include "BLEHandler.h" // BLE-yhteysmoduuli
#include "Motion.h" // Liiketunnistusmoduuli
#include "OTA.h" // Langattoman päivityksen "Over the air" moduuli

// I2C-pinnit (ESP32-C3 Superminille)
// SDA = Serial Data, SCL = Serial Clock
#define I2C_SDA 8
#define I2C_SCL 9

// Tämä hoitaa BMI270:n I2C-kommunikoinnin
BoschSensorClass imu(Wire);

void setup() {
  Serial.begin(115200);
  delay(300);
// ADC-konfiguraatio akun mittausta varten
  Wire.begin(I2C_SDA, I2C_SCL);
  analogReadResolution(12);
// Alustetaan IMU ja BLE
  if (!imu.begin()) {
    Serial.println("BMI270 ei vastaa! Jatketaan BLE:llä.");
  }

  setupBLE(); // Alustetaan BLE
  setupMotion(); // Alustetaan IMU-kalibrointi ja laskenta

  updateBattery(false); // Luetaan akun tila heti käynnistyksen yhteydessä

}


void loop() {
    /* JÄTETÄÄN OVER THE AIR- PÄIVITYS KÄYTÖSTÄ TOISTAISEKSI, JATKOKEHITYSTÄ VARTEN KUITENKIN JÄTÄN TÄHÄN */
   // handleOTA();
  
   // LEPOTILA: Puhelin ei ole yhdistettynä
    if (!bleConnected) {
    
    handleBattery(); // Päivitetään akun tila, jotta puhelin saa ajan tasalla olevan prosenttilukeman heti yhdistettäessä
    delay(200);      // Tämä 200ms antaa ESP32:n nukkua taustalla!
    return;          
  }
  
  // AKTIIVITILA: Puhelin yhdistettynä, mittaillaan ja lähetetään dataa
  handleBattery(); // Akun seuranta
  handleMotion(); // IMU-lukeminen, nopeuden laskenta, toistojen tunnistus
  sendVelocityNotify(velocity); // Lähetetään nopeus puhelimeen

}