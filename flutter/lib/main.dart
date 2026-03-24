import 'package:flutter/material.dart';
import 'dart:async';
// Bluetooth-kirjasto, otetaan käyttöön myöhemmin
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';

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
  final List<double> _setVelocities = []; // tallennetaan jokaisen sarjan nopeudet analyysiä varten
  double peakVelocity = 0.0; // tallennetaan sarjan huippunopeus analyysiä varten
  double meanVelocity = 0.0; // tallennetaan sarjan keskimääräinen nopeus analyysiä varten

  bool useMockData = true;
  String connectionStatus = 'BLE: ei yhdistetty';

  BluetoothDevice? _device;
  BluetoothCharacteristic? _velocityChar;
  StreamSubscription<List<int>>? _bleSub;

  // löydetyt BLE-laitteet käyttäjän valintaa varten
  List<ScanResult> _scanResults = [];

  final List<FlSpot> _velocitySpots = []; // Graafipisteet kiihtyvyysdatasta
  double _x = 0.0; // ajan kulumista simuloiva muuttuja graafia varten

  String get analysisText {
    if (isRecording) return 'Analyysi: Sarja käynnissä...';
    if (_setVelocities.isEmpty) return 'Analyysi: Odota suoritusta...';

    if (meanVelocity >= 1.3) return 'Analyysi: Nopeusvoima-alue (kevyt kuorma)';
    if (meanVelocity >= 0.9) return 'Analyysi: Voima-nopeusalue (keskikuorma)';
    if (meanVelocity >= 0.6) return 'Analyysi: Maksimivoima-alue (raskas kuorma)';
    return 'Analyysi: Hyvin raskas / väsymys, tarkista tekniikka';
  }

  String valittuLiike = "ei valittu";
  final List<String> liikkeet = [
    "Tempaus",
    "Rinnalleveto",
    "Rinnalleveto + työntö",
    "Maastaveto",
    "Takakyykky",
    "Penkkipunnerrus"
  ];

  double currentVelocity = 0.0;
  Timer? _timer;
  double _t = 0.0; // simulointia varten "aika"
  final Random _random = Random();

  // Tässä mock-datalla simuloidaan kiihtyvyysanturin dataa
  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() {
        _t += 0.1; // Simuloidaan ajan kulumista

        if (useMockData) {
          final base = 0.9 + 0.6 * sin(_t);
          final noise = (_random.nextDouble() - 0.5) * 0.08;
          currentVelocity = max(0.0, base + noise);
        } else {
          // BLE-data tulee notify-streamistä _connectToDevice()-metodissa
          // pidetään currentVelocity ennallaan tässä loopissa
        }

        _x += 1.0;
        _velocitySpots.add(FlSpot(_x, currentVelocity));

        if (_velocitySpots.length > 100) {
          _velocitySpots.removeAt(0); // graafin skaalaus viimeiseen 100 pisteeseen
        }

        if (isRecording) {
          _setVelocities.add(currentVelocity);
        }
      });
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
        meanVelocity =
            _setVelocities.reduce((a, b) => a + b) / _setVelocities.length;
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
    setState(() {
      connectionStatus = 'BLE: skannataan...';
      _scanResults = [];
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      final results = await FlutterBluePlus.scanResults.first;
      await FlutterBluePlus.stopScan();

      setState(() {
        _scanResults = results
            .where((r) => r.device.platformName.trim().isNotEmpty)
            .toList();

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
              final name = r.device.platformName.trim().isEmpty
                  ? '(nimetön laite)'
                  : r.device.platformName;
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
      // varmuuden vuoksi vanha yhteys pois
      await _bleSub?.cancel();
      _bleSub = null;

      if (_device != null) {
        try {
          await _device!.disconnect();
        } catch (_) {}
      }

      _device = device;
      await _device!.connect(timeout: const Duration(seconds: 8));

      final services = await _device!.discoverServices();

      // TODO: vaihda oikeaan characteristiciin (notify)
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
        // Odotetaan tässä vaiheessa ASCII-muotoa, esim "1.23"
        final raw = utf8.decode(data, allowMalformed: true).trim();
        final parsed = double.tryParse(raw);

        if (parsed != null && mounted) {
          setState(() {
            currentVelocity = parsed;
            connectionStatus = 'BLE: yhdistetty (${_device?.platformName ?? "laite"})';
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

  Future<void> _disconnectBle() async {
    await _bleSub?.cancel();
    _bleSub = null;

    if (_device != null) {
      await _device!.disconnect();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Velocity Based Training'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 1. Graafialue (tähän tulee fl_chart myöhemmin)
            Container(
              height: 300,
              margin: const EdgeInsets.all(16),
              color: Colors.grey[900],
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 2.0,
                    gridData: const FlGridData(show: true),
                    titlesData: const FlTitlesData(
                      leftTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: true)),
                      bottomTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: true),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _velocitySpots,
                        isCurved: true,
                        color: Colors.greenAccent,
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

            // 3. VBT-analyysi (esim. voimaa kehittävä) [cite: 35, 36]
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                analysisText,
                style: const TextStyle(color: Colors.greenAccent, fontSize: 18),
              ),
            ),

            // 4. Setin hallinta
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _startSet,
                  child: const Text('Start Set'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _stopSet,
                  child: const Text('Stop Set'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _resetSet,
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              isRecording ? 'SETTI KÄYNNISSÄ' : 'SETTI EI KÄYNNISSÄ',
              style: TextStyle(
                color: isRecording ? Colors.orangeAccent : Colors.grey,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Peak: ${peakVelocity.toStringAsFixed(2)} m/s   Mean: ${meanVelocity.toStringAsFixed(2)} m/s',
              style: const TextStyle(fontSize: 16, color: Colors.white70),
            ),

            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Käytä mock-dataa'),
              value: useMockData,
              onChanged: (value) {
                setState(() {
                  useMockData = value;
                  connectionStatus = value ? 'Mock data käytössä' : 'BLE: ei yhdistetty';
                });
              },
            ),
            Text(
              connectionStatus,
              style: const TextStyle(color: Colors.white70),
            ),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: useMockData ? null : _scanBleDevices,
                  child: const Text('Scan BLE'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: useMockData ? null : _disconnectBle,
                  child: const Text('Disconnect'),
                ),
              ],
            ),

            // TÄSSÄ NAPPULAT LIIKKEIDEN VALINTAAN -meri 190326
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                "valittu liike: $valittuLiike",
                style: const TextStyle(fontSize: 20, color: Colors.blueAccent),
              ),
            ),

            Wrap(
              spacing: 8.0,
              children: liikkeet.map((yksiLiike) {
                return ElevatedButton(
                  onPressed: () {
                    setState(() {
                      valittuLiike = yksiLiike;
                    });
                  },
                  child: Text(yksiLiike),
                );
              }).toList(),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}