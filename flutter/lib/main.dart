import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Velocity Based Trainig'),
      ),
      body: Column(
        children: [
          // 1. Graafialue (tähän tulee fl_chart myöhemmin) 
          Container(
            height: 300,
            margin: const EdgeInsets.all(16),
            color: Colors.grey[900],
            child: const Center(child: Text('Tähän tulee kiihtyvyysgraafi')),
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

          // 4. Testipainike simulointiin
          ElevatedButton(
            onPressed: () {
              setState(() {
                currentVelocity = 1.25; // Simuloitu nosto [cite: 66]
              });
            },
            child: const Text('Simuloi nosto'),
          ),

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