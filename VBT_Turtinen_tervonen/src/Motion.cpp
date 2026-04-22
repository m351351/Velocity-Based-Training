#include "Motion.h"
#include <Wire.h>
#include "Exercise.h"
#include "BLEHandler.h"

extern BoschSensorClass imu;
extern ExerciseType currentExercise;

float velocity = 0.0f; // Tämä lähetetään puhelimeen (vain positiivinen)
static float internalVelocity = 0.0f; // Sisäinen fysiikan nopeus

const float DRAG_COEFFICIENT_UP = 0.98f;   // Normaali ilmanvastus nostossa
const float DRAG_COEFFICIENT_DOWN = 0.90f; // Raskas ilmanvastus laskussa (tappaa negatiivisen kertymän)

float cal_ax = 0, cal_ay = 0, cal_az = 0;
float cal_mag = 1.0f;

unsigned long lastVelMs = 0;
unsigned long lastImuMs = 0;
const uint32_t IMU_INTERVAL_MS = 20; // 50 Hz

// UUDET AJASTIMET (Signaalin rauhoitus)
static unsigned long restStableMs = 0;
static unsigned long repBelowMs = 0;

// Toistojen seuranta
static bool inRep = false;
static float repMaxVel = 0.0f;
static float repSumVel = 0.0f;
static int repPoints = 0;

void setupMotion() {
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

void handleMotion() {
    // Jos BLE ei ole yhdistetty, nollataan tilanne ja palataan
    if (!bleConnected) {
        lastVelMs = millis();
        lastImuMs = millis();
        internalVelocity = 0.0f;
        velocity = 0.0f;
        restStableMs = 0;
        inRep = false;
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

            float dot = (ax * cal_ax + ay * cal_ay + az * cal_az) / cal_mag;
            float dynamicAccG = dot - cal_mag;

            // 1. LEPOTILAN TUNNISTUS (FAKTAPOHJAINEN LOGIIKKA)
            // Kiihtyvyys lähellä nollaa JA nopeus lähellä nollaa
            if (fabsf(dynamicAccG) < 0.04f && fabsf(internalVelocity) < 0.08f) {
                if (restStableMs == 0) restStableMs = now; // Aloitetaan laskenta
                
                if (now - restStableMs > 200) { // Yli 200ms vakaana -> lepo
                    cal_ax = cal_ax * 0.90f + ax * 0.10f;
                    cal_ay = cal_ay * 0.90f + ay * 0.10f;
                    cal_az = cal_az * 0.90f + az * 0.10f;
                    cal_mag = sqrtf(cal_ax*cal_ax + cal_ay*cal_ay + cal_az*cal_az);
                    
                    internalVelocity = 0.0f;
                    velocity = 0.0f;
                }
            } else {
                // Liikettä havaittu -> Nollataan lepolaskuri
                restStableMs = 0; 
                
                // LIIKKEEN TUNNISTUS (Käytetään dynaamista params.startThresholdG arvoa)
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

            // Rajoitetaan sisäinen nopeus (Estetään syvä miinus, maksimi kasvatettu 10.0f)
            internalVelocity = constrain(internalVelocity, -0.5f, 10.0f);

            // 2. KÄYTTÖLIITTYMÄN PÄIVITYS
            if (internalVelocity > 0.0f) {
                velocity = internalVelocity;
            } else {
                velocity = 0.0f;
            }

            // 3. TOISTOJEN TUNNISTUS JA "DEBOUNCE"
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
                
                repBelowMs = 0; // Nollataan toiston lopetusajastin, koska liike jatkuu!
            } else if (inRep) {
                // Nopeus putosi alle 0.05f, mutta OLLAANKO TODELLA PYSÄHDYTTY?
                if (repBelowMs == 0) repBelowMs = now; // Aloitetaan lopetuslaskenta
                
                // Jos on oltu yli 200ms yhtäjaksoisesti alle nopeusrajan, toisto on oikeasti ohi
                if (now - repBelowMs > 200) { 
                    inRep = false;
                    
                    // Validointi: Vähintään 160ms (8 data-pistettä) ja 0.20 m/s huippunopeus
                    if (repPoints >= 8 && repMaxVel >= 0.20f) {
                        float repMeanVel = repSumVel / repPoints;
                        Serial.printf("[VBT] <<< TOISTO VALMIS! Peak: %.2f m/s | Mean: %.2f m/s <<<\n\n", repMaxVel, repMeanVel);
                    } else {
                        Serial.printf("[VBT] --- Toisto hylatty (Haamu). Pisteet: %d, Peak: %.2f ---\n\n", repPoints, repMaxVel);
                    }
                    repBelowMs = 0;
                }
            }

            // 4. LOKITUS (Tulostetaan vain liikkeessä tai hetki pysähtymisen jälkeen)
            if (velocity > 0.01f || (restStableMs > 0 && now - restStableMs < 1000)) {
                 // Kommentoi tämä auki jos haluat taas kerätä Excel-dataa:
                 //Serial.printf("%lu,%.3f,%.3f,%.3f,%.3f\n", now, totalAccG, dynamicAccG, internalVelocity, velocity);
            }
        }
    }
}