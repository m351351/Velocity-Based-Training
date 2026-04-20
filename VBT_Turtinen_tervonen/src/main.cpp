#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <BLEUtils.h>
#include "Arduino_BMI270_BMM150.h"
#include "Battery.h"
#include "BLEHandler.h"
#include "Motion.h"

#define I2C_SDA 8
#define I2C_SCL 9

BoschSensorClass imu(Wire);



void setup() {
  Serial.begin(115200);
  delay(300);

  Wire.begin(I2C_SDA, I2C_SCL);
  analogReadResolution(12);

  if (!imu.begin()) {
    Serial.println("BMI270 ei vastaa! Jatketaan BLE:llä.");
  }

  setupBLE();
  setupMotion();

  updateBattery(false);

}



void loop() {
  
  handleBattery();
  handleMotion();
  sendVelocityNotify(velocity);



  delay(5);
}