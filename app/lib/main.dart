import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MapPage(),
    );
  }
}

class LatLngTween extends Tween<LatLng> {
  LatLngTween({LatLng? begin, LatLng? end}) : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) {
    return LatLng(
      begin!.latitude + (end!.latitude - begin!.latitude) * t,
      begin!.longitude + (end!.longitude - begin!.longitude) * t,
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage>
    with SingleTickerProviderStateMixin {
  final MapController mapController = MapController();

  LatLng deviceLocation = LatLng(23.8103, 90.4125);
  LatLng? userLocation;
  LatLng? previousDeviceLocation;

  String deviceCity = "";
  String deviceAddress = "";
  String userCity = "";
  String userAddress = "";

  double temp = 0, hum = 0, gas = 0, speed = 0;

  bool alarmState = false;

  late MqttServerClient client;

  late AnimationController _controller;
  Animation<LatLng>? _animation;

  bool isConnecting = true;
  bool isConnected = false;

  Timer? reconnectTimer;
  int retryCount = 0;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    getUserLocation();
    connectMQTT();
  }

  @override
  void dispose() {
    _controller.dispose();
    reconnectTimer?.cancel();
    super.dispose();
  }

  // 📍 USER LOCATION
  Future<void> getUserLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) return;

    Position pos = await Geolocator.getCurrentPosition();

    userLocation = LatLng(pos.latitude, pos.longitude);
    await getAddress(pos.latitude, pos.longitude, true);

    setState(() {});
  }

  // 🌍 ADDRESS
  Future<void> getAddress(double lat, double lng, bool isUser) async {
    final url = Uri.parse(
        "https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng");

    final res = await http.get(url, headers: {"User-Agent": "FlutterApp"});
    final data = jsonDecode(res.body);

    setState(() {
      if (isUser) {
        userCity = data["address"]["city"] ??
            data["address"]["town"] ??
            data["address"]["village"] ??
            "Unknown";
        userAddress = data["display_name"] ?? "";
      } else {
        deviceCity = data["address"]["city"] ??
            data["address"]["town"] ??
            data["address"]["village"] ??
            "Unknown";
        deviceAddress = data["display_name"] ?? "";
      }
    });
  }

  // 🔌 MQTT CONNECT (HiveMQ)
  Future<void> connectMQTT() async {
    setState(() => isConnecting = true);

    client = MqttServerClient(
      'broker.hivemq.com',
      'client_${DateTime.now().millisecondsSinceEpoch}',
    );

    client.port = 1883;
    client.keepAlivePeriod = 20;

    client.onDisconnected = onDisconnected;

    client.connectionMessage =
        MqttConnectMessage().withClientIdentifier('flutter').startClean();

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      if (client.connectionStatus!.state ==
          MqttConnectionState.connected) {
        setState(() {
          isConnecting = false;
          isConnected = true;
        });

        retryCount = 0;
        reconnectTimer?.cancel();

        client.subscribe('kidsgurd/data', MqttQos.atMostOnce);
        client.updates!.listen(onMessage);
      } else {
        throw Exception("Connection failed");
      }
    } catch (e) {
      setState(() {
        isConnecting = false;
        isConnected = false;
      });

      startAutoReconnect();
    }
  }

  // 🔄 AUTO RECONNECT (SMART)
  void startAutoReconnect() {
    reconnectTimer?.cancel();

    reconnectTimer =
        Timer.periodic(const Duration(seconds: 10), (timer) {
          if (!isConnected) {
            retryCount++;

            int delay = (retryCount * 5).clamp(5, 60);

            print("🔄 Retry $retryCount in $delay sec");

            Future.delayed(Duration(seconds: delay), () {
              connectMQTT();
            });
          } else {
            retryCount = 0;
            timer.cancel();
          }
        });
  }

  void onDisconnected() {
    setState(() => isConnected = false);
    startAutoReconnect();
  }

  // 📡 RECEIVE DATA
  void onMessage(List<MqttReceivedMessage<MqttMessage>> events) async {
    final msg = events[0].payload as MqttPublishMessage;
    final data = jsonDecode(
      MqttPublishPayload.bytesToStringAsString(msg.payload.message),
    );

    LatLng newDevice = LatLng(data['lat'], data['lng']);

    previousDeviceLocation = deviceLocation;

    _animation = LatLngTween(
      begin: previousDeviceLocation,
      end: newDevice,
    ).animate(_controller)
      ..addListener(() {
        setState(() => deviceLocation = _animation!.value);
      });

    _controller.forward(from: 0);

    setState(() {
      temp = (data['temp'] ?? 0).toDouble();
      hum = (data['hum'] ?? 0).toDouble();
      gas = (data['gas'] ?? 0).toDouble();
      speed = (data['speed'] ?? 0).toDouble();
    });

    await getAddress(newDevice.latitude, newDevice.longitude, false);
  }

  // 🚨 SEND ALARM
  void sendAlarmData() {
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"alarm": alarmState ? 1 : 0}));

    client.publishMessage(
      "kidsgurd/senddata",
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  // 🗺️ NAVIGATION
  Future<void> openGoogleMapsRoute() async {
    if (userLocation == null) return;

    final uri = Uri.parse(
        "google.navigation:q=${deviceLocation.latitude},${deviceLocation.longitude}");

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Kids Guard"),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: Text(
                isConnected ? "🟢 Connected" : "🔴 Offline",
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),

      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options:
            MapOptions(initialCenter: deviceLocation, initialZoom: 15),
            children: [
              TileLayer(
                urlTemplate:
                "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png",
                subdomains: const ['a', 'b', 'c', 'd'],
              ),
              MarkerLayer(markers: [
                if (userLocation != null)
                  Marker(
                    point: userLocation!,
                    child: const Icon(Icons.person, color: Colors.blue),
                  ),
                Marker(
                  point: deviceLocation,
                  child: const Icon(Icons.location_pin, color: Colors.red),
                ),
              ]),
            ],
          ),

          // 🔄 RECONNECT BUTTON
          if (!isConnected && !isConnecting)
            Positioned(
              top: 80,
              right: 20,
              child: ElevatedButton(
                onPressed: connectMQTT,
                child: const Text("Reconnect"),
              ),
            ),

          // ⏳ LOADING
          if (isConnecting)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 10),
                    Text("Connecting...",
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}