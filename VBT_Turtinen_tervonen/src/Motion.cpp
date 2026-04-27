#include "Motion.h"
#include <Wire.h>
#include "Exercise.h"
#include "BLEHandler.h"

extern BoschSensorClass imu;
extern ExerciseType currentExercise;

// Nopeusmuuttujat
float velocity = 0.0f; // Tämä lähetetään puhelimeen (vain positiivinen)
static float internalVelocity = 0.0f; // Sisäinen fysiikan nopeus


// Kalibrointimuuttujat
// Gravitaatiokiihtyvyden suunta kalibrointihetkellä
float cal_ax = 0, cal_ay = 0, cal_az = 0;
// Gravitaativektorin pituus kalibrointihetkellä (normaalisti noin 1.0 G)
float cal_mag = 1.0f;

// Ajastimet IMU-lukemiselle ja nopeuden laskulle
unsigned long lastVelMs = 0; // Integroinnin viiteaika (dt-laskentaa varten)
unsigned long lastImuMs = 0; // IMU-lukemisen ajankohta
const uint32_t IMU_INTERVAL_MS = 20; // 50 Hz <- SÄÄDÄ TARVITTAESSA

// Lepotilan tunnistuksen ajastimet (Signaalin rauhoitus)
static unsigned long restStableMs = 0; // Milloin laite alkoi olla paikallaan (aika nollaantuu liikkeessä)
static unsigned long repBelowMs = 0; // Milloin nopeus viimeksi laski alle rajan (toiston loppu)

// Toistojen seuranta
bool inRep = false; // Onko toisto käynnissä? 
static float repMaxVel = 0.0f; // Toiston korkein mitattu nopeus
static float repSumVel = 0.0f; // Kaikkien nopeuksien summa toiston aikana (keskiarvoa varten)
static int repPoints = 0; // Näytteiden lukumäärä toistojen aikana

void setupMotion() {
    calibrateMotion(); // Mitataan laitteen lepotilan asento
    lastVelMs = millis(); // Nopeuslaskenta alkaa
    lastImuMs = millis(); // IMU-lukeminen alkaa
    Serial.println("Aika_ms,KokonaisG,DynaaminenG,SisainenNopeus,BLE_Nopeus"); 
}

void calibrateMotion() {
    float sum_x = 0, sum_y = 0, sum_z = 0;
    int samples = 100; // 100 näytettä kalibrointiin = noin 1 sekunti paikallaan!
    Serial.println("Kalibroidaan... Pida laite paikallaan.");
    
    for (int i = 0; i < samples; i++) {
        if (imu.accelerationAvailable()) {
            float ax, ay, az;
            imu.readAcceleration(ax, ay, az); // Luetaan kiihtyvyys (yksikkö = G)
            sum_x += ax;
            sum_y += ay;
            sum_z += az;
        }
        delay(10);
    }

    // Lasketaan kalibrointiarvojen keskiarvo
    cal_ax = sum_x / samples;
    cal_ay = sum_y / samples;
    cal_az = sum_z / samples;
    // Gravitaatiovektorin pituus kalibrointihetkellä
    cal_mag = sqrtf(cal_ax*cal_ax + cal_ay*cal_ay + cal_az*cal_az);
}

// Pääsilmukka, joka lukee IMU:ta, laskee nopeuden ja tunnistaa toistot
// Pääsilmukka, joka lukee IMU:ta, laskee nopeuden ja tunnistaa toistot
void handleMotion() {
    // Jos BLE ei ole yhdistetty, nollataan tilanne ja poistutaan
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
        lastImuMs += IMU_INTERVAL_MS;
        
        if (imu.accelerationAvailable()) { // Uutta dataa saatavilla?
            float ax, ay, az;
            imu.readAcceleration(ax, ay, az); // Luetaan akseleraatiolukemat

            float dt = 0.02f;
            lastVelMs = now;

            // Dynaamisen kiihtyvyyden laskenta kalibroidun gravitaatiovektorin avulla
            float dot = (ax * cal_ax + ay * cal_ay + az * cal_az) / cal_mag;
            float dynamicAccG = dot - cal_mag;

            // 1. LEPOTILAN TUNNISTUS JA FYSIIKKA
            if (fabsf(dynamicAccG) < 0.04f && fabsf(internalVelocity) < 0.08f) {
                if (restStableMs == 0) restStableMs = now; // Lepotilan alkamisaika
                
                if (now - restStableMs > 200) { 
                    cal_ax = cal_ax * 0.90f + ax * 0.10f;
                    cal_ay = cal_ay * 0.90f + ay * 0.10f;
                    cal_az = cal_az * 0.90f + az * 0.10f;
                    cal_mag = sqrtf(cal_ax*cal_ax + cal_ay*cal_ay + cal_az*cal_az);
                    // Lepotilassa nopeus nollataan = estää driftin kertymisen
                    internalVelocity = 0.0f;
                    velocity = 0.0f;
                }
            } else {
                restStableMs = 0; // Liike alkoi -> Nollataan lepotilan ajastin
                
                // Nopeuslaskenta: Integroi dynaaminen kiihtyvyys vain jos se ylittää aloituskynnyksen
                if (fabsf(dynamicAccG) > 0.04f) {
                    internalVelocity += dynamicAccG * 9.81f * dt;
                }
                
                // ÄLYKÄS NOPEUDEN HALLINTA (Korjaa roikkumaan jäävän nopeuden ja "seinään" osumisen)
                if (internalVelocity > 0.0f) {
                    if (dynamicAccG < -0.04f) {
                        // 1. Hidastuvaihe: Painovoima iskee vastaan. Pehmennetään käyrää hieman.
                        internalVelocity *= 0.95f; 
                    } else if (fabsf(dynamicAccG) <= 0.04f) {
                        // 2. Pysähdys (Deadband): Tanko on pysähtynyt! Tapetaan "haamunopeus" heti pois.
                        internalVelocity *= 0.80f; 
                    }
                    // 3. Aktiivinen työntö (dynamicAccG > 0.04f): EI JARRUA. Saat pitää nopeutesi!
                } else {
                    // Tapetaan mahdolliset miinukselle valuvat nopeudet nopeasti
                    internalVelocity *= 0.80f;
                }
            } // <--- TÄMÄ SULKU OLI SE MIKÄ SINULTA HUKKUI!

            // Rajoitetaan sisäinen nopeus
            internalVelocity = constrain(internalVelocity, -0.5f, 10.0f);

            // Näyttönopeus on aina posiivinen ja nollataan jos sisäinen nopeus liian pieni
            if (internalVelocity > 0.0f) {
                velocity = internalVelocity;
            } else {
                velocity = 0.0f;
            }

            // 2. TOISTOJEN NOPEUSRAJOITUS JA TUNNISTUS. Tilakone inRep = true/false
            if (velocity > 0.05f) {
                // Toisto on käynnissä
                if (!inRep) {
                    inRep = true;
                    repMaxVel = 0.0f;
                    repSumVel = 0.0f;
                    repPoints = 0;
                    Serial.println("\nTOISTO ALKOI");
                }

                // Päivitetään toiston tilastot
                if (velocity > repMaxVel) repMaxVel = velocity; // Huippunopeus
                repSumVel += velocity; // Nopeuksien summa keskiarvoa varten
                repPoints++; // Näytteiden lukumäärä
                
                repBelowMs = 0; // Nollataan laskuri jotta toisto ei pääty vahingossa kesken

            } else if (inRep) {
                if (repBelowMs == 0) repBelowMs = now; 
                
                // Jos on oltu yli 200ms yhtäjaksoisesti alle nopeusrajan, toisto on ohi
                if (now - repBelowMs > 200) { 
                    inRep = false;
                    
                    // Validointi: Vähintään 8 datapistettä ja 0.20 m/s huippunopeus
                    if (repPoints >= 8 && repMaxVel >= 0.20f) {
                        float repMeanVel = repSumVel / repPoints;
                        Serial.printf("TOISTO VALMIS! Peak: %.2f m/s | Mean: %.2f m/s \n\n", repMaxVel, repMeanVel);
                        
                        // Lähetetään tarkan mittauksen tulos puhelimelle
                        sendRepResults(repMaxVel, repMeanVel);
                        
                    } else {
                        Serial.printf("Toisto hylätty (Haamu). Pisteet: %d, Peak: %.2f ---\n\n", repPoints, repMaxVel);
                    }
                    repBelowMs = 0; // Nollataan laskuri seuraavaa toistoa varten
                } 
            }

            // 3. DATALOGGERI
            if (velocity > 0.01f || (restStableMs > 0 && now - restStableMs < 1000)) {
                 // Lasketaan KokonaisG vain tätä debug-printtiä varten!
                 float totalAccG = sqrtf(ax * ax + ay * ay + az * az); 
                 
                 Serial.printf("%lu,%.3f,%.3f,%.3f,%.3f\n", 
                               now, totalAccG, dynamicAccG, internalVelocity, velocity);
            }

        } // <- Tämä on imu.accelerationAvailable() lopetussulku
    } // <- Tämä on IMU_INTERVAL_MS lopetussulku
} // <- Tämä on handleMotion() funktion lopetussulku