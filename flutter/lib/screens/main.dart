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

  Color _scaffoldBgColor = const Color(0xFF121212); // Oletus musta

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

  int _goodReps = 0;   
  int _fastReps = 0;   
  int _slowReps = 0;
  List<String> _sessionFeedbacks = []; // Tallentaa jokaisen toiston sanallisen palautteen
  List<double> _repValues = []; // Tallentaa jokaisen toiston nopeuden (m/s)

  String _lastFeedbackText = "Valmis sarjaan";




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

          if (velocity > 0.18) {
            _repSamples.add(velocity);
            if (velocity > _peakOfRep) _peakOfRep = velocity;
          }
          else if (velocity <= 0.03 && _repSamples.length >= 10) {
          
          // TARKISTUS: Hyväksytään vain, jos huipun nopeus oli riittävä
          if (_peakOfRep >= 0.25) {
            _meanOfRep = _repSamples.reduce((a, b) => a + b) / _repSamples.length;
            _repCount++;

            String currentFeedback = "";

              // Valitaan vertailuarvo: Painonnosto (ID 0, 4, 5) -> Peak, muut -> Mean
              double velocityToJudge = (_currentExercise.id == 0 || _currentExercise.id >= 4) 
                  ? _peakOfRep 
                  : _meanOfRep;

              // A. TAKAKYYKKY JA MUUT VOIMAVERTAILUT (Mean Velocity)
            if (_currentExercise.id >= 1 && _currentExercise.id <= 3) {
                          if (velocityToJudge > 1.3) {
                            currentFeedback = "Räjähtävä aloitus! (0–30% 1RM)";
                            _fastReps++;
                          } else if (velocityToJudge >= 1.0) {
                            currentFeedback = "Nopeusvoima-alue (30–50% 1RM)";
                            _goodReps++;
                          } else if (velocityToJudge >= 0.75) {
                            currentFeedback = "Voimanopeus (50–70% 1RM)";
                            _goodReps++;
                          } else if (velocityToJudge >= 0.5) {
                            currentFeedback = "Raskas perusvoimasarja (70–85% 1RM)";
                            _goodReps++;
                          } else {
                            currentFeedback = "Maksimivoima-alue! (85–100% 1RM)";
                            _slowReps++;
                          }
                        } 
                        // 2. PAINONNOSTOLIIKKEET (Tempaus, Rinnalleveto, Työntö)
                        else {
                          if (_currentExercise.name == "Tempaus") {
                            currentFeedback = velocityToJudge >= 1.85 ? "Täydellinen räjähdys!" : "Hidas kakkosveto!";
                          } else {
                            currentFeedback = velocityToJudge >= 1.45 ? "Hyvä räjähdys!" : "Hidas kakkosveto!";
                          }
                          _goodReps++; 
                        }

              setState(() {
                _lastFeedbackText = currentFeedback; // Päivitetään teksti ensin
                _sessionFeedbacks.add(currentFeedback);
                _repValues.add(velocityToJudge);
              });

              _audioPlayer.play(AssetSource('beep.mp3'));
              _triggerFlash();
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

  void _triggerFlash() {
    // Valitaan vertailuarvo liikkeen mukaan
    double valueToCompare = (_currentExercise.id == 0 || _currentExercise.id >= 4) 
        ? _peakOfRep 
        : _meanOfRep;

    setState(() {
      if (valueToCompare < _currentExercise.minTarget) {
        _scaffoldBgColor = Colors.redAccent.withValues(alpha: 0.3); // Liian hidas
      } else if (valueToCompare > _currentExercise.maxTarget) {
        _scaffoldBgColor = const Color.fromARGB(255, 224, 175, 42).withValues(alpha: 0.3); // Liian nopea / kevyt
      } else {
        _scaffoldBgColor = const Color.fromARGB(255, 59, 179, 4).withValues(alpha: 0.3); // Optimaalinen!
      }
    });

    // Palautetaan tausta takaisin mustaksi 600ms viiveellä
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _scaffoldBgColor = const Color(0xFF121212);
        });
      }
    });
  }


void _showSessionSummary() {
  // Lasketaan koko sarjan keskiarvo
  double totalAverage = 0;
  if (_repValues.isNotEmpty) {
    totalAverage = _repValues.reduce((a, b) => a + b) / _repValues.length;
  }

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text("${_currentExercise.name} - Tulokset", 
              style: const TextStyle(color: Colors.cyanAccent)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _summaryRow("Toistot yhteensä:", "$_repCount", Colors.white),
              // NÄYTETÄÄN KOKONAISKESKIARVO TÄSSÄ
              _summaryRow(
                _currentExercise.id == 0 || _currentExercise.id >= 4 
                    ? "Peak keskiarvo:" 
                    : "Mean keskiarvo:", 
                "${totalAverage.toStringAsFixed(2)} m/s", 
                Colors.yellowAccent
              ),
              const Divider(color: Colors.white24),
              const Text("TOISTOKOHTAINEN PALAUTE:", 
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 10),
              SizedBox(
                height: 200,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sessionFeedbacks.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        backgroundColor: Colors.cyanAccent,
                        radius: 12,
                        child: Text("${index + 1}", 
                               style: const TextStyle(fontSize: 10, color: Colors.black)),
                      ),
                      // Näytetään sekä sanallinen palaute että yksittäisen noston nopeus
                      title: Text(_sessionFeedbacks[index], 
                             style: const TextStyle(color: Colors.white, fontSize: 14)),
                      trailing: Text("${_repValues[index].toStringAsFixed(2)} m/s",
                             style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("SULJE", style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      );
    },
  );
}

  Widget _summaryRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
    );
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
      backgroundColor: _scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // Valinnainen: tekee välähdyksestä tyylikkäämmän
        elevation: 0,
        title: const Text("Velocity Based Training"),
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

          // build-metodin sisällä Columnin alussa:
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: _getHeroColor().withValues(alpha: 0.2), // Taustaväri palautteen mukaan
            child: Text(
              _lastFeedbackText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _getHeroColor(),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

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
                border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5)),
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
                      fontSize: 20, 
                      color: Colors.cyanAccent, 
                      fontWeight: FontWeight.bold
                    ),
                  ),
                  const SizedBox(height: 0.5), // Pieni väli laskurin ja nopeuden välissä
                  
                  Text(
                    displayValue,
                    style: TextStyle(
                      fontSize: 90, 
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
                        if (_isRecording) {
                          // Kun lopetetaan, näytetään kooste
                          _showSessionSummary();
                        } else {
                          // Kun aloitetaan uusi, nollataan kaikki
                          _spots.clear();
                          _xValue = 0;
                          _peakOfRep = 0;
                          _meanOfRep = 0;
                          _repCount = 0;
                          _goodReps = 0;
                          _fastReps = 0;
                          _slowReps = 0;
                          _repSamples.clear();
                          _sessionFeedbacks.clear();
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