#include "Motion.h"
#include <Wire.h>

extern BoschSensorClass imu;

float velocity = 0.0f;
float gravityOffset = 1.0f;
unsigned long lastVelMs = 0;
unsigned long lastImuMs = 0;
const uint32_t IMU_INTERVAL_MS = 20; // 50 Hz

void setupMotion(){

    unsigned long lastVelMs = 0;
    unsigned long lastImuMs = 0;

    calibrateMotion();
}

void calibrateMotion() {
    float sum = 0;
    int samples = 100;
    Serial.println("[MOTION] Kalibroidaan... Pida laite paikallaan.");
    
    for (int i = 0; i < samples; i++) {
        if (imu.accelerationAvailable()) {
            float ax, ay, az;
            imu.readAcceleration(ax, ay, az);
            sum += sqrtf(ax*ax + ay*ay + az*az);
        }
        delay(10);
    }
    gravityOffset = sum / samples;
    Serial.printf("[MOTION] Kalibrointi valmis. Offset: %.4f\n", gravityOffset);
}



void handleMotion(){

    unsigned long now = millis();

    // IMU + velocity @ 50 Hz
    if (now - lastImuMs >= IMU_INTERVAL_MS) {
        lastImuMs = now;

        if (imu.accelerationAvailable()) {
        float ax, ay, az;
        imu.readAcceleration(ax, ay, az);

        float totalAccG = sqrtf(ax * ax + ay * ay + az * az);
        float dynamicAccG = fabsf(totalAccG - 1.0f);

        float dt = (now - lastVelMs) / 1000.0f;
        lastVelMs = now;

        if (dynamicAccG > 0.15f) velocity += dynamicAccG * 9.81f * dt; // m/s^2 -> m/s
        else {
            velocity *= 0.8f;
            if (velocity < 0.05f) velocity = 0.0f;
        }
        velocity = constrain(velocity, 0.0f, 3.0f);
    }
  }
}