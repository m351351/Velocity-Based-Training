import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class VelocityChart extends StatelessWidget {
  final List<FlSpot> spots;
  final double maxY;
  final Color lineColor;

  const VelocityChart({
    super.key, 
    required this.spots, 
    required this.maxY, 
    this.lineColor = Colors.cyanAccent
  });

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots.isEmpty ? [const FlSpot(0, 0)] : spots,
            isCurved: true,
            color: lineColor,
            barWidth: 4,
            belowBarData: BarAreaData(show: true, color: lineColor.withOpacity(0.1)),
          ),
        ],
        titlesData: const FlTitlesData(show: false), // Pidetään simppelinä aluksi
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}