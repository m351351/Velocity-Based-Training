import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';

enum LiftCategory { powerlifting, weightlifting }

void main() {
  runApp(const VBTApp());
}

class VBTApp extends StatelessWidget {
  const VBTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Velocity Based Training',
      theme: ThemeData.dark(), // Tumma teema kuntosaliympäristöön
      home: const VBTPage(),
    );
  }
}

class VBTPage extends StatefulWidget {
  const VBTPage({super.key});

  @override
  State<VBTPage> createState() => _VBTPageState();
}

// TÄÄLLÄ ALOITUSNÄKYMÄÄN TULEVAT TEKSTIT -meri 190326
class _VBTPageState extends State<VBTPage> {
  bool isRecording = false;
  final List<double> _setVelocities = []; // tallennetaan sarjan nopeudet analyysiä varten
  double peakVelocity = 0.0; // sarjan huippunopeus
  double meanVelocity = 0.0; // sarjan keskinopeus
  double currentVelocity = 0.0;

  bool useMockData = true;
  String connectionStatus = 'BLE: ei yhdistetty';

  BluetoothDevice? _device;
  BluetoothCharacteristic? _velocityChar;
  StreamSubscription<List<int>>? _bleSub;
  List<ScanResult> _scanResults = []; // löydetyt BLE-laitteet käyttäjän valintaa varten

  final List<FlSpot> _velocitySpots = []; // graafipisteet
  double _x = 0.0; // ajan kulumista simuloiva muuttuja graafia varten
  double _t = 0.0; // simulointia varten "aika"
  Timer? _timer;
  final Random _random = Random();

  // Lajivalinta + liikevalinta
  LiftCategory selectedCategory = LiftCategory.powerlifting;
  String valittuLiike = "Takakyykky";
  double targetVelocityLoss = 20.0; // käyttäjän asettama tavoite velocity lossille
                                    // tähän voisi ilmeisesti laittaa myös tietokantayhteyden jolloin käyttäjä voisi
                                    // asettaa itselleen haluamansa tavoitteen tai valita jostain valmiista. Ei tarvi demoon. -meri

  final List<String> powerliftingLiikkeet = [
    "Takakyykky",
    "Penkkipunnerrus",
    "Maastaveto",
  ];

  final List<String> weightliftingLiikkeet = [
    "Tempaus",
    "Rinnalleveto",
    "Rinnalleveto + työntö",
  ];

  List<String> get visibleLiikkeet =>
      selectedCategory == LiftCategory.powerlifting ? powerliftingLiikkeet : weightliftingLiikkeet;

  // ----------------------------
  // Zone / luokittelulogiikka
  // ----------------------------

  String get powerliftingZone {
    final v = meanVelocity;
    if (v > 1.3) return 'Starting Strength';
    if (v >= 1.0) return 'Speed-Strength';
    if (v >= 0.75) return 'Strength-Speed';
    if (v >= 0.5) return 'Accelerative Strength';
    return 'Absolute Strength';
  }

  String get powerliftingZoneGoal {
    final v = meanVelocity;
    if (v > 1.3) return '<30% 1RM';
    if (v >= 1.0) return '30–45% 1RM';
    if (v >= 0.75) return '45–60% 1RM';
    if (v >= 0.5) return '60–80% 1RM';
    return '>80% 1RM';
  }

  Color get powerliftingZoneColor {
    final v = meanVelocity;
    if (v > 1.3) return Colors.lightBlueAccent;
    if (v >= 1.0) return Colors.blueAccent;
    if (v >= 0.75) return Colors.greenAccent;
    if (v >= 0.5) return Colors.amberAccent;
    return Colors.redAccent;
  }

  // Painonnoston liikespesifiset peak-rajat
  (double min, double optLow, double optHigh) _wlThresholds(String liike) {
    switch (liike) {
      case "Tempaus":
        return (1.6, 1.8, 2.2);
      case "Rinnalleveto":
        return (1.4, 1.6, 1.8);
      case "Rinnalleveto + työntö":
        return (1.2, 1.4, 1.6);
      default:
        return (1.4, 1.6, 1.8);
    }
  }

  String get weightliftingAssessment {
    final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
    final v = peakVelocity;

    if (v < min) return 'Alle minimin (${min.toStringAsFixed(1)} m/s)';
    if (v <= optHigh && v >= optLow) {
      return 'Optimaalinen (${optLow.toStringAsFixed(1)}–${optHigh.toStringAsFixed(1)} m/s)';
    }
    if (v > optHigh) return 'Yli optimaalisen';
    return 'Minimin yli, mutta ei optimaalinen';
  }

  Color get weightliftingColor {
    final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
    final v = peakVelocity;
    if (v < min) return Colors.redAccent;
    if (v >= optLow && v <= optHigh) return Colors.greenAccent;
    if (v > optHigh) return Colors.lightBlueAccent;
    return Colors.amberAccent;
  }

  // Voimannostossa seurataan velocity lossia
  double get velocityLossPercent {
    if (_setVelocities.length < 2) return 0.0;
    final best = _setVelocities.reduce((a, b) => a > b ? a : b);
    final latest = _setVelocities.last;
    if (best <= 0) return 0.0;
    return ((best - latest) / best) * 100.0;
  }

  String get velocityLossText {
    final vl = velocityLossPercent;
    if (vl <= 20) return '10–20%: voima/räjähtävyys';
    if (vl <= 40) return '30–40%: hypertrofia';
    return '>40%: failure-riski';
  }

  Color get velocityLossColor {
    final vl = velocityLossPercent;
    if (vl <= 20) return Colors.greenAccent;
    if (vl <= 40) return Colors.amberAccent;
    return Colors.redAccent;
  }

  String get analysisText {
    if (isRecording) return 'Analyysi: Sarja käynnissä...';
    if (_setVelocities.isEmpty) return 'Analyysi: Odota suoritusta...';

    if (selectedCategory == LiftCategory.powerlifting) {
      return 'Zone: $powerliftingZone • $powerliftingZoneGoal';
    } else {
      return 'Peak-arvio: $weightliftingAssessment';
    }
  }

  // ----------------------------
  // Graafin apulogiikka
  // ----------------------------

  // Sticking point ~ alin nopeus sarjan keskialueella
  FlSpot? get stickingPointSpot {
    if (_velocitySpots.length < 10 || selectedCategory != LiftCategory.powerlifting) return null;

    final start = (_velocitySpots.length * 0.25).floor();
    final end = (_velocitySpots.length * 0.75).floor();
    if (end <= start) return null;

    FlSpot minSpot = _velocitySpots[start];
    for (int i = start + 1; i < end; i++) {
      if (_velocitySpots[i].y < minSpot.y) {
        minSpot = _velocitySpots[i];
      }
    }
    return minSpot;
  }

  FlSpot? get peakSpot {
    if (_velocitySpots.isEmpty || selectedCategory != LiftCategory.weightlifting) return null;
    FlSpot maxSpot = _velocitySpots.first;
    for (final s in _velocitySpots) {
      if (s.y > maxSpot.y) maxSpot = s;
    }
    return maxSpot;
  }

  List<HorizontalLine> get zoneLines {
    if (selectedCategory == LiftCategory.powerlifting) {
      return [
        HorizontalLine(y: 0.5, color: Colors.redAccent.withOpacity(0.45), strokeWidth: 1),
        HorizontalLine(y: 0.75, color: Colors.amberAccent.withOpacity(0.45), strokeWidth: 1),
        HorizontalLine(y: 1.0, color: Colors.greenAccent.withOpacity(0.45), strokeWidth: 1),
        HorizontalLine(y: 1.3, color: Colors.lightBlueAccent.withOpacity(0.45), strokeWidth: 1),
      ];
    } else {
      final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
      return [
        HorizontalLine(y: min, color: Colors.redAccent.withOpacity(0.45), strokeWidth: 1),
        HorizontalLine(y: optLow, color: Colors.amberAccent.withOpacity(0.45), strokeWidth: 1),
        HorizontalLine(y: optHigh, color: Colors.greenAccent.withOpacity(0.45), strokeWidth: 1),
      ];
    }
  }

  // zone-taustat graafiin
  List<RangeAnnotations> get zoneBackgrounds {
    if (selectedCategory == LiftCategory.powerlifting) {
      return [
        RangeAnnotations(horizontalRangeAnnotations: [
          HorizontalRangeAnnotation(y1: 0.0, y2: 0.5, color: Colors.red.withOpacity(0.06)),
          HorizontalRangeAnnotation(y1: 0.5, y2: 0.75, color: Colors.amber.withOpacity(0.06)),
          HorizontalRangeAnnotation(y1: 0.75, y2: 1.0, color: Colors.green.withOpacity(0.06)),
          HorizontalRangeAnnotation(y1: 1.0, y2: 1.3, color: Colors.blue.withOpacity(0.06)),
          HorizontalRangeAnnotation(y1: 1.3, y2: 1.5, color: Colors.lightBlue.withOpacity(0.06)),
        ])
      ];
    } else {
      final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
      return [
        RangeAnnotations(horizontalRangeAnnotations: [
          HorizontalRangeAnnotation(y1: 0.0, y2: min, color: Colors.red.withOpacity(0.05)),
          HorizontalRangeAnnotation(y1: min, y2: optLow, color: Colors.amber.withOpacity(0.05)),
          HorizontalRangeAnnotation(y1: optLow, y2: optHigh, color: Colors.green.withOpacity(0.05)),
          HorizontalRangeAnnotation(y1: optHigh, y2: 2.6, color: Colors.blue.withOpacity(0.05)),
        ])
      ];
    }
  }

  double get heroValue => selectedCategory == LiftCategory.powerlifting ? meanVelocity : peakVelocity;

  Color get heroColor => selectedCategory == LiftCategory.powerlifting ? powerliftingZoneColor : weightliftingColor;

  String get heroLabel => selectedCategory == LiftCategory.powerlifting ? 'Mean Velocity' : 'Peak Velocity';

  // mittaripalkki 0..1
  double get zoneGaugeValue {
    if (selectedCategory == LiftCategory.powerlifting) {
      return (meanVelocity / 1.5).clamp(0.0, 1.0);
    } else {
      return (peakVelocity / 2.6).clamp(0.0, 1.0);
    }
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (useMockData) {
        // Simulointilogiikka
        _t += 0.1;
        if (selectedCategory == LiftCategory.powerlifting) {
          final base = 0.45 + 0.22 * sin(_t * 0.85);
          final phase = (_t % 3.0) / 3.0;
          final stickingDip = (phase > 0.40 && phase < 0.62) ? -0.10 : 0.0;
          final noise = (_random.nextDouble() - 0.5) * 0.03;
          currentVelocity = max(0.0, base + stickingDip + noise);
        } else {
          final phase = (_t % 1.2);
          double v = 0.08;
          v += 0.9 * exp(-pow((phase - 0.28) / 0.11, 2).toDouble());
          v -= 0.25 * exp(-pow((phase - 0.46) / 0.07, 2).toDouble());
          v += 1.7 * exp(-pow((phase - 0.63) / 0.09, 2).toDouble());
          final noise = (_random.nextDouble() - 0.5) * 0.04;
          currentVelocity = max(0.0, v + noise);
        }
        _runSimulation();
      } else {
        fetchData();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bleSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  void _runSimulation() {
    setState(() {
      _x += 1.0;
      _velocitySpots.add(FlSpot(_x, currentVelocity));

      if (_velocitySpots.length > 140) {
        _velocitySpots.removeAt(0);
      }

      if (isRecording) {
        _setVelocities.add(currentVelocity);
        peakVelocity = _setVelocities.reduce((a, b) => a > b ? a : b);
        meanVelocity = _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
      }
    });
  }

  void _startSet() {
    setState(() {
      isRecording = true;
      _setVelocities.clear();
      peakVelocity = 0.0;
      meanVelocity = 0.0;
    });
  }

  void _stopSet() {
    setState(() {
      isRecording = false;
      if (_setVelocities.isNotEmpty) {
        peakVelocity = _setVelocities.reduce((a, b) => a > b ? a : b);
        meanVelocity = _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
      }
    });
  }

  void _resetSet() {
    setState(() {
      isRecording = false;
      _setVelocities.clear();
      peakVelocity = 0.0;
      meanVelocity = 0.0;
    });
  }

  Future<void> _scanBleDevices() async {
    setState(() {
      connectionStatus = 'BLE: skannataan...';
      _scanResults = [];
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      final results = await FlutterBluePlus.scanResults.first;
      await FlutterBluePlus.stopScan();

      setState(() {
        _scanResults = results.where((r) => r.device.platformName.trim().isNotEmpty).toList();
        connectionStatus = _scanResults.isEmpty
            ? 'BLE: ei laitteita'
            : 'BLE: valitse laite (${_scanResults.length})';
      });

      if (_scanResults.isNotEmpty && mounted) {
        await _showDevicePicker();
      }
    } catch (e) {
      await FlutterBluePlus.stopScan();
      setState(() => connectionStatus = 'BLE-virhe: $e');
    }
  }

  Future<void> fetchData() async {

    const String baseUrl = '10.0.2.2';

    try {
      final response = await http.get(Uri.parse('http://$baseUrl/vbt_project/get_data.php'));
      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          setState(() {
            currentVelocity = double.parse(data[0]['acc_x'].toString());
            _x += 1.0;
            _velocitySpots.add(FlSpot(_x, currentVelocity));
            if (_velocitySpots.length > 50) {
              _velocitySpots.removeAt(0);
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Haku epäonnistui: $e');
    }
  }

  Future<void> _showDevicePicker() async {
    await showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _scanResults.length,
            itemBuilder: (context, index) {
              final r = _scanResults[index];
              final name = r.device.platformName.trim().isEmpty ? '(nimetön laite)' : r.device.platformName;
              return ListTile(
                title: Text(name),
                subtitle: Text(r.device.remoteId.str),
                onTap: () async {
                  Navigator.pop(context);
                  await _connectToDevice(r.device);
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => connectionStatus = 'BLE: yhdistetään ${device.platformName}...');
    try {
      await _bleSub?.cancel();
      _bleSub = null;
      if (_device != null) {
        try { await _device!.disconnect(); } catch (_) {}
      }
      _device = device;
      final services = await _device!.discoverServices();
      _velocityChar = null;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.properties.notify) {
            _velocityChar = c;
            break;
          }
        }
        if (_velocityChar != null) break;
      }

      if (_velocityChar == null) {
        setState(() => connectionStatus = 'BLE: notify characteristic puuttuu');
        return;
      }

      await _velocityChar!.setNotifyValue(true);
      _bleSub = _velocityChar!.lastValueStream.listen((data) {
        final raw = utf8.decode(data, allowMalformed: true).trim();
        final parsed = double.tryParse(raw);
        if (parsed != null && mounted) {
          setState(() {
            currentVelocity = parsed;
            connectionStatus = 'BLE: yhdistetty (${_device?.platformName ?? "laite"})';
            if (isRecording) {
              _setVelocities.add(currentVelocity);
              peakVelocity = _setVelocities.reduce((a, b) => a > b ? a : b);
              meanVelocity = _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
            }
          });
        }
      });
      setState(() => connectionStatus = 'BLE: yhdistetty (${_device?.platformName ?? "laite"})');
    } catch (e) {
      setState(() => connectionStatus = 'BLE-virhe: $e');
    }
  }

  Future<void> _disconnectBle() async {
    await _bleSub?.cancel();
    _bleSub = null;
    if (_device != null) { await _device!.disconnect(); }
    setState(() => connectionStatus = 'BLE: ei yhdistetty');
  }

  @override
  Widget build(BuildContext context) {
    final bool isPowerlifting = selectedCategory == LiftCategory.powerlifting;
    final FlSpot? stickSpot = stickingPointSpot;
    final FlSpot? pSpot = peakSpot;

    return Scaffold(
      appBar: AppBar(title: const Text('Velocity Based Training')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 1. Graafialue
            Container(
              height: 300,
              margin: const EdgeInsets.all(16), 
              color: Colors.grey[900],
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 2.5,
                    gridData: const FlGridData(show: true),
                    titlesData: const FlTitlesData(
                      leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: true),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _velocitySpots,
                        isCurved: true,
                        color: heroColor,
                        barWidth: 3,
                        dotData: const FlDotData(show: false),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 2. Reaaliaikainen lukema 
            Text(
              'Nopeus: ${currentVelocity.toStringAsFixed(2)} m/s',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),

            // Lajivalinta
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SegmentedButton<LiftCategory>(
                segments: const [
                  ButtonSegment(value: LiftCategory.powerlifting, label: Text('Voimannosto'), icon: Icon(Icons.fitness_center)),
                  ButtonSegment(value: LiftCategory.weightlifting, label: Text('Painonnosto'), icon: Icon(Icons.bolt)),
                ],
                selected: {selectedCategory},
                onSelectionChanged: (newSelection) {
                  setState(() {
                    selectedCategory = newSelection.first;
                    valittuLiike = visibleLiikkeet.first;
                    _velocitySpots.clear();
                    _x = 0.0;
                    _setVelocities.clear();
                    peakVelocity = 0.0;
                    meanVelocity = 0.0;
                  });
                },
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text("valittu liike: $valittuLiike", style: const TextStyle(fontSize: 20, color: Colors.blueAccent)),
            ),

            Wrap(
              spacing: 8.0,
              children: visibleLiikkeet.map((yksiLiike) {
                final selected = valittuLiike == yksiLiike;
                return ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: selected ? (isPowerlifting ? Colors.lightBlue : Colors.green) : null,
                  ),
                  onPressed: () {
                    setState(() {
                      valittuLiike = yksiLiike;
                      _velocitySpots.clear();
                      _x = 0.0;
                    });
                  },
                  child: Text(yksiLiike),
                );
              }).toList(),
            ),

            const SizedBox(height: 8),
            Text(heroLabel, style: const TextStyle(fontSize: 14, color: Colors.white70)),
            Text(heroValue.toStringAsFixed(2), style: TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: heroColor, height: 1.0)),
            const Text('m/s', style: TextStyle(fontSize: 18, color: Colors.white70)),

            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(isPowerlifting ? 'ZONE: $powerliftingZone' : 'PEAK STATUS', style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 14,
                      value: zoneGaugeValue,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(heroColor),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0),
              child: Text(analysisText, textAlign: TextAlign.center, style: TextStyle(color: heroColor, fontSize: 16, fontWeight: FontWeight.w600)),
            ),

            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Velocity Loss: ${velocityLossPercent.toStringAsFixed(1)}% (tavoite ${targetVelocityLoss.toStringAsFixed(0)}%)', style: TextStyle(color: velocityLossColor)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 12,
                      value: (velocityLossPercent / targetVelocityLoss).clamp(0.0, 1.0),
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(velocityLossColor),
                    ),
                  ),
                  Text(velocityLossText, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),

            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: SizedBox(
                width: double.infinity,
                height: 64,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRecording ? Colors.redAccent : Colors.green,
                    textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => isRecording ? _stopSet() : _startSet(),
                  icon: Icon(isRecording ? Icons.stop : Icons.play_arrow),
                  label: Text(isRecording ? 'STOP SET' : 'START SET'),
                ),
              ),
            ),

            ElevatedButton(onPressed: _resetSet, child: const Text('Reset')),

            SwitchListTile(
              title: const Text('Käytä mock-dataa'),
              value: useMockData,
              onChanged: (value) => setState(() {
                useMockData = value;
                connectionStatus = value ? 'Mock data käytössä' : 'BLE: ei yhdistetty';
              }),
            ),
            Text(connectionStatus, style: const TextStyle(color: Colors.white70)),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(onPressed: useMockData ? null : _scanBleDevices, child: const Text('Scan BLE')),
                const SizedBox(width: 10),
                ElevatedButton(onPressed: useMockData ? null : _disconnectBle, child: const Text('Disconnect')),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}