#ifndef EXERCISE_H
#define EXERCISE_H

#include <Arduino.h>

enum ExerciseType {
    CLEAN,          // Rinnalleveto
    SNATCH,         // Tempaus
    CLEAN_AND_JERK, // Rinnalleveto + työntö
    SQUAT,          // Kyykky
    BENCH_PRESS,    // Penkkipunnerrus
    DEADLIFT        // Maastaveto
};

struct ExerciseParams {
    const char* name;
    float startThresholdG;  // Kiihtyvyyskynnys noston alkamiseen (G)
    float stopThresholdG;   // Kynnys, jonka alla liike katsotaan pysähtyneeksi
    float minTargetVel;     // Alin suositeltu nopeus (m/s)
    float maxTargetVel;     // Ylin suositeltu nopeus (m/s)
};

// Funktio, jolla haetaan valitun liikkeen asetukset
ExerciseParams getExerciseParams(ExerciseType type);

#endif