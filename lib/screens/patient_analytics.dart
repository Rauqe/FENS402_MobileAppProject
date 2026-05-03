import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../services/api_service.dart';

class PatientAnalyticsScreen extends StatefulWidget {
  final Patient patient;
  const PatientAnalyticsScreen({super.key, required this.patient});

  @override
  State<PatientAnalyticsScreen> createState() => _PatientAnalyticsScreenState();
}

class _PatientAnalyticsScreenState extends State<PatientAnalyticsScreen> {
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;

  Future<void> _fetch() async {
    if (_startDate.isAfter(_endDate)) {
      setState(() => _error = 'Start date cannot be after end date.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final start = _startDate.toIso8601String().split('T').first;
      final end = _endDate.toIso8601String().split('T').first;
      final result = await ApiService.instance.getPatientAnalytics(
        patientId: widget.patient.patientId,
        startDate: start,
        endDate: end,
      );
      setState(() => _data = result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
      if (_startDate.isAfter(_endDate) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Start date cannot be after end date.'),
          ),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.patient.fullName} — Analytics'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Date Range',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            )),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickDate(isStart: true),
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              _startDate.toIso8601String().split('T').first,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('→'),
                        ),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickDate(isStart: false),
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              _endDate.toIso8601String().split('T').first,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _fetch,
                        icon: const Icon(Icons.search_rounded),
                        label: const Text('Get Analytics'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(
                  child: Text('Error: $_error',
                      style: const TextStyle(color: Colors.red)))
            else if (_data != null)
              _buildResults(cs),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ColorScheme cs) {
    final dispensed = (_data!['total_dispensed'] as num?)?.toInt() ?? 0;
    final taken = (_data!['total_taken'] as num?)?.toInt() ?? 0;
    final missed = (_data!['total_missed'] as num?)?.toInt() ?? 0;
    final adherence = (_data!['adherence_rate'] as num?)?.toDouble() ?? 0.0;
    final daily = (_data!['daily_stats'] as List<dynamic>?) ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _statCard('Dispensed', dispensed, Colors.blue, cs),
            const SizedBox(width: 8),
            _statCard('Taken', taken, Colors.green, cs),
            const SizedBox(width: 8),
            _statCard('Missed', missed, Colors.red, cs),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: cs.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Adherence Rate',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        )),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: adherence / 100,
                          minHeight: 20,
                          backgroundColor: Colors.red.withOpacity(0.15),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            adherence >= 80
                                ? Colors.green
                                : adherence >= 50
                                    ? Colors.orange
                                    : Colors.red,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${adherence.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: adherence >= 80
                            ? Colors.green
                            : adherence >= 50
                                ? Colors.orange
                                : Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (daily.isNotEmpty) ...[
          Text('Daily Breakdown',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: cs.outlineVariant),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: daily.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final day = daily[i] as Map<String, dynamic>;
                final t = (day['taken'] as num?)?.toInt() ?? 0;
                final m = (day['missed'] as num?)?.toInt() ?? 0;
                final d = (day['dispensed'] as num?)?.toInt() ?? 0;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: m > 0
                        ? Colors.red.withOpacity(0.1)
                        : Colors.green.withOpacity(0.1),
                    child: Icon(
                      m > 0 ? Icons.close_rounded : Icons.check_rounded,
                      color: m > 0 ? Colors.red : Colors.green,
                      size: 18,
                    ),
                  ),
                  title: Text(day['date'] as String? ?? ''),
                  subtitle: Text('Dispensed: $d  Taken: $t  Missed: $m'),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _statCard(String label, int value, Color color, ColorScheme cs) {
    return Expanded(
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color.withOpacity(0.3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(label,
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
