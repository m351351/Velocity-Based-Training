import 'package:flutter/material.dart';
import 'package:flutter_application_1/models/exercise_model.dart';
import 'package:flutter_application_1/services/ble_service.dart';
import 'package:flutter_application_1/widgets/velocity_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  runApp(const VBTApp());
}

class VBTApp extends StatelessWidget {
  const VBTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VBT Pro',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.cyanAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
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

class _VBTPageState extends State<VBTPage> {
  final BLEService _bleService = BLEService();


  final AudioPlayer _audioPlayer = AudioPlayer(); // Äänisoitin
  int _repCount = 0;// Toistolaskuri



  ExerciseTarget _currentExercise = exerciseData["Takakyykky"]!;

  List<FlSpot> _spots = [];
  double _currentVelocity = 0.0;
  double _xValue = 0.0;
  bool _isRecording = false;
  bool _isConnected = false;
  int _batteryLevel = 0;
  
  double _peakOfRep = 0.0;     // Toiston korkein nopeus
  double _meanOfRep = 0.0;     // Toiston keskinopeus
  List<double> _repSamples = []; // Tämän hetkisen toiston kaikki näytteet

  @override
  void initState() {
    super.initState();

  _bleService.velocityStream.listen((velocity) {
    if (mounted) {
      setState(() {
        _currentVelocity = velocity;

        if (_isRecording) {
          _xValue += 1;
          _spots.add(FlSpot(_xValue, velocity));

          if (velocity > 0.12) {
            _repSamples.add(velocity);
            if (velocity > _peakOfRep) _peakOfRep = velocity;
          }
          else if (velocity <= 0.05 && _repSamples.length >= 5) {
          
          // TARKISTUS: Hyväksytään vain, jos huipun nopeus oli riittävä
          if (_peakOfRep >= 0.20) {
            _meanOfRep = _repSamples.reduce((a, b) => a + b) / _repSamples.length;
            _repCount++;
            _audioPlayer.play(AssetSource('beep.mp3'));
          }
          _repSamples.clear();
          _peakOfRep = 0; // Tärkeää nollata huippu toiston jälkeen
        } 
        else if (velocity <= 0.05) {
          _repSamples.clear();
          _peakOfRep = 0;
        }
      }
      });
    }
  });

    _bleService.batteryStream.listen((level) {
  if (mounted) {
    setState(() => _batteryLevel = level);
  }
  });
  }

  // APUFUNKTIO VÄRILLE
  Color _getHeroColor() {
    double valueToCompare = (_currentExercise.id == 0 || _currentExercise.id >= 4) 
        ? _peakOfRep 
        : _meanOfRep;

    // Jos ollaan liikkeessä, käytetään reaaliaikaista väriä, muuten viimeisintä tulosta
    if (_currentVelocity > 0.1) valueToCompare = _currentVelocity;

    if (valueToCompare == 0) return Colors.white;
    if (valueToCompare < _currentExercise.minTarget) return Colors.redAccent;
    if (valueToCompare > _currentExercise.maxTarget) return Colors.blueAccent;
    return Colors.greenAccent;
  }

  Future<void> _handleConnect() async {
    setState(() => _isConnected = false);
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      if (mounted) _showDevicePicker();
    } catch (e) {
      debugPrint("Skannausvirhe: $e");
    }
  }

  void _showDevicePicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StreamBuilder<List<ScanResult>>(
          stream: FlutterBluePlus.scanResults,
          initialData: const [],
          builder: (context, snapshot) {
            final results = snapshot.data ?? [];
            final filteredResults = results.where((r) => r.device.platformName.isNotEmpty).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text("Valitse VBT-Sensori", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                if (filteredResults.isEmpty) const Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator()),
                Expanded(
                  child: ListView.builder(
                    itemCount: filteredResults.length,
                    itemBuilder: (context, index) {
                      final r = filteredResults[index];
                      return ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(r.device.platformName),
                        onTap: () async {
                          Navigator.pop(context);
                          await FlutterBluePlus.stopScan();
                          await _bleService.connect(r.device);
                          if (mounted) setState(() => _isConnected = true);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleDisconnect() {
    _bleService.device?.disconnect();
    setState(() {
      _isConnected = false;
      _batteryLevel = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Lasketaan näytettävä arvo
    String displayValue = _currentVelocity.toStringAsFixed(2);
    if (_currentVelocity < 0.1 && (_peakOfRep > 0 || _meanOfRep > 0)) {
      displayValue = (_currentExercise.id == 0 || _currentExercise.id >= 4)
          ? _peakOfRep.toStringAsFixed(2)
          : _meanOfRep.toStringAsFixed(2);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("VBT ANALYZER"),
        actions: [
          if (_isConnected) 
            Center(child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: Text("$_batteryLevel%", style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
            )),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(_isConnected ? Icons.bluetooth_connected : Icons.bluetooth),
                    label: Text(_isConnected ? "YHDISTETTY" : "YHDISTÄ"),
                    onPressed: _isConnected ? null : _handleConnect,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.bluetooth_disabled, color: Colors.redAccent),
                  onPressed: _isConnected ? _handleDisconnect : null,
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _currentExercise.name,
                  isExpanded: true,
                  items: exerciseData.keys.map((String key) {
                    return DropdownMenuItem<String>(value: key, child: Text(key));
                  }).toList(),
                  onChanged: (String? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _currentExercise = exerciseData[newValue]!;
                        _bleService.sendExercise(_currentExercise.id);
                        // Nollataan edellisen liikkeen huiput
                        _peakOfRep = 0;
                        _meanOfRep = 0;
                      });
                    }
                  },
                ),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // --- TÄSSÄ ON UUSI LASKURI ---
                  Text(
                    "REPS: $_repCount",
                    style: const TextStyle(
                      fontSize: 30, 
                      color: Colors.cyanAccent, 
                      fontWeight: FontWeight.bold
                    ),
                  ),
                  const SizedBox(height: 10), // Pieni väli laskurin ja nopeuden välissä
                  
                  Text(
                    displayValue,
                    style: TextStyle(
                      fontSize: 100, 
                      fontWeight: FontWeight.bold,
                      color: _getHeroColor(),
                    ),
                  ),
                  Text(
                    (_currentExercise.id == 0 || _currentExercise.id >= 4) 
                        ? "PEAK VELOCITY (m/s)" 
                        : "MEAN VELOCITY (m/s)",
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: VelocityChart(
                spots: _spots,
                maxY: _currentExercise.maxY,
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                height: 70,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.redAccent : Colors.green,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    setState(() {
                      if (!_isRecording) {
                        _spots.clear();
                        _xValue = 0;
                        _peakOfRep = 0; // NOLLAUS UUDELLE SARJALLE
                        _meanOfRep = 0;
                        _repCount = 0;
                        _repSamples.clear();
                      }
                      _isRecording = !_isRecording;
                    });
                  },
                  child: Text(
                    _isRecording ? "LOPETA SARJA" : "ALOITA SARJA",
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _bleService.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}