
// SignalScout — Flutter Android app
// Works on first run with Alpha Vantage `demo` key (MSFT).
// Add your own free API key in Settings to use any symbol.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

const String kDefaultApiKey = 'demo'; // MSFT-only demo key
const String kDefaultSymbol = 'MSFT';
const String kDefaultInterval = '15min'; // 1min,5min,15min,30min,60min

class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  Candle(this.time, this.open, this.high, this.low, this.close, this.volume);
}

class SignalSnapshot {
  final double price, rsi;
  final bool rsiCross30Up, rsiCross70Up;
  final bool emaBullCross, emaBearCross;
  final bool macdBullCross, macdBearCross;
  final bool breakout20d, inSqueeze;
  SignalSnapshot({
    required this.price,
    required this.rsi,
    required this.rsiCross30Up,
    required this.rsiCross70Up,
    required this.emaBullCross,
    required this.emaBearCross,
    required this.macdBullCross,
    required this.macdBearCross,
    required this.breakout20d,
    required this.inSqueeze,
  });
}

// ---------------- INDICATORS ----------------
List<double> ema(List<double> values, int span) {
  final k = 2 / (span + 1);
  final out = <double>[];
  double? prev;
  for (final v in values) {
    prev = (prev == null) ? v : (v - prev) * k + prev;
    out.add(prev!);
  }
  return out;
}

List<double> rsi(List<double> closes, {int length = 14}) {
  if (closes.length < length + 1) return List.filled(closes.length, 50);
  final rsis = List<double>.filled(closes.length, 50);
  double gain = 0, loss = 0;
  for (int i = 1; i <= length; i++) {
    final ch = closes[i] - closes[i - 1];
    if (ch >= 0) gain += ch; else loss -= ch;
  }
  double avgGain = gain / length, avgLoss = loss / length;
  rsis[length] = avgLoss == 0 ? 100 : 100 - (100 / (1 + (avgGain / avgLoss)));
  for (int i = length + 1; i < closes.length; i++) {
    final ch = closes[i] - closes[i - 1];
    final g = ch > 0 ? ch : 0.0;
    final l = ch < 0 ? -ch : 0.0;
    avgGain = (avgGain * (length - 1) + g) / length;
    avgLoss = (avgLoss * (length - 1) + l) / length;
    final rs = avgLoss == 0 ? double.infinity : (avgGain / avgLoss);
    rsis[i] = 100 - (100 / (1 + rs));
  }
  return rsis;
}

class MacdResult { 
  final List<double> macd, signal, hist; 
  MacdResult(this.macd, this.signal, this.hist);
}

MacdResult macd(List<double> closes, {int fast=12, int slow=26, int signal=9}) {
  final fastE = ema(closes, fast);
  final slowE = ema(closes, slow);
  final macdLine = List<double>.generate(closes.length, (i) => fastE[i] - slowE[i]);
  final signalLine = ema(macdLine, signal);
  final hist = List<double>.generate(closes.length, (i) => macdLine[i] - signalLine[i]);
  return MacdResult(macdLine, signalLine, hist);
}

class BB { final List<double> mid, up, low; BB(this.mid, this.up, this.low); }

BB bollinger(List<double> closes, {int length=20, double mult=2}) {
  final mid = <double>[]; final up = <double>[]; final low = <double>[];
  for (int i=0; i<closes.length; i++) {
    if (i < length-1) { mid.add(closes[i]); up.add(closes[i]); low.add(closes[i]); continue; }
    final window = closes.sublist(i-length+1, i+1);
    final m = window.reduce((a,b)=>a+b)/window.length;
    double varSum = 0; for (final v in window) { varSum += (v-m)*(v-m); }
    final sd = math.sqrt(varSum / window.length);
    mid.add(m); up.add(m + mult*sd); low.add(m - mult*sd);
  }
  return BB(mid, up, low);
}

class Keltner { final List<double> mid, up, low; Keltner(this.mid,this.up,this.low); }

Keltner keltner(List<double> highs, List<double> lows, List<double> closes, {int length=20, double mult=1.5}) {
  final mid = ema(closes, length);
  final tr = <double>[];
  for (int i=0; i<closes.length; i++) {
    final h = highs[i], l = lows[i];
    final pc = i==0 ? closes[i] : closes[i-1];
    tr.add(math.max(h-l, math.max((h-pc).abs(), (l-pc).abs())));
  }
  final atr = <double>[];
  for (int i=0; i<tr.length; i++) {
    if (i==0) atr.add(tr[i]); else atr.add((atr[i-1]*(length-1)+tr[i])/length);
  }
  final up = List<double>.generate(closes.length, (i) => mid[i] + mult*atr[i]);
  final low = List<double>.generate(closes.length, (i) => mid[i] - mult*atr[i]);
  return Keltner(mid, up, low);
}

bool isBreakout20d(List<double> closes) {
  const lookback = 20;
  if (closes.length < lookback) return false;
  final mx = closes.sublist(closes.length - lookback).reduce((a,b)=> a>b?a:b);
  return closes.last >= mx;
}

// ---------------- API ----------------
Future<List<Candle>> fetchIntraday(String symbol, String interval, String apiKey) async {
  final uri = Uri.parse('https://www.alphavantage.co/query?function=TIME_SERIES_INTRADAY&symbol=$symbol&interval=$interval&outputsize=full&apikey=$apiKey');
  final res = await http.get(uri);
  if (res.statusCode != 200) { throw Exception('HTTP ${res.statusCode}'); }
  final json = jsonDecode(res.body);
  final key = 'Time Series ($interval)';
  if (!json.containsKey(key)) throw Exception(json['Note'] ?? json['Error Message'] ?? 'Unexpected response');
  final map = (json[key] as Map<String, dynamic>);
  final entries = map.entries.map((e){
    final t = DateTime.parse(e.key);
    final o = double.parse(e.value['1. open']);
    final h = double.parse(e.value['2. high']);
    final l = double.parse(e.value['3. low']);
    final c = double.parse(e.value['4. close']);
    final v = double.parse(e.value['5. volume']);
    return Candle(t,o,h,l,c,v);
  }).toList();
  entries.sort((a,b)=> a.time.compareTo(b.time));
  return entries;
}

SignalSnapshot computeSignals(List<Candle> data) {
  final closes = data.map((c)=>c.close).toList();
  final highs = data.map((c)=>c.high).toList();
  final lows  = data.map((c)=>c.low ).toList();

  final ema9 = ema(closes, 9);
  final ema21 = ema(closes, 21);
  final r = rsi(closes, length: 14);
  final m = macd(closes);
  final bb = bollinger(closes);
  final kel = keltner(highs, lows, closes);
  final inSqueeze = bb.up.last < kel.up.last && bb.low.last > kel.low.last;

  bool crossUp(List<double> a, List<double> b) => a[a.length-2] <= b[b.length-2] && a.last > b.last;
  bool crossDown(List<double> a, List<double> b) => a[a.length-2] >= b[b.length-2] && a.last < b.last;

  return SignalSnapshot(
    price: closes.last,
    rsi: r.last,
    rsiCross30Up: r[r.length-2] < 30 && r.last >= 30,
    rsiCross70Up: r[r.length-2] < 70 && r.last >= 70,
    emaBullCross: crossUp(ema9, ema21),
    emaBearCross: crossDown(ema9, ema21),
    macdBullCross: crossUp(m.macd, m.signal),
    macdBearCross: crossDown(m.macd, m.signal),
    breakout20d: isBreakout20d(closes),
    inSqueeze: inSqueeze,
  );
}

// ---------------- UI ----------------
void main() => runApp(const SignalScoutApp());

class SignalScoutApp extends StatefulWidget { const SignalScoutApp({super.key}); @override State<SignalScoutApp> createState()=> _SignalScoutAppState(); }

class _SignalScoutAppState extends State<SignalScoutApp> {
  ThemeMode mode = ThemeMode.dark;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignalScout',
      themeMode: mode,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blueGrey),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(colorScheme: const ColorScheme.dark(primary: Colors.teal)),
      home: HomeScreen(onToggleTheme: () => setState(()=> mode = mode==ThemeMode.dark? ThemeMode.light: ThemeMode.dark)),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const HomeScreen({super.key, required this.onToggleTheme});
  @override State<HomeScreen> createState()=> _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String symbol = kDefaultSymbol;
  String interval = kDefaultInterval;
  String apiKey = kDefaultApiKey;

  bool isLoading = false;
  List<Candle> candles = [];
  SignalSnapshot? snap;
  String? error;

  Future<void> _load() async {
    setState(()=> isLoading = true); error = null; snap = null;
    try {
      final data = await fetchIntraday(symbol, interval, apiKey);
      if (data.length < 50) { throw Exception('Not enough data returned. Try a different interval.'); }
      final s = computeSignals(data);
      setState((){ candles = data; snap = s; });
    } catch (e) {
      setState(()=> error = e.toString());
    } finally { setState(()=> isLoading = false); }
  }

  @override void initState(){ super.initState(); _load(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SignalScout'),
        actions: [
          IconButton(onPressed: widget.onToggleTheme, icon: const Icon(Icons.brightness_6)),
          IconButton(onPressed: _openSettings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _TopControls(
              symbol: symbol,
              interval: interval,
              onRefresh: _load,
              onSymbolChanged: (v){ setState(()=> symbol = v.toUpperCase()); },
              onIntervalChanged: (v){ setState(()=> interval = v); },
            ),
            const SizedBox(height: 12),
            if (isLoading) const LinearProgressIndicator(),
            if (error != null) _ErrorBox(msg: error!),
            if (!isLoading && snap != null) ...[
              _SignalCards(snapshot: snap!),
              const SizedBox(height: 12),
              Expanded(child: _PriceChart(candles: candles)),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _load,
        label: const Text('Refresh'),
        icon: const Icon(Icons.refresh),
      ),
    );
  }

  void _openSettings() async {
    final result = await showModalBottomSheet<(String,String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SettingsSheet(apiKey: apiKey, symbol: symbol),
    );
    if (result != null) {
      setState(() { apiKey = result.$1; symbol = result.$2; });
      _load();
    }
  }
}

class _SettingsSheet extends StatefulWidget {
  final String apiKey; final String symbol;
  const _SettingsSheet({required this.apiKey, required this.symbol});
  @override State<_SettingsSheet> createState()=> _SettingsSheetState();
}
class _SettingsSheetState extends State<_SettingsSheet> {
  late TextEditingController keyCtrl; late TextEditingController symCtrl;
  @override void initState(){ super.initState(); keyCtrl = TextEditingController(text: widget.apiKey); symCtrl = TextEditingController(text: widget.symbol); }
  @override void dispose(){ keyCtrl.dispose(); symCtrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context){
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: 'Alpha Vantage API Key (free)')), 
          const SizedBox(height: 8),
          TextField(controller: symCtrl, decoration: const InputDecoration(labelText: 'Default Symbol (e.g., AAPL, SPY)')), 
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: ()=> Navigator.pop(context, (keyCtrl.text.trim(), symCtrl.text.trim().toUpperCase())), icon: const Icon(Icons.save), label: const Text('Save')), 
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}

class _TopControls extends StatelessWidget {
  final String symbol; final String interval; final VoidCallback onRefresh; final ValueChanged<String> onSymbolChanged; final ValueChanged<String> onIntervalChanged;
  const _TopControls({required this.symbol, required this.interval, required this.onRefresh, required this.onSymbolChanged, required this.onIntervalChanged});
  @override Widget build(BuildContext context) {
    final symCtrl = TextEditingController(text: symbol);
    return Row(children: [
      Expanded(child: TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Symbol'),
        controller: symCtrl,
        onSubmitted: onSymbolChanged,
      )),
      const SizedBox(width: 8),
      DropdownButton<String>(
        value: interval,
        items: const [
          DropdownMenuItem(value: '1min', child: Text('1m')),
          DropdownMenuItem(value: '5min', child: Text('5m')),
          DropdownMenuItem(value: '15min', child: Text('15m')),
          DropdownMenuItem(value: '30min', child: Text('30m')),
          DropdownMenuItem(value: '60min', child: Text('60m')),
        ],
        onChanged: (v){ if(v!=null) onIntervalChanged(v); },
      ),
      const SizedBox(width: 8),
      FilledButton.icon(onPressed: onRefresh, icon: const Icon(Icons.play_arrow), label: const Text('Go')),
    ]);
  }
}

class _ErrorBox extends StatelessWidget {
  final String msg; const _ErrorBox({required this.msg});
  @override Widget build(BuildContext context) {
    return Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [const Icon(Icons.error_outline), const SizedBox(width: 8), Expanded(child: Text(msg))]),
    ));
  }
}

class _SignalCards extends StatelessWidget {
  final SignalSnapshot snapshot; const _SignalCards({required this.snapshot});
  @override Widget build(BuildContext context) {
    final chips = <Widget>[
      _sig('RSI', snapshot.rsi.toStringAsFixed(1)),
      _flag('RSI↑30', snapshot.rsiCross30Up),
      _flag('RSI↑70', snapshot.rsiCross70Up),
      _flag('EMA 9/21 ↑', snapshot.emaBullCross),
      _flag('EMA 9/21 ↓', snapshot.emaBearCross),
      _flag('MACD ↑', snapshot.macdBullCross),
      _flag('MACD ↓', snapshot.macdBearCross),
      _flag('20d Breakout', snapshot.breakout20d),
      _flag('Squeeze', snapshot.inSqueeze),
    ];
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          Text('Price: ${snapshot.price.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          ...chips,
        ]),
      ),
    );
  }

  Widget _sig(String label, String value){
    return Chip(label: Text('$label $value'));
  }
  Widget _flag(String label, bool on){
    return FilterChip(label: Text(label), selected: on, onSelected: (_){ });
  }
}

class _PriceChart extends StatelessWidget {
  final List<Candle> candles; const _PriceChart({required this.candles});
  @override Widget build(BuildContext context) {
    if (candles.isEmpty) return const SizedBox();
    final spots = candles.map((c)=> FlSpot(c.time.millisecondsSinceEpoch.toDouble(), c.close)).toList();
    final minX = spots.first.x; final maxX = spots.last.x;
    double minY = spots.first.y, maxY = spots.first.y;
    for (final s in spots) { if (s.y < minY) minY = s.y; if (s.y > maxY) maxY = s.y; }
    final fmt = DateFormat('MM/dd HH:mm');

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LineChart(
          LineChartData(
            minX: minX, maxX: maxX, minY: minY*0.995, maxY: maxY*1.005,
            gridData: const FlGridData(show: false),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 28, interval: (maxX-minX)/4, getTitlesWidget: (value, meta){
                final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                return SideTitleWidget(axisSide: meta.axisSide, child: Text(fmt.format(dt), style: const TextStyle(fontSize: 10)));
              })),
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(spots: spots, isCurved: true, dotData: const FlDotData(show: false), barWidth: 2),
            ],
          ),
        ),
      ),
    );
  }
}
