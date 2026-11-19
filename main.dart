import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

const green = Color(0xFF16834A);
const ink = Color(0xFF17231C);
final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final dateFmt = DateFormat('dd MMM yyyy, hh:mm a');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await KhataDb.instance.database;
  runApp(const MeraKhataApp());
}

class MeraKhataApp extends StatelessWidget {
  const MeraKhataApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mera Khata',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: green, surface: const Color(0xFFF7F9F7)),
      scaffoldBackgroundColor: const Color(0xFFF7F9F7),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF7F9F7), foregroundColor: ink, elevation: 0),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE4EAE5))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: green, width: 1.5)),
      ),
    ),
    home: const PinGate(),
  );
}

class KhataDb {
  KhataDb._();
  static final instance = KhataDb._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final root = await getDatabasesPath();
    _db = await openDatabase(p.join(root, 'mera_khata.db'), version: 1,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE customers(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, phone TEXT NOT NULL,
          photo TEXT, address TEXT, created_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE transactions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL,
          kind TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL,
          note TEXT, due_date TEXT, created_at TEXT NOT NULL,
          FOREIGN KEY(customer_id) REFERENCES customers(id))''');
        await db.execute('CREATE INDEX idx_customer_phone ON customers(phone)');
        await db.execute('CREATE INDEX idx_tx_customer ON transactions(customer_id)');
      });
    await _db!.execute('PRAGMA foreign_keys = ON');
    return _db!;
  }

  Future<List<Map<String, Object?>>> customers({String search = ''}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT c.*, COALESCE(SUM(CASE WHEN t.kind='credit' THEN t.amount ELSE -t.amount END),0) AS balance
      FROM customers c LEFT JOIN transactions t ON t.customer_id=c.id
      WHERE c.name LIKE ? OR c.phone LIKE ?
      GROUP BY c.id ORDER BY c.name COLLATE NOCASE
    ''', ['%$search%', '%$search%']);
  }

  Future<int> addCustomer(String name, String phone, String? photo, String address) async =>
    (await database).insert('customers', {'name': name, 'phone': phone, 'photo': photo,
      'address': address, 'created_at': DateTime.now().toIso8601String()});

  Future<void> updateCustomer(int id, String name, String phone, String? photo, String address) async =>
    (await database).update('customers', {'name': name, 'phone': phone, 'photo': photo, 'address': address},
      where: 'id=?', whereArgs: [id]);

  Future<int> addTx(int customerId, String kind, double amount, String method, String note, DateTime? due) async =>
    (await database).insert('transactions', {
      'customer_id': customerId, 'kind': kind, 'amount': amount, 'method': method,
      'note': note, 'due_date': due?.toIso8601String(), 'created_at': DateTime.now().toIso8601String()
    });

  Future<List<Map<String, Object?>>> transactions(int customerId) async =>
    (await database).query('transactions', where: 'customer_id=?', whereArgs: [customerId], orderBy: 'created_at DESC');

  Future<Map<String, Object?>> totals() async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT COUNT(DISTINCT c.id) customers,
      COALESCE(SUM(CASE WHEN t.kind='credit' THEN t.amount ELSE 0 END),0) credits,
      COALESCE(SUM(CASE WHEN t.kind='payment' THEN t.amount ELSE 0 END),0) received,
      COALESCE(SUM(CASE WHEN t.kind='credit' THEN t.amount ELSE -t.amount END),0) outstanding
      FROM customers c LEFT JOIN transactions t ON t.customer_id=c.id
    ''');
    return r.first;
  }

  Future<Map<String, Object?>> backup() async {
    final db = await database;
    return {'format': 'mera-khata-backup-v1',
      'customers': await db.query('customers'),
      'transactions': await db.query('transactions'),
      'exported_at': DateTime.now().toIso8601String()};
  }

  Future<void> restore(Map<String, dynamic> data) async {
    if (data['format'] != 'mera-khata-backup-v1') throw Exception('This is not a Mera Khata backup.');
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('transactions');
      await txn.delete('customers');
      for (final c in (data['customers'] as List)) {
        final row = Map<String, Object?>.from(c);
        await txn.insert('customers', row, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final t in (data['transactions'] as List)) {
        final row = Map<String, Object?>.from(t);
        await txn.insert('transactions', row, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}

class PinGate extends StatefulWidget {
  const PinGate({super.key});
  @override State<PinGate> createState() => _PinGateState();
}
class _PinGateState extends State<PinGate> {
  final pin = TextEditingController();
  bool loading = true, hasPin = false, invalid = false;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { hasPin = prefs.getString('app_pin') != null; loading = false; });
  }
  Future<void> _enter() async {
    final prefs = await SharedPreferences.getInstance();
    if (!hasPin) {
      if (pin.text.trim().length < 4) { setState(() => invalid = true); return; }
      await prefs.setString('app_pin', pin.text.trim());
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
    } else if (pin.text == prefs.getString('app_pin')) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
    } else { setState(() => invalid = true); }
  }
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.menu_book_rounded, color: green, size: 64),
        const SizedBox(height: 12), const Text('Mera Khata', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: ink)),
        const SizedBox(height: 8), Text(hasPin ? 'Enter your PIN' : 'Create a 4-digit (or longer) PIN'),
        const SizedBox(height: 20),
        TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'PIN', errorText: invalid ? 'Please check your PIN (minimum 4 digits).' : null)),
        const SizedBox(height: 14), SizedBox(width: double.infinity, child: FilledButton(onPressed: _enter, child: Text(hasPin ? 'Unlock app' : 'Create PIN'))),
        const SizedBox(height: 8), const Text('Your records stay on this device unless you export a backup.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54))
      ]))));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  String search = '';
  int tab = 0;
  Future<void> refresh() async { if (mounted) setState(() {}); }
  Future<void> _addCustomer() async {
    final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const CustomerForm()));
    if (result == true) refresh();
  }
  Future<void> _openCustomer(Map<String,Object?> c) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(customer: c)));
    refresh();
  }
  Future<void> _backup() async {
    try {
      final data = await KhataDb.instance.backup();
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'mera-khata-backup-${DateFormat('yyyyMMdd-HHmm').format(DateTime.now())}.json'));
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      await Share.shareXFiles([XFile(file.path)], text: 'Mera Khata backup. Keep this file safe.');
    } catch (e) { _msg('Backup failed: $e'); }
  }
  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Row(children: [Icon(Icons.menu_book_rounded, color: green), SizedBox(width: 9), Text('Mera Khata', style: TextStyle(fontWeight: FontWeight.bold))]),
      actions: [IconButton(tooltip: 'Settings & backup', onPressed: () => showModalBottomSheet(context: context, showDragHandle: true,
        builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.backup_outlined), title: const Text('Export backup'), subtitle: const Text('Share a JSON copy of all customer records'), onTap: () { Navigator.pop(context); _backup(); }),
          ListTile(leading: const Icon(Icons.lock_outline), title: const Text('Change PIN'), onTap: () async { Navigator.pop(context); await _changePin(); }),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('About Mera Khata'), subtitle: const Text('Offline-first customer ledger'), onTap: () { Navigator.pop(context); showAboutDialog(context: context, applicationName: 'Mera Khata', applicationVersion: '1.0.0', children: [const Text('Keep track of customer credit and payments.')]); })
        ]))), icon: const Icon(Icons.settings_outlined))]),
    body: FutureBuilder<List<Map<String,Object?>>>(
      future: KhataDb.instance.customers(search: search),
      builder: (context, snap) {
        final customers = snap.data ?? [];
        return FutureBuilder<Map<String,Object?>>(
          future: KhataDb.instance.totals(),
          builder: (context, totalsSnap) {
            final t = totalsSnap.data ?? {};
            final outstanding = (t['outstanding'] as num?)?.toDouble() ?? 0;
            return RefreshIndicator(onRefresh: refresh, child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: green, borderRadius: BorderRadius.circular(22)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('TOTAL OUTSTANDING', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  const SizedBox(height: 7), Text(money.format(outstanding), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16), Row(children: [
                    _metric('Customers', '${t['customers'] ?? 0}'), const SizedBox(width: 26),
                    _metric('Credit given', money.format((t['credits'] as num?)?.toDouble() ?? 0)),
                    const SizedBox(width: 26), _metric('Received', money.format((t['received'] as num?)?.toDouble() ?? 0))
                  ])
                ])),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Customers', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                FilledButton.icon(onPressed: _addCustomer, icon: const Icon(Icons.person_add_alt_1, size: 18), label: const Text('Add'))
              ]),
              const SizedBox(height: 12),
              TextField(onChanged: (v) => setState(() => search = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or mobile number')),
              const SizedBox(height: 12),
              if (snap.connectionState == ConnectionState.waiting) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
              if (customers.isEmpty && snap.connectionState != ConnectionState.waiting)
                Container(padding: const EdgeInsets.all(26), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                  child: const Column(children: [Icon(Icons.people_outline, size: 42, color: green), SizedBox(height: 8), Text('No customers yet', style: TextStyle(fontWeight: FontWeight.bold)), Text('Add your first customer to start keeping khata.') ])),
              ...customers.map((c) => Card(color: Colors.white, elevation: 0, margin: const EdgeInsets.only(bottom: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFE9EEEA))),
                child: ListTile(onTap: () => _openCustomer(c), contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  leading: _avatar(c['photo'] as String?, c['name'] as String),
                  title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(c['phone'] as String),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(money.format((c['balance'] as num).toDouble()), style: TextStyle(fontWeight: FontWeight.bold, color: (c['balance'] as num) > 0 ? Colors.red.shade700 : green)),
                    Text((c['balance'] as num) > 0 ? 'DUE' : 'CLEAR', style: const TextStyle(fontSize: 10, color: Colors.black54, letterSpacing: .7))
                  ])))),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsPage())),
                icon: const Icon(Icons.analytics_outlined), label: const Text('View reports & daily summary'))
            ]));
          });
      }),
  );
  Widget _metric(String label, String value) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    const SizedBox(height: 3), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))
  ]));
  Future<void> _changePin() async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: const Text('Set a new PIN'),
      content: TextField(controller: ctrl, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'New PIN (4+ digits)')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save'))]));
    if (value != null && value.trim().length >= 4) { final prefs = await SharedPreferences.getInstance(); await prefs.setString('app_pin', value.trim()); _msg('PIN updated.'); }
    else if (value != null) _msg('PIN must contain at least 4 digits.');
  }
}

Widget _avatar(String? path, String name) {
  final exists = path != null && File(path).existsSync();
  return CircleAvatar(radius: 25, backgroundColor: const Color(0xFFE5F2E9),
    backgroundImage: exists ? FileImage(File(path!)) : null,
    child: exists ? null : Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: green, fontWeight: FontWeight.bold, fontSize: 18)));
}

class CustomerForm extends StatefulWidget {
  final Map<String,Object?>? customer;
  const CustomerForm({super.key, this.customer});
  @override State<CustomerForm> createState() => _CustomerFormState();
}
class _CustomerFormState extends State<CustomerForm> {
  final name = TextEditingController(), phone = TextEditingController(), address = TextEditingController();
  String? photo;
  bool saving = false;
  @override void initState() { super.initState(); final c = widget.customer; if (c != null) { name.text = c['name'] as String; phone.text = c['phone'] as String; address.text = (c['address'] as String?) ?? ''; photo = c['photo'] as String?; } }
  Future<void> _pick() async { final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 75, maxWidth: 900); if (x != null) setState(() => photo = x.path); }
  Future<void> _save() async {
    if (name.text.trim().isEmpty || phone.text.trim().isEmpty) return;
    setState(() => saving = true);
    if (widget.customer == null) { await KhataDb.instance.addCustomer(name.text.trim(), phone.text.trim(), photo, address.text.trim()); }
    else { await KhataDb.instance.updateCustomer(widget.customer!['id'] as int, name.text.trim(), phone.text.trim(), photo, address.text.trim()); }
    if (mounted) Navigator.pop(context, true);
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.customer == null ? 'Add customer' : 'Edit customer')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      Center(child: InkWell(onTap: _pick, child: Stack(children: [
        _avatar(photo, name.text.isEmpty ? 'C' : name.text),
        const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 13, backgroundColor: green, child: Icon(Icons.camera_alt, size: 14, color: Colors.white)))
      ]))),
      const SizedBox(height: 22), TextField(controller: name, decoration: const InputDecoration(labelText: 'Customer name *')),
      const SizedBox(height: 12), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile number *')),
      const SizedBox(height: 12), TextField(controller: address, maxLines: 2, decoration: const InputDecoration(labelText: 'Address (optional)')),
      const SizedBox(height: 22), FilledButton(onPressed: saving ? null : _save, child: Text(saving ? 'Saving...' : 'Save customer'))
    ]));
}

class CustomerPage extends StatefulWidget {
  final Map<String,Object?> customer;
  const CustomerPage({super.key, required this.customer});
  @override State<CustomerPage> createState() => _CustomerPageState();
}
class _CustomerPageState extends State<CustomerPage> {
  Future<void> _add(String kind) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => TxDialog(kind: kind, customerId: widget.customer['id'] as int));
    if (ok == true) setState(() {});
  }
  Future<void> _statement(List<Map<String,Object?>> txs) async {
    final c = widget.customer;
    final b = StringBuffer('MERA KHATA - CUSTOMER STATEMENT\n${c['name']}\n${c['phone']}\n\n');
    double balance = 0;
    for (final t in txs.reversed) {
      final credit = t['kind'] == 'credit'; final amount = (t['amount'] as num).toDouble();
      balance += credit ? amount : -amount;
      b.writeln('${dateFmt.format(DateTime.parse(t['created_at'] as String))} | ${credit ? 'Credit' : 'Payment'} | ${money.format(amount)} | Balance ${money.format(balance)} | ${t['note'] ?? ''}');
    }
    b.writeln('\nOutstanding: ${money.format(balance)}');
    await Share.share(b.toString(), subject: 'Khata statement - ${c['name']}');
  }
  @override Widget build(BuildContext context) {
    final c = widget.customer; final id = c['id'] as int;
    return Scaffold(appBar: AppBar(title: const Text('Customer account'), actions: [
      IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () async {
        final ok = await Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerForm(customer: c)));
        if (ok == true && mounted) setState(() {});
      }),
      IconButton(icon: const Icon(Icons.share_outlined), onPressed: () async {
        final tx = await KhataDb.instance.transactions(id); await _statement(tx);
      })
    ]),
    body: FutureBuilder<List<Map<String,Object?>>>(future: KhataDb.instance.transactions(id), builder: (context, snap) {
      final txs = snap.data ?? [];
      double balance = 0;
      for (final t in txs) balance += (t['kind'] == 'credit' ? 1 : -1) * (t['amount'] as num).toDouble();
      return ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [_avatar(c['photo'] as String?, c['name'] as String), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c['name'] as String, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)), Text(c['phone'] as String, style: const TextStyle(color: Colors.black54)),
          if ((c['address'] as String? ?? '').isNotEmpty) Text(c['address'] as String, style: const TextStyle(color: Colors.black54))
        ]))]),
        const SizedBox(height: 18), Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: green, borderRadius: BorderRadius.circular(20)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('CURRENT BALANCE', style: TextStyle(color: Colors.white70, letterSpacing: 1)),
            const SizedBox(height: 6), Text(money.format(balance), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold))
          ])),
        const SizedBox(height: 14), Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => _add('credit'), icon: const Icon(Icons.add), label: const Text('Add udhaar'))),
          const SizedBox(width: 10), Expanded(child: FilledButton.tonalIcon(onPressed: balance <= 0 ? null : () => _add('payment'), icon: const Icon(Icons.payments_outlined), label: const Text('Receive payment')))
        ]),
        const SizedBox(height: 22), const Text('Transaction history', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: 8),
        if (txs.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No transactions yet.')),
        ...txs.map((t) {
          final credit = t['kind'] == 'credit'; final dt = DateTime.parse(t['created_at'] as String);
          return Card(color: Colors.white, elevation: 0, child: ListTile(
            leading: CircleAvatar(backgroundColor: credit ? const Color(0xFFFFEEEE) : const Color(0xFFE8F5EC),
              child: Icon(credit ? Icons.arrow_upward : Icons.arrow_downward, color: credit ? Colors.red : green)),
            title: Text('${credit ? 'Udhaar added' : 'Payment received'} · ${money.format((t['amount'] as num).toDouble())}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${dateFmt.format(dt)}\n${t['method']}${(t['note'] as String? ?? '').isNotEmpty ? ' · ${t['note']}' : ''}${t['due_date'] != null ? '\nDue: ${DateFormat('dd MMM yyyy').format(DateTime.parse(t['due_date'] as String))}' : ''}'),
            isThreeLine: true,
          ));
        })
      ]);
    }));
  }
}

class TxDialog extends StatefulWidget {
  final String kind;
  final int customerId;
  const TxDialog({super.key, required this.kind, required this.customerId});
  @override State<TxDialog> createState() => _TxDialogState();
}
class _TxDialogState extends State<TxDialog> {
  final amount = TextEditingController(), note = TextEditingController();
  String method = 'Cash';
  DateTime? due;
  bool saving = false;
  @override Widget build(BuildContext context) {
    final credit = widget.kind == 'credit';
    return AlertDialog(title: Text(credit ? 'Add udhaar' : 'Receive payment'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (₹)')),
        const SizedBox(height: 10), DropdownButtonFormField<String>(value: method, decoration: const InputDecoration(labelText: 'Payment method'), items: ['Cash','UPI','Bank transfer','Other'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => method = v ?? 'Cash')),
        const SizedBox(height: 10), TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note / items (optional)')),
        if (credit) ...[
          const SizedBox(height: 10), ListTile(contentPadding: EdgeInsets.zero, title: const Text('Payment due date'), subtitle: Text(due == null ? 'Not set' : DateFormat('dd MMM yyyy').format(due!)),
            trailing: IconButton(icon: const Icon(Icons.calendar_month), onPressed: () async {
              final d = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)), initialDate: DateTime.now().add(const Duration(days: 7)));
              if (d != null) setState(() => due = d);
            }))
        ]
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: saving ? null : () async {
          final value = double.tryParse(amount.text.trim());
          if (value == null || value <= 0) return;
          setState(() => saving = true);
          await KhataDb.instance.addTx(widget.customerId, widget.kind, value, method, note.text.trim(), due);
          if (context.mounted) Navigator.pop(context, true);
        }, child: Text(saving ? 'Saving...' : 'Save'))
      ]);
  }
}

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Reports & summary')),
    body: FutureBuilder<Map<String,Object?>>(future: KhataDb.instance.totals(), builder: (context, snap) {
      final t = snap.data ?? {};
      final credits = (t['credits'] as num?)?.toDouble() ?? 0;
      final received = (t['received'] as num?)?.toDouble() ?? 0;
      final due = (t['outstanding'] as num?)?.toDouble() ?? 0;
      return ListView(padding: const EdgeInsets.all(18), children: [
        _reportCard('Total outstanding', money.format(due), Icons.account_balance_wallet_outlined),
        _reportCard('Total credit recorded', money.format(credits), Icons.add_shopping_cart_outlined),
        _reportCard('Total payments received', money.format(received), Icons.payments_outlined),
        _reportCard('Registered customers', '${t['customers'] ?? 0}', Icons.people_outline),
        const SizedBox(height: 10),
        const Text('These are lifetime totals. Daily date-filtered reporting can be added in the next release.', style: TextStyle(color: Colors.black54))
      ]);
    }));
  Widget _reportCard(String title, String value, IconData icon) => Card(color: Colors.white, elevation: 0, child: ListTile(
    leading: CircleAvatar(backgroundColor: const Color(0xFFE8F5EC), child: Icon(icon, color: green)),
    title: Text(title), trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))));
}
