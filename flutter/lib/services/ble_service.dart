import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:typed_data';

class BLEService {
  static const String kServiceUuid = "12345678-1234-1234-1234-123456789abc";
  static const String kCharUuid = "abcd1234-ab12-ab12-ab12-abcdef123456";
  static const String kExerciseSelectUuid = "12345678-1234-1234-1234-123456789def";
  static const String kBatteryCharUuid = "00002a19-0000-1000-8000-00805f9b34fb";

  BluetoothDevice? device;
  BluetoothCharacteristic? velocityChar;
  BluetoothCharacteristic? exerciseChar;
  BluetoothCharacteristic? batteryChar;

  // Streamit, joita käyttöliittymä kuuntelee
  final _velocityController = StreamController<double>.broadcast();
  Stream<double> get velocityStream => _velocityController.stream;

  final _batteryController = StreamController<int>.broadcast();
  Stream<int> get batteryStream => _batteryController.stream;

Future<void> connect(BluetoothDevice d) async {
    device = d;
    await device!.connect();
    List<BluetoothService> services = await device!.discoverServices();

    for (var s in services) {
      for (var c in s.characteristics) {
        String uuid = c.uuid.str.toLowerCase();
        if (uuid == kCharUuid) velocityChar = c;
        if (uuid == kExerciseSelectUuid) exerciseChar = c;
        // Standardi akun UUID on 2a19
        if (uuid.contains("2a19")) batteryChar = c;
      }
    }

    // 1. Nopeusdatan tilaus (UUSI 50 Hz BINÄÄRIPURKU)
    if (velocityChar != null) {
      await velocityChar!.setNotifyValue(true);
      velocityChar!.onValueReceived.listen((data) {
        // Varmistetaan, että saimme tasan 4 tavua (C++ Float32 on 4 tavua)
        if (data.length == 4) {
          // Muunnetaan tavut suoraan desimaaliluvuksi (Little Endian -järjestys)
          final val = ByteData.sublistView(Uint8List.fromList(data)).getFloat32(0, Endian.little);
          
          // Syötetään luku suoraan streamiin main.dartin käytettäväksi
          _velocityController.add(val);
        }
      });
    }
    
    // 2. Akun tilan tilaus ja alkulukeminen
    if (batteryChar != null) {
      // Tilataan automaattiset päivitykset
      await batteryChar!.setNotifyValue(true);
      batteryChar!.onValueReceived.listen((data) {
        if (data.isNotEmpty) {
          _batteryController.add(data[0]); // Lisätään uusi prosentti streamiin
        }
      });

      // Luetaan akun tila kerran heti yhdistämisen jälkeen
      try {
        final initialBattery = await batteryChar!.read();
        if (initialBattery.isNotEmpty) {
          _batteryController.add(initialBattery[0]);
        }
      } catch (e) {
        debugPrint("Akun alkulukeminen epäonnistui: $e");
      }
    }
  }

  Future<void> sendExercise(int id) async {
    if (exerciseChar != null) {
      await exerciseChar!.write([id]);
    }
  }

  void dispose() {
    _velocityController.close();
    _batteryController.close();
  }
}