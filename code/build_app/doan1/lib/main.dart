import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

// MQTT
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// Firebase
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

import 'history_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const FallDetectApp());
}

class FallDetectApp extends StatelessWidget {
  const FallDetectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fall Detect Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

// ================== ROOT: ĐIỀU HƯỚNG BOTTOM NAV ==================
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          MonitorScreen(),
          HistoryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'Giám sát'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Lịch sử'),
        ],
      ),
    );
  }
}

// ================== MÔ HÌNH 1 ĐIỂM DỮ LIỆU CHO BIỂU ĐỒ ==================
class VitalPoint {
  final DateTime time;
  final double heartRate;
  final double spO2;
  VitalPoint(this.time, this.heartRate, this.spO2);
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  // ================== CẤU HÌNH HIVEMQ CLOUD ==================
  static const String mqttHost = 'YOURD_HOST';
  static const int mqttPort = 8883;
  static const String mqttUser = 'YOUR_USER';
  static const String mqttPass = 'YOUR_PASS';

  static const String topicData = 'falldetect/PROJECT/data';
  static const String topicAlert = 'falldetect/PROJECT/alert';
  static const String topicSosCancel = 'falldetect/PROJECT/sos_cancel';

  late MqttServerClient client;

  // ================== TRẠNG THÁI HIỂN THỊ ==================
  int heartRate = 0;
  int spO2 = 0;
  double atotal = 0;
  double tilt = 0;
  String deviceStatus = '--';
  bool isConnected = false;
  DateTime? lastUpdate;

  // ================== DỮ LIỆU CHO BIỂU ĐỒ (30 điểm gần nhất) ==================
  final List<VitalPoint> _history = [];
  static const int maxPoints = 30;

  @override
  void initState() {
    super.initState();
    _connectMqtt();
  }

  @override
  void dispose() {
    client.disconnect();
    super.dispose();
  }

  // ================== KẾT NỐI MQTT ==================
  Future<void> _connectMqtt() async {
    client = MqttServerClient.withPort(
      mqttHost,
      'flutter_client_${DateTime.now().millisecondsSinceEpoch}',
      mqttPort,
    );
    client.secure = true;
    client.securityContext = SecurityContext.defaultContext;
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.logging(on: false);

    final connMess = MqttConnectMessage()
        .withClientIdentifier('flutter_client_${DateTime.now().millisecondsSinceEpoch}')
        .authenticateAs(mqttUser, mqttPass)
        .startClean();
    client.connectionMessage = connMess;

    try {
      await client.connect();
    } catch (e) {
      debugPrint('Loi ket noi MQTT: $e');
      client.disconnect();
      Future.delayed(const Duration(seconds: 5), _connectMqtt);
      return;
    }

    if (client.connectionStatus!.state == MqttConnectionState.connected) {
      client.subscribe(topicData, MqttQos.atLeastOnce);
      client.subscribe(topicAlert, MqttQos.atLeastOnce);

      client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> event) {
        final MqttPublishMessage recMess = event[0].payload as MqttPublishMessage;
        final String payload =
            MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        final String topic = event[0].topic;
        _handleMessage(topic, payload);
      });
    } else {
      debugPrint('MQTT ket noi that bai: ${client.connectionStatus}');
      client.disconnect();
      Future.delayed(const Duration(seconds: 5), _connectMqtt);
    }
  }

  void _onConnected() {
    debugPrint('MQTT da ket noi');
    if (mounted) setState(() => isConnected = true);
  }

  void _onDisconnected() {
    debugPrint('MQTT mat ket noi');
    if (mounted) setState(() => isConnected = false);
  }

  // ================== XỬ LÝ DỮ LIỆU NHẬN ĐƯỢC ==================
  void _handleMessage(String topic, String payload) {
    try {
      final data = jsonDecode(payload);

      if (topic == topicData) {
        final hr = (data['heartRate'] ?? 0).toInt();
        final sp = (data['spO2'] ?? 0).toInt();
        setState(() {
          heartRate = hr;
          spO2 = sp;
          atotal = (data['atotal'] ?? 0).toDouble();
          tilt = (data['tilt'] ?? 0).toDouble();
          deviceStatus = data['status'] ?? '--';
          lastUpdate = DateTime.now();

          // Chỉ thêm vào biểu đồ nếu có tín hiệu hợp lệ (tránh vẽ toàn số 0 lúc mới đeo)
          if (hr > 0 && sp > 0) {
            _history.add(VitalPoint(DateTime.now(), hr.toDouble(), sp.toDouble()));
            if (_history.length > maxPoints) {
              _history.removeAt(0);
            }
          }
        });
      } else if (topic == topicAlert) {
        final String reason = data['reason'] ?? 'Phat hien te nga';
        _showFallAlert(reason);
        _saveAlertToFirestore(reason);
      }
    } catch (e) {
      debugPrint('Loi parse JSON: $e');
    }
  }

  // ================== LƯU LỊCH SỬ VÀO FIRESTORE ==================
  Future<void> _saveAlertToFirestore(String reason) async {
    try {
      await FirebaseFirestore.instance.collection('alerts').add({
        'reason': reason,
        'heartRate': heartRate,
        'spO2': spO2,
        'atotal': atotal,
        'tilt': tilt,
        'timestamp': FieldValue.serverTimestamp(),
      });
      debugPrint('Da luu lich su vao Firestore');
    } catch (e) {
      debugPrint('Loi luu Firestore: $e');
    }
  }

  // ================== HIỂN THỊ CẢNH BÁO TÉ NGÃ ==================
  void _showFallAlert(String reason) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red[50],
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 48),
        title: const Text('CẢNH BÁO TÉ NGÃ!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () {
              _sendSosCancel();
              Navigator.of(ctx).pop();
            },
            child: const Text('Xác nhận an toàn (hủy SOS)'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Đã hiểu, gọi ngay'),
          ),
        ],
      ),
    );
  }

  void _sendSosCancel() {
    if (client.connectionStatus!.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString('cancel');
    client.publishMessage(topicSosCancel, MqttQos.atLeastOnce, builder.payload!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đồ án 1 - HGP - Phát hiện té ngã'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Icon(
                  isConnected ? Icons.cloud_done : Icons.cloud_off,
                  color: isConnected ? Colors.greenAccent : Colors.redAccent,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  isConnected ? 'Đã kết nối' : 'Mất kết nối',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (!isConnected) await _connectMqtt();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: _VitalCard(
                    icon: Icons.favorite,
                    color: Colors.redAccent,
                    label: 'Nhịp tim',
                    value: heartRate > 0 ? '$heartRate' : '--',
                    unit: 'bpm',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _VitalCard(
                    icon: Icons.air,
                    color: Colors.blueAccent,
                    label: 'SpO2',
                    value: spO2 > 0 ? '$spO2' : '--',
                    unit: '%',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Trạng thái thiết bị', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Atotal: ${atotal.toStringAsFixed(2)} g'),
                    Text('Góc nghiêng: ${tilt.toStringAsFixed(1)}°'),
                    Text('Trạng thái: $deviceStatus'),
                    if (lastUpdate != null) 
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Cập nhật lúc: ${lastUpdate!.hour.toString().padLeft(2, '0')}:'
                          '${lastUpdate!.minute.toString().padLeft(2, '0')}:'
                          '${lastUpdate!.second.toString().padLeft(2, '0')}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ================== BIỂU ĐỒ XU HƯỚNG ==================
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Xu hướng nhịp tim & SpO2', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      '${_history.length} điểm dữ liệu gần nhất',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 220,
                      child: _history.length < 2
                          ? const Center(child: Text('Đang chờ dữ liệu...'))
                          : _VitalChart(history: _history),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _legendDot(Colors.redAccent, 'Nhịp tim'),
                        const SizedBox(width: 20),
                        _legendDot(Colors.blueAccent, 'SpO2'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

// ================== WIDGET BIỂU ĐỒ ==================
class _VitalChart extends StatelessWidget {
  final List<VitalPoint> history;
  const _VitalChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final hrSpots = <FlSpot>[];
    final spo2Spots = <FlSpot>[];
    for (int i = 0; i < history.length; i++) {
      hrSpots.add(FlSpot(i.toDouble(), history[i].heartRate));
      spo2Spots.add(FlSpot(i.toDouble(), history[i].spO2));
    }

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: 160,
        gridData: const FlGridData(show: true, horizontalInterval: 20),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 32, interval: 40),
          ),
          bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: hrSpots,
            isCurved: true,
            color: Colors.redAccent,
            barWidth: 2,
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: spo2Spots,
            isCurved: true,
            color: Colors.blueAccent,
            barWidth: 2,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }
}

class _VitalCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String unit;

  const _VitalCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(unit, style: TextStyle(color: Colors.grey[600])),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}