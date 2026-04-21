#ifndef MOTION_H
#define MOTION_H

#include <Arduino.h>
#include "Arduino_BMI270_BMM150.h"
#include "Exercise.h"

// Julkiset funktiot
void setupMotion();
void handleMotion();
void calibrateMotion();

extern float velocity; // Julkinen muuttuja, jotta BLEHandler tai main voi lukea nopeuden
extern ExerciseType currentExercise;

#endif