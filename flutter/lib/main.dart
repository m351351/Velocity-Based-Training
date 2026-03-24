import 'package:flutter/material.dart';
import 'dart:async';
// Bluetooth-kirjasto, otetaan käyttöön myöhemmin
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
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

  final List<FlSpot> _velocitySpots = []; // Graafipisteet kiihtyvyysdatasta
  double _x = 0.0; // ajan kulumista simuloiva muuttuja graafia varten

// Tässä mock-datalla simuloidaan kiihtyvyysanturin dataa
  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() {
        _t += 0.1; // Simuloidaan ajan kulumista
        _x += 1.0;
        _velocitySpots.add(FlSpot(_x, currentVelocity));
        
        if (_velocitySpots.length > 100) {
          _velocitySpots.removeAt(0); // graafin skaalaus viimeiseen 100 pisteesee 
        } // uusi datapiste graafiin
        // perusmuoto: siniaalto ja pieni satunnaisuus
        final base = 0.9 + 0.6 * sin(_t); // simuloidaan nosto ja laskuvaihetta
        final noise = (_random.nextDouble() - 0.5) * 0.08; // satunnaista kohinaa

        // Ei anneta nopeuden mennä negatiiviseksi tässä mock-datassa
        currentVelocity = max(0.0, base + noise);
            });
  });
}
@override
void dispose() {
  _timer?.cancel();
  super.dispose();

}
  // Tänne tulee myöhemmin kiihtyvyysanturin data [cite: 25, 76]

/* //TÄMÄ PÄÄLLE KUN HALUTAAN KÄYTTÄÄ KÄYTTÖLIITTYMÄÄ PUHELIMELLA, POIS PÄÄLTÄ JOS KEHITYS KONEELLA -meri 190326
@override
  void initState(){
    super.initState();

    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state){
      if (state == BluetoothAdapterState.on){
        debugPrint("Bluetooth on päällä ja valmis VBT-laitteen hakuun.");
      } else{
        debugPrint("Bluetooth on pois päältä, tarttis varmaan tehdä jotain");
      }
    });
  }*/

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Velocity Based Training'),
      ),
      body: Column(
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
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true)),
        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
          const Padding(
            padding: EdgeInsets.all(20.0),
            child: Text(
              'Analyysi: Odota suoritusta...',
              style: TextStyle(color: Colors.greenAccent, fontSize: 18),
            ),
          ),
/*
          // 4. Testipainike simulointiin
          ElevatedButton(
            onPressed: () {
              setState(() {
                currentVelocity = 1.25; // Simuloitu nosto [cite: 66]
              });
            },
            child: const Text('Simuloi nosto'),
          ),
*/
// TÄSSÄ NAPPULAT LIIKKEIDEN VALINTAAN -meri 190326
          Padding(
            padding: EdgeInsets.all(8.0),
            child: Text("valittu liike: $valittuLiike",
              style: TextStyle(fontSize: 20, color: Colors.blueAccent)),
            ),

          Wrap(
            spacing: 8.0,
            children: liikkeet.map((yksiLiike){
              return ElevatedButton(
                onPressed: (){
                  setState(() {
                    valittuLiike = yksiLiike;
                  });
                } ,
                child: Text(yksiLiike),
              );
            }) .toList(),
            ),
          


        ],
      ),
    );
  }
}