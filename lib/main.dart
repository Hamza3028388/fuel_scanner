import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ====================== الاتصال بالـ API ======================
class Api {
  // غيّر الـ IP لعنوان اللابتوب، أو من أيقونة الإعدادات داخل التطبيق
  static String baseUrl = 'http://192.168.1.10:5298';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    baseUrl = p.getString('baseUrl') ?? baseUrl;
  }

  static Future<void> save(String url) async {
    final p = await SharedPreferences.getInstance();
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    await p.setString('baseUrl', baseUrl);
  }

  static String _msg(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    try {
      final j = jsonDecode(body);
      if (j is Map) return (j['message'] ?? j['detail'] ?? j['title'] ?? body).toString();
    } catch (_) {}
    return body.isEmpty ? 'خطأ (${r.statusCode})' : body;
  }

  static Future<Map<String, dynamic>> scan(String code) async {
    final r = await http
        .get(Uri.parse('$baseUrl/api/Vehicles/scan/$code'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 400 || r.statusCode == 404) {
      throw Exception('QR غير صالح');
    }
    if (r.statusCode != 200) throw Exception(_msg(r));
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  static Future<({bool ok, String message})> fuel(String code, double? liters) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/api/Fuel'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'qrCode': code, 'liters': liters}),
        )
        .timeout(const Duration(seconds: 10));
    return (ok: r.statusCode == 200, message: _msg(r));
  }
}

// ====================== التطبيق ======================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.load();
  runApp(const FuelApp());
}

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تعبئة الوقود',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      builder: (c, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const ScanScreen(),
    );
  }
}

// ====================== شاشة الكاميرا ======================
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _busy = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    setState(() => _busy = true);
    await controller.stop();

    try {
      final data = await Api.scan(code.trim());
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ResultScreen(code: code.trim(), data: data)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }

    if (mounted) {
      setState(() => _busy = false);
      await controller.start();
    }
  }

  Future<void> _settings() async {
    final txt = TextEditingController(text: Api.baseUrl);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('عنوان السيرفر'),
        content: TextField(
          controller: txt,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(hintText: 'http://192.168.1.10:5298'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              await Api.save(txt.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سكان السيارة'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => controller.toggleTorch(),
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: _settings),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          if (_busy) const Center(child: CircularProgressIndicator()),
          const Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Text(
              'وجّه الكاميرا نحو كود QR',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ],
      ),
    );
  }
}

// ====================== شاشة النتيجة ======================
class ResultScreen extends StatefulWidget {
  final String code;
  final Map<String, dynamic> data;
  const ResultScreen({super.key, required this.code, required this.data});
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final litersCtrl = TextEditingController();
  bool _sending = false;

  bool get allowed => widget.data['allowed'] == true;

  Future<void> _confirm() async {
    setState(() => _sending = true);
    try {
      final liters = double.tryParse(litersCtrl.text.trim());
      final r = await Api.fuel(widget.code, liters);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.ok ? 'تم تسجيل التعبئة' : r.message),
        backgroundColor: r.ok ? Colors.green : Colors.red,
      ));
      if (r.ok) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تعذر الاتصال: $e'), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _row(String label, dynamic value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
                width: 110,
                child: Text(label, style: const TextStyle(color: Colors.black54))),
            Expanded(
                child: Text('${value ?? '-'}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
          ],
        ),
      );

  String? _date(dynamic v) => v == null ? null : v.toString().split('T').first;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final found = d['found'] == true;
    final color = allowed ? Colors.green : Colors.red;

    return Scaffold(
      appBar: AppBar(title: const Text('نتيجة السكان'), backgroundColor: color, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Icon(allowed ? Icons.check_circle : Icons.cancel, color: color, size: 64),
              const SizedBox(height: 8),
              Text('${d['message'] ?? ''}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ]),
          ),
          if (found) ...[
            const SizedBox(height: 16),
            _row('السائق', d['driverName']),
            _row('رقم الكتيب', d['bookletNumber']),
            _row('اللوحة', d['plateNumber']),
            _row('المدينة', d['city']),
            _row('نوع السيارة', d['carType']),
            _row('اللون', d['color']),
            const Divider(height: 28),
            _row('آخر تعبئة', _date(d['lastFuelDate']) ?? 'لا يوجد'),
            _row('المدة المسموحة', '${d['intervalDays']} يوم'),
            if (d['nextAllowedDate'] != null) _row('التعبئة القادمة', _date(d['nextAllowedDate'])),
          ],
          const SizedBox(height: 20),
          if (allowed) ...[
            TextField(
              controller: litersCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'عدد اللترات (اختياري)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
                onPressed: _sending ? null : _confirm,
                icon: const Icon(Icons.local_gas_station),
                label: Text(_sending ? 'جاري التسجيل...' : 'تأكيد التعبئة',
                    style: const TextStyle(fontSize: 18)),
              ),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton(
              onPressed: () => Navigator.pop(context), child: const Text('رجوع للسكان')),
        ],
      ),
    );
  }
}