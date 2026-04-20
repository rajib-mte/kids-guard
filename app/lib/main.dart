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
  LatLngTween({LatLng? begin, LatLng? end})
      : super(begin: begin, end: end);

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

  double temp = 0;
  double hum = 0;
  double gas = 0;
  double speed = 0;

  bool alarmState = false;

  late MqttServerClient client;

  late AnimationController _controller;
  Animation<LatLng>? _animation;

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
    super.dispose();
  }

  Future<void> getUserLocation() async {
    LocationPermission permission;

    permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return; // user permanently denied
    }

    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    userLocation = LatLng(pos.latitude, pos.longitude);

    await getAddress(pos.latitude, pos.longitude, true);

    setState(() {});
  }

  Future<void> getAddress(double lat, double lng, bool isUser) async {
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng",
    );

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

  Future<void> connectMQTT() async {
    client = MqttServerClient(
      'test.mosquitto.org',
      'client_${DateTime.now().millisecondsSinceEpoch}',
    );

    client.port = 1883;
    client.keepAlivePeriod = 20;

    client.connectionMessage =
        MqttConnectMessage().withClientIdentifier('flutter').startClean();

    await client.connect();

    client.subscribe('kidsgurd/data', MqttQos.atMostOnce);

    client.updates!.listen((events) async {
      final msg = events[0].payload as MqttPublishMessage;
      final data = jsonDecode(
        MqttPublishPayload.bytesToStringAsString(msg.payload.message),
      );

      LatLng newDevice = LatLng(data['lat'], data['lng']);

      previousDeviceLocation = deviceLocation;

      double durationMs =
      (speed > 0) ? (2000 / speed).clamp(300, 1500) : 1000;

      _controller.duration = Duration(milliseconds: durationMs.toInt());

      _animation = LatLngTween(
        begin: previousDeviceLocation,
        end: newDevice,
      ).animate(CurvedAnimation(
        parent: _controller,
        curve: Curves.linear,
      ))
        ..addListener(() {
          setState(() {
            deviceLocation = _animation!.value;
          });
        });

      _controller.forward(from: 0);

      setState(() {
        temp = (data['temp'] ?? 0).toDouble();
        hum = (data['hum'] ?? 0).toDouble();
        gas = (data['gas'] ?? 0).toDouble();
        speed = (data['speed'] ?? 0).toDouble();
      });

      await getAddress(newDevice.latitude, newDevice.longitude, false);
    });
  }

  // 🚨 MQTT ALARM
  void sendAlarmData() {
    final builder = MqttClientPayloadBuilder();

    builder.addString(jsonEncode({
      "alarm": alarmState ? 1 : 0,
    }));

    client.publishMessage(
      "kidsgurd/senddata",
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  // 🗺️ FIXED GOOGLE MAP NAVIGATION (FORCE APP OPEN)
  Future<void> openGoogleMapsRoute() async {
    if (userLocation == null) return;

    final url =
        "google.navigation:q=${deviceLocation.latitude},${deviceLocation.longitude}&mode=d";

    final uri = Uri.parse(url);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      // fallback
      final fallbackUrl =
          "https://www.google.com/maps/dir/?api=1"
          "&origin=${userLocation!.latitude},${userLocation!.longitude}"
          "&destination=${deviceLocation.latitude},${deviceLocation.longitude}"
          "&travelmode=driving";

      await launchUrl(Uri.parse(fallbackUrl),
          mode: LaunchMode.externalApplication);
    }
  }

  Widget buildCard(String title, String city, String address, Color color) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(blurRadius: 5)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: color)),
          Text(city),
          Text(address,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 5),
          Text("🌡 $temp °C"),
          Text("💧 $hum %"),
          Text("🔥 $gas"),
          Text("🚗 $speed km/h"),
        ],
      ),
    );
  }

  Widget deviceInfo() => buildCard(
    "📍 DEVICE",
    deviceCity,
    deviceAddress,
    Colors.red,
  );

  Widget userInfo() {
    if (userLocation == null) return const SizedBox();
    return buildCard(
      "📍 USER",
      userCity,
      userAddress,
      Colors.blue,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: deviceLocation,
              initialZoom: 15,
            ),
            children: [
              TileLayer(
                urlTemplate:
                "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png",
                subdomains: const ['a', 'b', 'c', 'd'],
              ),

              PolylineLayer(
                polylines: [
                  if (userLocation != null)
                    Polyline(
                      points: [userLocation!, deviceLocation],
                      strokeWidth: 4,
                      color: Colors.red,
                    ),
                ],
              ),

              MarkerLayer(
                markers: [
                  if (userLocation != null)
                    Marker(
                      point: userLocation!,
                      width: 80,
                      height: 80,
                      child: const Icon(
                        Icons.person_pin_circle,
                        color: Colors.blue,
                        size: 40,
                      ),
                    ),
                  Marker(
                    point: deviceLocation,
                    width: 80,
                    height: 80,
                    child: const Icon(
                      Icons.location_pin,
                      color: Colors.red,
                      size: 40,
                    ),
                  ),
                ],
              ),
            ],
          ),

          Positioned(top: 40, left: 10, child: userInfo()),
          Positioned(top: 40, right: 10, child: deviceInfo()),

          Positioned(
            bottom: 30,
            right: 20,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: "focus",
                  backgroundColor: Colors.black,
                  child: const Icon(Icons.my_location),
                  onPressed: () {
                    mapController.move(deviceLocation, 18);
                  },
                ),
                const SizedBox(height: 10),

                FloatingActionButton(
                  heroTag: "map",
                  backgroundColor: Colors.green,
                  child: const Icon(Icons.directions),
                  onPressed: openGoogleMapsRoute,
                ),

                const SizedBox(height: 10),

                FloatingActionButton(
                  heroTag: "alarm",
                  backgroundColor:
                  alarmState ? Colors.red : Colors.grey,
                  child: Icon(
                      alarmState ? Icons.alarm_on : Icons.alarm_off),
                  onPressed: () {
                    setState(() {
                      alarmState = !alarmState;
                    });
                    sendAlarmData();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}