#include "Exercise.h"

ExerciseParams getExerciseParams(ExerciseType type) {
    switch (type) {
        case CLEAN:
            // Rinnalleveto on nopea: vaatii selvän alun ja tavoitenopeus on korkea
            return {"Rinnalleveto", 0.30f, 0.10f, 1.10f, 1.50f};
        
        case SQUAT:
            // Kyykky on hitaampi: reagoi herkemmin pieneenkin liikkeeseen
            return {"Kyykky", 0.12f, 0.05f, 0.50f, 0.70f};
            
        case BENCH_PRESS:
            return {"Penkkipunnerrus", 0.15f, 0.08f, 0.40f, 0.60f};
            
        case DEADLIFT:
            return {"Maastaveto", 0.10f, 0.05f, 0.30f, 0.50f};
            
        default:
            return {"Vakio", 0.15f, 0.10f, 0.50f, 1.00f};
    }
}