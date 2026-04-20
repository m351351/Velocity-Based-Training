#ifndef MOTION_H
#define MOTION_H

#include <Arduino.h>
#include "Arduino_BMI270_BMM150.h"

// Julkiset funktiot
void setupMotion();
void handleMotion();
void calibrateMotion();

// Julkinen muuttuja, jotta BLEHandler tai main voi lukea nopeuden
extern float velocity;

#endif