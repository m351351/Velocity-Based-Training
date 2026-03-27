import 'package:flutter/material.dart';
import 'dart:async';
// Bluetooth-kirjasto, otetaan käyttöön myöhemmin
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

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
      theme: ThemeData.dark(), // Tumma teema kuntosaliympäristöön [cite: 40]
      home: const VBTPage(),
      debugShowCheckedModeBanner: false,
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

  bool useMockData = true;
  String connectionStatus = 'Mock data käytössä';

  BluetoothDevice? _device;
  BluetoothCharacteristic? _velocityChar;
  StreamSubscription<List<int>>? _bleSub;
  static const String kServiceUuid = "12345678-1234-1234-1234-123456789abc";
  static const String kCharUuid = "abcd1234-ab12-ab12-ab12-abcdef123456";

  // scan-stabilointi (status=6 estoon)
  bool _isScanning = false;
  DateTime? _lastScanAt;

  // löydetyt BLE-laitteet käyttäjän valintaa varten
  List<ScanResult> _scanResults = [];

  final List<FlSpot> _velocitySpots = []; // graafipisteet
  double _x = 0.0; // ajan kulumista simuloiva muuttuja graafia varten

  // Lajivalinta + liikevalinta
  LiftCategory selectedCategory = LiftCategory.powerlifting;
  String valittuLiike = "Takakyykky";

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

  double currentVelocity = 0.0;
  Timer? _timer;
  double _t = 0.0; // simulointia varten "aika"
  final Random _random = Random();

  // käyttäjän asettama tavoite velocity lossille
  double targetVelocityLoss = 20.0;

  // smoothing painonnostolle (poistaa neulamaista sahanterää)
  final List<double> _smoothingBuffer = [];
  double _smooth(double raw, {int window = 5}) {
    _smoothingBuffer.add(raw);
    if (_smoothingBuffer.length > window) {
      _smoothingBuffer.removeAt(0);
    }
    final sum = _smoothingBuffer.fold(0.0, (a, b) => a + b);
    return sum / _smoothingBuffer.length;
  }

  // JSON BLE -> velocity laskenta
  DateTime? _lastSampleTime;
  double _velocityFromAcc = 0.0;

  double _computeVelocityFromJson(Map<String, dynamic> j) {
    final ax = (j['ax'] as num?)?.toDouble() ?? 0.0;
    final ay = (j['ay'] as num?)?.toDouble() ?? 0.0;
    final az = (j['az'] as num?)?.toDouble() ?? 9.81;

    // poistetaan gravitaatio z-akselilta
    final azNet = az - 9.81;
    final totalAcc = sqrt(ax * ax + ay * ay + azNet * azNet); // m/s^2

    final now = DateTime.now();
    final dt = _lastSampleTime == null
        ? 0.02
        : (now.difference(_lastSampleTime!).inMilliseconds / 1000.0).clamp(0.001, 0.2);
    _lastSampleTime = now;

    // integrointi
    _velocityFromAcc += totalAcc * dt;

    // kevyt damping, ettei drifti karkaa
    _velocityFromAcc *= 0.98;

    return _velocityFromAcc;
  }

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

  Color get powerliftingZoneColor {
    final v = meanVelocity;
    if (v > 1.3) return const Color(0xFF4FC3F7); // kirkas sininen
    if (v >= 0.75) return const Color(0xFF00E676); // vihreä
    if (v >= 0.5) return const Color(0xFFFFB300); // keltainen/oranssi
    return const Color(0xFFFF5252); // punainen
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

  Color get weightliftingColor {
    final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
    final v = peakVelocity;
    if (v < min) return const Color(0xFFFF5252);
    if (v >= optLow && v <= optHigh) return const Color(0xFF00E676);
    if (v > optHigh) return const Color(0xFF4FC3F7);
    return const Color(0xFFFFB300);
  }

  // Voimannostossa seurataan velocity lossia
  double get velocityLossPercent {
    if (_setVelocities.length < 2) return 0.0;
    final best = _setVelocities.reduce((a, b) => a > b ? a : b);
    final latest = _setVelocities.last;
    if (best <= 0) return 0.0;
    return ((best - latest) / best) * 100.0;
  }

  Color get velocityLossColor {
    final vl = velocityLossPercent;
    if (vl <= 20) return const Color(0xFF00E676);
    if (vl <= 40) return const Color(0xFFFFB300);
    return const Color(0xFFFF5252);
  }

  String get analysisText {
    if (_setVelocities.isEmpty) return 'Odottaa sarjaa';
    if (selectedCategory == LiftCategory.powerlifting) {
      return 'Zone: $powerliftingZone';
    } else {
      final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
      if (peakVelocity < min) return 'Peak alle minimin';
      if (peakVelocity >= optLow && peakVelocity <= optHigh) return 'Peak optimaalisella alueella';
      if (peakVelocity > optHigh) return 'Peak yli optimaalisen';
      return 'Peak minimin yli';
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
        HorizontalLine(y: 0.5, color: Colors.redAccent.withOpacity(0.30), strokeWidth: 1),
        HorizontalLine(y: 0.75, color: Colors.amberAccent.withOpacity(0.30), strokeWidth: 1),
        HorizontalLine(y: 1.0, color: Colors.greenAccent.withOpacity(0.30), strokeWidth: 1),
      ];
    } else {
      final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
      return [
        HorizontalLine(y: min, color: Colors.redAccent.withOpacity(0.30), strokeWidth: 1),
        HorizontalLine(y: optLow, color: Colors.amberAccent.withOpacity(0.30), strokeWidth: 1),
        HorizontalLine(y: optHigh, color: Colors.greenAccent.withOpacity(0.30), strokeWidth: 1),
      ];
    }
  }

  List<HorizontalRangeAnnotation> get zoneBackgroundRanges {
    if (selectedCategory == LiftCategory.powerlifting) {
      return [
        HorizontalRangeAnnotation(y1: 0.0, y2: 0.5, color: const Color(0x22FF5252)),
        HorizontalRangeAnnotation(y1: 0.5, y2: 0.75, color: const Color(0x22FFB300)),
        HorizontalRangeAnnotation(y1: 0.75, y2: 1.0, color: const Color(0x2200E676)),
        HorizontalRangeAnnotation(y1: 1.0, y2: 1.5, color: const Color(0x224FC3F7)),
      ];
    } else {
      final (min, optLow, optHigh) = _wlThresholds(valittuLiike);
      return [
        HorizontalRangeAnnotation(y1: 0.0, y2: min, color: const Color(0x22FF5252)),
        HorizontalRangeAnnotation(y1: min, y2: optLow, color: const Color(0x22FFB300)),
        HorizontalRangeAnnotation(y1: optLow, y2: optHigh, color: const Color(0x2200E676)),
        HorizontalRangeAnnotation(y1: optHigh, y2: 2.6, color: const Color(0x224FC3F7)),
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

  // Tässä mock-datalla simuloidaan kiihtyvyysanturin dataa
  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() {
        _t += 0.1; // Simuloidaan ajan kulumista

        if (useMockData) {
          if (selectedCategory == LiftCategory.powerlifting) {
            // Voimannosto: "The Grind Curve", mukana keskialueen notkahdus
            final base = 0.45 + 0.22 * sin(_t * 0.85);
            final phase = (_t % 3.0) / 3.0; // 0..1
            final stickingDip = (phase > 0.40 && phase < 0.62) ? -0.10 : 0.0;
            final noise = (_random.nextDouble() - 0.5) * 0.03;
            currentVelocity = max(0.0, base + stickingDip + noise);
          } else {
            // Painonnosto: "The Double Peak"
            final phase = (_t % 1.2); // lyhyt sykli
            double v = 0.08;
            v += 0.9 * exp(-pow((phase - 0.28) / 0.11, 2).toDouble()); // 1st pull
            v -= 0.25 * exp(-pow((phase - 0.46) / 0.07, 2).toDouble()); // transition
            v += 1.7 * exp(-pow((phase - 0.63) / 0.09, 2).toDouble()); // 2nd pull
            final noise = (_random.nextDouble() - 0.5) * 0.04;
            currentVelocity = max(0.0, _smooth(v + noise)); // smoothing vain painonnostolle
          }
        }

        // GATING: graafiin lisätään pisteitä vain kun setti käy
        if (isRecording) {
          _x += 1.0;
          _velocitySpots.add(FlSpot(_x, currentVelocity));
          if (_velocitySpots.length > 120) {
            _velocitySpots.removeAt(0); // graafin skaalaus viimeisiin pisteisiin
          }

          _setVelocities.add(currentVelocity);
          peakVelocity = _setVelocities.reduce((a, b) => a > b ? a : b);
          meanVelocity = _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
        }
      });
    });
  }

  void _startSet() {
    setState(() {
      isRecording = true;

      // START tyhjentää sarjan datan + graafin, ettei vanha kohina kummittele
      _setVelocities.clear();
      _velocitySpots.clear();
      _x = 0.0;
      _smoothingBuffer.clear();

      // nollataan myös JSON-integraattori uuden setin alussa
      _lastSampleTime = null;
      _velocityFromAcc = 0.0;

      peakVelocity = 0.0;
      meanVelocity = 0.0;
    });
  }

  void _stopSet() {
    setState(() {
      isRecording = false;
      // STOP jättää viimeisen sarjan graafin näkyviin analyysiä varten
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
      _velocitySpots.clear();
      _x = 0.0;
      _smoothingBuffer.clear();
      _lastSampleTime = null;
      _velocityFromAcc = 0.0;
    });
  }

  // Tänne tulee myöhemmin kiihtyvyysanturin data [cite: 25, 76]

/* //TÄMÄ PÄÄLLE KUN HALUTAAN KÄYTTÄÄ KÄYTTÖLIITTYMÄÄ PUHELIMELLA, POIS PÄÄLTÄ JOS KEHITYS KONEELLA -meri 190326
  @override
  void initState() {
    super.initState();

    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      if (state == BluetoothAdapterState.on) {
        debugPrint("Bluetooth on päällä ja valmis VBT-laitteen hakuun.");
      } else {
        debugPrint("Bluetooth on pois päältä, tarttis varmaan tehdä jotain");
      }
    });
  }
*/

  Future<void> _scanBleDevices() async {
    if (_isScanning) return;

    // estää napin hakkaamisen -> Android status=6
    if (_lastScanAt != null &&
        DateTime.now().difference(_lastScanAt!) < const Duration(seconds: 2)) {
      setState(() => connectionStatus = 'BLE: odota hetki ennen uutta skannausta');
      return;
    }

    // Android 10 vaatii location-oikeuden BLE-skannaukseen
    if (Platform.isAndroid) {
      final locationStatus = await Permission.location.request();
      final bluetoothStatus = await Permission.bluetooth.request();

      // Android 12+ lisäoikeudet
      final scanStatus = await Permission.bluetoothScan.request();
      final connectStatus = await Permission.bluetoothConnect.request();

      if (!locationStatus.isGranted ||
          !bluetoothStatus.isGranted ||
          !scanStatus.isGranted ||
          !connectStatus.isGranted) {
        setState(() => connectionStatus = 'BLE: oikeudet puuttuu');
        return;
      }
    }

    setState(() {
      _isScanning = true;
      connectionStatus = 'BLE: skannataan...';
      _scanResults = [];
    });

    StreamSubscription<List<ScanResult>>? sub;

    try {
      // varmistus ettei vanha scan ole jäänyt päälle
      await FlutterBluePlus.stopScan();
      await Future.delayed(const Duration(milliseconds: 200));

      sub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          _scanResults = results
              .where((r) => r.device.platformName.trim().isNotEmpty)
              .toList();
        });
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        androidUsesFineLocation: true, // tärkeä Android 10:lle
      );

      // odotetaan timeoutin verran
      await Future.delayed(const Duration(seconds: 4));

      await FlutterBluePlus.stopScan();
      await sub.cancel();

      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _lastScanAt = DateTime.now();
        connectionStatus = _scanResults.isEmpty
            ? 'BLE: ei laitteita'
            : 'BLE: valitse laite (${_scanResults.length})';
      });

      if (_scanResults.isNotEmpty && mounted) {
        await _showDevicePicker();
      }
    } catch (e) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub?.cancel();

      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _lastScanAt = DateTime.now();
        connectionStatus = 'BLE-virhe: $e';
      });
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
        try {
          await _device!.disconnect();
        } catch (_) {}
      }

      _device = device;

      // TÄRKEÄ: oikea connect
      await _device!.connect(timeout: const Duration(seconds: 10));

      // pieni viive ennen service discoveryä
      await Future.delayed(const Duration(milliseconds: 300));

      final services = await _device!.discoverServices();

      _velocityChar = null;
      for (final s in services) {
        if (s.uuid.str.toLowerCase() == kServiceUuid.toLowerCase()) {
          for (final c in s.characteristics) {
            if (c.uuid.str.toLowerCase() == kCharUuid.toLowerCase()) {
              _velocityChar = c;
              break;
            }
          }
        }
        if (_velocityChar != null) break;
      }

      if (_velocityChar == null) {
        setState(() => connectionStatus = 'BLE: oikea characteristic puuttuu');
        return;
      }

      await _velocityChar!.setNotifyValue(true);

      _bleSub = _velocityChar!.onValueReceived.listen((data) {
        final raw = utf8.decode(data, allowMalformed: true).trim();

        // Korvaa JSON-parsinta tällä
        final parsed = double.tryParse(raw);
        if (parsed != null && mounted) {
          setState(() {
            currentVelocity = parsed.clamp(0.0, 3.0).toDouble();
            connectionStatus = 'BLE: yhdistetty (${_device?.platformName ?? "laite"})';

            if (isRecording) {
              _x += 1.0;
              final v = selectedCategory == LiftCategory.weightlifting
                  ? _smooth(currentVelocity)
                  : currentVelocity;

              _velocitySpots.add(FlSpot(_x, v));
              if (_velocitySpots.length > 120) {
                _velocitySpots.removeAt(0);
              }

              _setVelocities.add(v);
              peakVelocity = _setVelocities.reduce((a, b) => a > b ? a : b);
              meanVelocity = _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
            }
          });
        }
      });

      setState(() {
        connectionStatus = 'BLE: yhdistetty (${_device?.platformName ?? "laite"})';
      });
    } catch (e) {
      setState(() => connectionStatus = 'BLE-virhe: $e');
    }
  }

  // (valinnainen mutta suositeltava) _disconnectBle() turvallisemmaksi:
  Future<void> _disconnectBle() async {
    await _bleSub?.cancel();
    _bleSub = null;

    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }

    setState(() {
      connectionStatus = 'BLE: ei yhdistetty';
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bleSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _pickLift() async {
    final items = visibleLiikkeet;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: items.map((liike) {
              final selected = liike == valittuLiike;
              return ListTile(
                title: Text(liike),
                trailing: selected ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, liike),
              );
            }).toList(),
          ),
        );
      },
    );

    if (chosen != null) {
      setState(() {
        valittuLiike = chosen;
        _velocitySpots.clear();
        _x = 0.0;
        _smoothingBuffer.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isPowerlifting = selectedCategory == LiftCategory.powerlifting;
    final FlSpot? stickSpot = stickingPointSpot;
    final FlSpot? pSpot = peakSpot;
    final List<FlSpot> safeSpots = _velocitySpots.isEmpty ? const [FlSpot(0, 0)] : _velocitySpots;

    final bool lossOverLimit = velocityLossPercent > targetVelocityLoss;
    final Color lineColor = isPowerlifting ? Colors.cyanAccent : Colors.white;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              heroColor.withOpacity(0.18),
              Colors.black,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // A) Yläosa: lajitabit
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: SegmentedButton<LiftCategory>(
                  segments: const [
                    ButtonSegment(
                      value: LiftCategory.powerlifting,
                      label: Text('VOIMA'),
                    ),
                    ButtonSegment(
                      value: LiftCategory.weightlifting,
                      label: Text('PAINO'),
                    ),
                  ],
                  selected: {selectedCategory},
                  onSelectionChanged: (newSelection) {
                    setState(() {
                      selectedCategory = newSelection.first;
                      valittuLiike = visibleLiikkeet.first;
                      _velocitySpots.clear();
                      _x = 0.0;
                      _setVelocities.clear();
                      _smoothingBuffer.clear();
                      peakVelocity = 0.0;
                      meanVelocity = 0.0;
                    });
                  },
                ),
              ),

              // Liikevalinta tekstinä + modal
              InkWell(
                onTap: _pickLift,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        valittuLiike,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.expand_more),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 6),

              // B) Keskiosa: sankarinumero
              Text(
                heroLabel,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
              Text(
                heroValue.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 92,
                  fontWeight: FontWeight.w900,
                  color: heroColor,
                  height: 0.95,
                ),
              ),
              const Text(
                'm/s',
                style: TextStyle(fontSize: 18, color: Colors.white70),
              ),

              const SizedBox(height: 8),

              // Zone/gauge
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isPowerlifting ? 'ZONE: $powerliftingZone' : analysisText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
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

              const SizedBox(height: 10),

              // C) Alaosa: matalampi graafi
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: isPowerlifting ? 1.5 : 2.6,
                      gridData: const FlGridData(show: false),
                      extraLinesData: ExtraLinesData(horizontalLines: zoneLines),
                      rangeAnnotations: RangeAnnotations(
                        horizontalRangeAnnotations: zoneBackgroundRanges,
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: isPowerlifting ? 0.5 : 1.0,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                value.toStringAsFixed(1),
                                style: const TextStyle(fontSize: 10, color: Colors.white70),
                              );
                            },
                          ),
                        ),
                        bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      lineBarsData: [
                        LineChartBarData(
                          spots: safeSpots,
                          isCurved: true, // pehmennetty viiva
                          curveSmoothness: 0.28,
                          color: lineColor,
                          barWidth: 4,
                          dotData: FlDotData(
                            show: true,
                            checkToShowDot: (spot, barData) {
                              if (isPowerlifting && stickSpot != null) {
                                return spot.x == stickSpot.x && spot.y == stickSpot.y;
                              }
                              if (!isPowerlifting && pSpot != null) {
                                return spot.x == pSpot.x && spot.y == pSpot.y;
                              }
                              return false;
                            },
                            getDotPainter: (spot, percent, bar, index) {
                              final bool isStick =
                                  isPowerlifting && stickSpot != null && spot.x == stickSpot.x && spot.y == stickSpot.y;
                              return FlDotCirclePainter(
                                radius: 5,
                                color: isStick ? Colors.redAccent : Colors.white,
                                strokeColor: Colors.black,
                                strokeWidth: 1.5,
                              );
                            },
                          ),
                          belowBarData: BarAreaData(
                            show: safeSpots.length >= 2,
                            color: lineColor.withOpacity(0.08),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              if (isPowerlifting && stickSpot != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Sticking point: ${stickSpot.y.toStringAsFixed(2)} m/s',
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 13),
                  ),
                ),
              if (!isPowerlifting && pSpot != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Peak point: ${pSpot.y.toStringAsFixed(2)} m/s',
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 13),
                  ),
                ),

              // Loss-rivi
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Loss: ${velocityLossPercent.toStringAsFixed(1)}%',
                        style: TextStyle(color: velocityLossColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.6, end: lossOverLimit ? 1.0 : 0.85),
                        duration: const Duration(milliseconds: 550),
                        curve: Curves.easeInOut,
                        builder: (context, opacity, child) {
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: lossOverLimit
                                  ? Colors.red.withOpacity(0.15 * opacity)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: child,
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            minHeight: 10,
                            value: (velocityLossPercent / targetVelocityLoss).clamp(0.0, 1.0),
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation<Color>(velocityLossColor),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Kevyt BLE-paneeli (minimal mutta käytännöllinen)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bluetooth, size: 18, color: Colors.white70),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            connectionStatus,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            const Text('Mock', style: TextStyle(fontSize: 12)),
                            Switch(
                              value: useMockData,
                              onChanged: (value) {
                                setState(() {
                                  useMockData = value;
                                  if (value) {
                                    connectionStatus = 'Mock data käytössä';
                                  } else {
                                    connectionStatus = 'BLE: ei yhdistetty';
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (!useMockData)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _isScanning ? null : _scanBleDevices,
                              child: Text(_isScanning ? 'Scanning...' : 'Scan'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _disconnectBle,
                              child: const Text('Disconnect'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // Jättinappi alareunaan
              SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isRecording ? Colors.redAccent : Colors.green,
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    ),
                    onPressed: () {
                      if (isRecording) {
                        _stopSet();
                      } else {
                        _startSet();
                      }
                    },
                    child: Text(
                      isRecording ? 'STOP SET' : 'START SET',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}