import 'package:flutter/material.dart';

enum LiftCategory { powerlifting, weightlifting }

class ExerciseTarget {
  final String name;
  final int id; // Sama ID kuin ESP32-koodissa
  final double minTarget;
  final double maxTarget;
  final double maxY; // Graafin y-akselin maksimi

  ExerciseTarget({
    required this.name, 
    required this.id, 
    required this.minTarget, 
    required this.maxTarget,
    this.maxY = 2.0,
  });
}

final Map<String, ExerciseTarget> exerciseData = {
  "Rinnalleveto": ExerciseTarget(name: "Rinnalleveto", id: 0, minTarget: 1.4, maxTarget: 1.8, maxY: 5.0),
  "Takakyykky": ExerciseTarget(name: "Takakyykky", id: 1, minTarget: 0.5, maxTarget: 0.75, maxY: 2.0),
  "Penkkipunnerrus": ExerciseTarget(name: "Penkkipunnerrus", id: 2, minTarget: 0.4, maxTarget: 0.6, maxY: 1.5),
  "Maastaveto": ExerciseTarget(name: "Maastaveto", id: 3, minTarget: 0.3, maxTarget: 0.5, maxY: 1.5),
  "Tempaus": ExerciseTarget(name: "Tempaus", id: 4, minTarget: 1.6, maxTarget: 2.2, maxY: 6.0),
  "Rinnalleveto + työntö": ExerciseTarget(name: "Rinnalleveto + työntö", id: 5, minTarget: 1.2, maxTarget: 1.6, maxY: 5.0),
};