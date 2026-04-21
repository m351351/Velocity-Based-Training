#include "Motion.h"
#include <Wire.h>
#include "Exercise.h"
#include "BLEHandler.h"

extern BoschSensorClass imu;
extern ExerciseType currentExercise;

float velocity = 0.0f;
static float internalVelocity = 0.0f; // Sisäinen fysiikan nopeus (sallii miinuksen, mutta rajoitetusti)

const float NOISE_THRESHOLD = 0.04f; 
const float DRAG_COEFFICIENT_UP = 0.98f;   // Normaali ilmanvastus nostossa
const float DRAG_COEFFICIENT_DOWN = 0.85f; // Raskas ilmanvastus laskussa (tappaa negatiivisen kertymän)

float cal_ax = 0, cal_ay = 0, cal_az = 0;
float cal_mag = 1.0f;

unsigned long lastVelMs = 0;
unsigned long lastImuMs = 0;
const uint32_t IMU_INTERVAL_MS = 20; // 50 Hz

static int restCounter = 0; 

void setupMotion(){
    calibrateMotion();
    lastVelMs = millis();
    lastImuMs = millis();
    Serial.println("Aika_ms,KokonaisG,DynaaminenG,SisainenNopeus,BLE_Nopeus"); 
}

void calibrateMotion() {
    float sum_x = 0, sum_y = 0, sum_z = 0;
    int samples = 100;
    Serial.println("[MOTION] Kalibroidaan... Pida laite paikallaan.");
    
    for (int i = 0; i < samples; i++) {
        if (imu.accelerationAvailable()) {
            float ax, ay, az;
            imu.readAcceleration(ax, ay, az);
            sum_x += ax;
            sum_y += ay;
            sum_z += az;
        }
        delay(10);
    }
    cal_ax = sum_x / samples;
    cal_ay = sum_y / samples;
    cal_az = sum_z / samples;
    cal_mag = sqrtf(cal_ax*cal_ax + cal_ay*cal_ay + cal_az*cal_az);
}



void handleMotion(){
    // Jos BLE ei ole yhdistetty, nollataan tilanne ja palataan
    if (!bleConnected) {
        lastVelMs = millis();
        lastImuMs = millis();
        internalVelocity = 0.0f;
        velocity = 0.0f;
        return; 
    }

    unsigned long now = millis();
    ExerciseParams params = getExerciseParams(currentExercise);

    // IMU + velocity @ 50 Hz
    if (now - lastImuMs >= IMU_INTERVAL_MS) {
        lastImuMs = now;
        
        if (imu.accelerationAvailable()) {
            float ax, ay, az;
            imu.readAcceleration(ax, ay, az);

            float totalAccG = sqrtf(ax * ax + ay * ay + az * az);
            float dt = (now - lastVelMs) / 1000.0f;
            lastVelMs = now;

            // 1. LEPOTILAN TUNNISTUS (KIRISTETTY)
            // Jos kokonaiskiihtyvyys on erittäin lähellä 1.0G (normaali painovoima)
            if (fabsf(totalAccG - 1.0f) < 0.04f) {
                restCounter++;
            } else {
                restCounter = 0; 
            }

            // Lasketaan dynaaminen kiihtyvyys suuntavektorilla
            float dot = (ax * cal_ax + ay * cal_ay + az * cal_az) / cal_mag;
            float dynamicAccG = dot - cal_mag;

            // 2. FYSIIKKA VS. LEPO
            if (restCounter > 6) { 
                // Yli 120ms TÄYSIN paikoillaan -> Pakotetaan TÄYDELLINEN resetointi
                
                // Kalibroidaan uusi asento salamannopeasti
                cal_ax = cal_ax * 0.90f + ax * 0.10f;
                cal_ay = cal_ay * 0.90f + ay * 0.10f;
                cal_az = cal_az * 0.90f + az * 0.10f;
                cal_mag = sqrtf(cal_ax*cal_ax + cal_ay*cal_ay + cal_az*cal_az);

                // Tapetaan nopeus nollaan
                internalVelocity = 0.0f;
                velocity = 0.0f;
                
            } else {
                // 1. LIIKKEEN TUNNISTUS
                // dynaaminen kynnysarvo NOISE_THRESHOLDin sijaan
                if (fabsf(dynamicAccG) > params.startThresholdG) {
                    internalVelocity += dynamicAccG * 9.81f * dt;
                }
                
                // EPÄSYMMETRINEN ILMANVASTUS
                if (internalVelocity > 0.0f) {
                    internalVelocity *= DRAG_COEFFICIENT_UP; // Normaali rullaus nostossa
                } else {
                    internalVelocity *= DRAG_COEFFICIENT_DOWN; // Raskas jarrutus alasmenossa
                }
            }

            // Rajoitetaan sisäinen nopeus (Estetään syvä miinus)
            internalVelocity = constrain(internalVelocity, -0.5f, 10.0f);

// 3. KÄYTTÖLIITTYMÄN PÄIVITYS JA TOISTOJEN TUNNISTUS
            if (internalVelocity > 0.0f) {
                velocity = internalVelocity;
            } else {
                velocity = 0.0f;
            }

            // --- VBT TOISTOJEN (REP) ANALYSAATTORI ---
            static bool inRep = false;
            static float repMaxVel = 0.0f;
            static float repSumVel = 0.0f;
            static int repPoints = 0;

            if (velocity > 0.05f) {
                // Toisto on käynnissä
                if (!inRep) {
                    inRep = true;
                    repMaxVel = 0.0f;
                    repSumVel = 0.0f;
                    repPoints = 0;
                    Serial.println("\n[VBT] >>> TOISTO ALKOI >>>");
                }
                if (velocity > repMaxVel) repMaxVel = velocity;
                repSumVel += velocity;
                repPoints++;
            } else {
                // Tanko pysähtyi (Toisto ohi tai lepoaika)
                if (inRep) {
                    inRep = false;
                    // Varmistetaan ettei kyseessä ollut vahinko-tärähdys (vaatii ainakin pari data-pistettä)
                    if (repPoints > 3) {
                        float repMeanVel = repSumVel / repPoints;
                        Serial.printf("[VBT] <<< TOISTO VALMIS! Peak: %.2f m/s | Mean: %.2f m/s <<<\n\n", repMaxVel, repMeanVel);
                    }
                }
            }

            // Debug tulostus perinteiseen tapaan
            if (velocity > 0.01f || restCounter < 15) {
                 Serial.printf("%lu,%.3f,%.3f,%.3f,%.3f\n", now, totalAccG, dynamicAccG, internalVelocity, velocity);
            }
        }
    }
}