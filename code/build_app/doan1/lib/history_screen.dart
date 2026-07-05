import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử cảnh báo'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('alerts')
            .orderBy('timestamp', descending: true)
            .limit(100)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Lỗi tải dữ liệu: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Chưa có cảnh báo nào được ghi nhận.\nDữ liệu sẽ tự hiện ở đây khi có té ngã hoặc SOS.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            );
          }

          // ===== Thống kê nhanh =====
          final now = DateTime.now();
          final todayCount = docs.where((d) {
            final ts = (d['timestamp'] as Timestamp?)?.toDate();
            if (ts == null) return false;
            return ts.year == now.year && ts.month == now.month && ts.day == now.day;
          }).length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        label: 'Tổng số cảnh báo',
                        value: '${docs.length}',
                        icon: Icons.warning_amber_rounded,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: 'Hôm nay',
                        value: '$todayCount',
                        icon: Icons.today,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    return _AlertTile(data: data);
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _AlertTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final reason = data['reason'] ?? 'Không rõ lý do';
    final heartRate = data['heartRate'] ?? 0;
    final spO2 = data['spO2'] ?? 0;
    final ts = (data['timestamp'] as Timestamp?)?.toDate();

    final isSos = reason.toString().toLowerCase().contains('sos');

    String timeStr = 'Đang cập nhật...';
    if (ts != null) {
      timeStr = DateFormat('HH:mm:ss - dd/MM/yyyy').format(ts);
    }

    return Card(
      elevation: 1,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isSos ? Colors.orange[100] : Colors.red[100],
          child: Icon(
            isSos ? Icons.sos : Icons.warning_amber_rounded,
            color: isSos ? Colors.orange : Colors.red,
          ),
        ),
        title: Text(reason, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(timeStr, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 2),
            Text('Nhịp tim: $heartRate bpm  •  SpO2: $spO2%', style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}
