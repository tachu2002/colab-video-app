import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api.dart';
import 'store.dart';

class GeneratePage extends StatefulWidget {
  final AppState state;
  const GeneratePage({super.key, required this.state});
  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  String mode = 't2v';
  final ja = TextEditingController(), en = TextEditingController(), seedCtl = TextEditingController();
  final List<XFile> images = [];
  int seconds = 5;
  String ratio = '9:16';
  String preset = 'high';
  bool seedFixed = false;
  int count = 1;
  String lora = '';
  double loraStrength = 0.8;
  List<String> loraOpts = [];

  bool running = false, cancel = false, busyText = false;
  double pct = 0;
  String stage = '';
  String? error;
  int doneCount = 0;
  DateTime? startedAt;
  Timer? _tick;

  AppState get s => widget.state;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    s.addListener(_onState);
    _loadLoras();
  }

  @override
  void dispose() {
    s.removeListener(_onState);
    _tick?.cancel();
    super.dispose();
  }

  void _onState() {
    final r = s.regenerateFrom;
    if (r != null) {
      s.regenerateFrom = null;
      setState(() {
        mode = r.mode; ja.text = r.ja; en.text = r.en; seconds = r.seconds;
        ratio = r.ratio; preset = r.preset; lora = r.lora;
        seedFixed = true; seedCtl.text = r.seed.toString();
        images.clear();
        error = (r.mode != 't2v') ? '画像は引き継がれません。もう一度えらんでください' : null;
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadLoras() async {
    final st = s.status;
    if (st == null) return;
    setState(() => loraOpts = st.loras);
    if (st.isRunning && st.loras.isEmpty) {
      try {
        final l = await HelperApi(st).loras();
        if (mounted) setState(() => loraOpts = l);
      } catch (_) {}
    }
  }

  PresetInfo _preset() {
    final list = s.status?.presets ?? [];
    return list.firstWhere((p) => p.id == preset, orElse: () => PresetInfo(preset, preset, 10, 12, false));
  }

  int get maxImages => mode == 'i2v' ? 1 : (mode == 'ref2v' ? 3 : 0);

  Future<void> _pick() async {
    final room = maxImages - images.length;
    if (room <= 0) return;
    final files = await _picker.pickMultiImage(maxWidth: 1280, maxHeight: 1280, imageQuality: 90, limit: room < 2 ? 2 : room);
    if (files.isEmpty) return;
    setState(() => images.addAll(files.take(room)));
  }

  Future<void> _random() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    setState(() { busyText = true; error = null; });
    try {
      final r = await HelperApi(st).random();
      ja.text = r['ja']!; en.text = r['en']!;
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  Future<void> _translate() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    if (ja.text.trim().isEmpty) return;
    setState(() { busyText = true; error = null; });
    try { en.text = await HelperApi(st).translate(ja.text.trim()); } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  String _stageOf(double p) {
    if (p < 5) return '準備中';
    if (p < 35) return '1段目（下書きを作っています）';
    if (p < 90) return '2段目（高画質にしています）';
    return '書き出し中';
  }

  Future<void> _run() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '接続できていません。接続タブで再接続してください'); return; }
    if (mode != 't2v' && images.isEmpty) { setState(() => error = '画像をえらんでください'); return; }
    if (ja.text.trim().isEmpty && en.text.trim().isEmpty) { setState(() => error = 'プロンプトを入れてください（ランダム生成も使えます）'); return; }
    final p = _preset();
    if (seconds > p.maxSec) seconds = p.maxSec;
    setState(() { running = true; cancel = false; error = null; doneCount = 0; pct = 0; stage = '準備中'; startedAt = DateTime.now(); });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    final api = HelperApi(st);
    final comfy = ComfyApi(st.comfyUrl);
    try {
      if (en.text.trim().isEmpty) {
        en.text = await api.translate(ja.text.trim());
      }
      final b64 = <String>[];
      for (final f in images.take(maxImages)) { b64.add(base64Encode(await f.readAsBytes())); }
      for (var i = 0; i < count && !cancel; i++) {
        final rnd = Random();
        final seed = seedFixed ? (int.tryParse(seedCtl.text) ?? 0) + i : rnd.nextInt(1 << 31);
        final cid = 'app${DateTime.now().millisecondsSinceEpoch}${rnd.nextInt(9999)}';
        setState(() { pct = 0; stage = '準備中'; });
        WebSocketChannel? ch;
        StreamSubscription? sub;
        try {
          ch = WebSocketChannel.connect(comfy.wsUri(cid));
          sub = ch.stream.listen((m) {
            if (m is! String) return;
            try {
              final j = jsonDecode(m);
              if (j['type'] == 'progress') {
                final d = j['data'];
                final v = (d['value'] as num).toDouble(), mx = (d['max'] as num).toDouble();
                final node = d['node']?.toString();
                double np = pct;
                if (node == '132') np = 5 + 30 * v / mx;
                else if (node == '198') np = 35 + 55 * v / mx;
                if (np > pct && mounted) setState(() { pct = np; stage = _stageOf(np); });
              }
            } catch (_) {}
          }, onError: (_) {}, cancelOnError: false);
        } catch (_) {}
        final pid = await api.generate(
          mode: mode, promptEn: en.text.trim(), seconds: seconds.toDouble(), aspect: ratio,
          preset: preset, seed: seed, imagesB64: b64, lora: lora, loraStrength: loraStrength, clientId: cid,
        );
        VideoRef? ref;
        while (ref == null && !cancel) {
          await Future.delayed(const Duration(seconds: 3));
          ref = await comfy.result(pid);
        }
        sub?.cancel();
        ch?.sink.close();
        if (cancel || ref == null) break;
        setState(() { pct = 95; stage = '端末に保存中'; });
        final id = '${DateTime.now().millisecondsSinceEpoch}';
        final path = await s.saveVideo(id, comfy.viewUri(ref));
        s.addHistory(HistoryItem(
          id: id, ja: ja.text.trim(), en: en.text.trim(), mode: mode, ratio: ratio, preset: preset,
          lora: lora, path: path, seconds: seconds, seed: seed, createdAt: DateTime.now(),
        ));
        setState(() { doneCount = i + 1; pct = 100; });
      }
    } catch (e) {
      error = e.toString();
    } finally {
      _tick?.cancel();
      if (mounted) setState(() { running = false; });
    }
  }

  Future<void> _cancel() async {
    cancel = true;
    final st = s.status;
    if (st != null) await ComfyApi(st.comfyUrl).interrupt();
    if (mounted) setState(() => stage = '中止しています');
  }

  Widget _chips<T>(List<T> values, T cur, String Function(T) label, void Function(T) pick) => Wrap(
        spacing: 8, runSpacing: 4,
        children: values.map((v) => ChoiceChip(label: Text(label(v)), selected: v == cur, onSelected: running ? null : (_) => pick(v))).toList(),
      );

  @override
  Widget build(BuildContext context) {
    final st = s.status;
    final p = _preset();
    final presets = (st?.presets.isNotEmpty ?? false) ? st!.presets : [PresetInfo('high', '高画質 960×1728', 10, 12, true)];
    final durs = [5, 8, 10].where((d) => d <= p.maxSec).toList();
    if (!durs.contains(seconds)) seconds = durs.last;
    final elapsed = startedAt == null ? 0 : DateTime.now().difference(startedAt!).inSeconds;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('生成', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 't2v', label: Text('文字')),
          ButtonSegment(value: 'i2v', label: Text('画像')),
          ButtonSegment(value: 'ref2v', label: Text('参照画像')),
        ],
        selected: {mode},
        onSelectionChanged: running ? null : (v) => setState(() { mode = v.first; if (images.length > maxImages) images.removeRange(maxImages, images.length); }),
      ),
      if (maxImages > 0) ...[
        const SizedBox(height: 8),
        SizedBox(height: 96, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (var i = 0; i < images.length; i++)
            Stack(children: [
              Padding(padding: const EdgeInsets.only(right: 8), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: FutureBuilder(
                future: images[i].readAsBytes(),
                builder: (c, snap) => snap.hasData ? Image.memory(snap.data!, width: 96, height: 96, fit: BoxFit.cover) : const SizedBox(width: 96, height: 96),
              ))),
              Positioned(right: 8, top: 0, child: InkWell(onTap: running ? null : () => setState(() => images.removeAt(i)), child: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)))),
            ]),
          if (images.length < maxImages)
            InkWell(onTap: running ? null : _pick, child: Container(width: 96, height: 96, decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.add_photo_alternate_outlined))),
        ])),
        Text(mode == 'i2v' ? '最初のフレームになる画像を1枚' : '参照する画像を最大3枚（人物や物など）', style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
      const SizedBox(height: 12),
      TextField(controller: ja, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'プロンプト（日本語）', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: busyText || running ? null : _random, icon: const Icon(Icons.casino_outlined), label: const Text('ランダム生成'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(onPressed: busyText || running ? null : _translate, icon: const Icon(Icons.translate), label: const Text('英語に変換'))),
      ]),
      if (busyText) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      const SizedBox(height: 8),
      TextField(controller: en, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: '英語プロンプト（直せます）', border: OutlineInputBorder())),
      const SizedBox(height: 16),
      const Text('長さ'),
      _chips<int>(durs, seconds, (v) => '$v秒', (v) => setState(() => seconds = v)),
      const SizedBox(height: 8),
      const Text('縦横'),
      _chips<String>(['9:16', '16:9', '1:1'], ratio, (v) => v == '9:16' ? '縦 9:16' : v == '16:9' ? '横 16:9' : '正方形', (v) => setState(() => ratio = v)),
      const SizedBox(height: 8),
      const Text('画質（目安の時間）'),
      _chips<String>(presets.map((e) => e.id).toList(), preset, (id) { final q = presets.firstWhere((e) => e.id == id); return '${q.label}（約${q.estMin}分）'; }, (v) => setState(() => preset = v)),
      const SizedBox(height: 8),
      Row(children: [
        const Text('シード'),
        const SizedBox(width: 8),
        ChoiceChip(label: const Text('ランダム'), selected: !seedFixed, onSelected: running ? null : (_) => setState(() => seedFixed = false)),
        const SizedBox(width: 8),
        ChoiceChip(label: const Text('固定'), selected: seedFixed, onSelected: running ? null : (_) => setState(() => seedFixed = true)),
        const SizedBox(width: 8),
        if (seedFixed) Expanded(child: TextField(controller: seedCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, hintText: '数字'))),
      ]),
      Row(children: [
        const Text('枚数'),
        IconButton(onPressed: running || count <= 1 ? null : () => setState(() => count--), icon: const Icon(Icons.remove_circle_outline)),
        Text('$count'),
        IconButton(onPressed: running || count >= 4 ? null : () => setState(() => count++), icon: const Icon(Icons.add_circle_outline)),
        Text(count > 1 ? '（約${p.estMin * count}分）' : '', style: const TextStyle(color: Colors.grey)),
      ]),
      if (loraOpts.isNotEmpty) ...[
        DropdownButtonFormField<String>(
          value: loraOpts.contains(lora) ? lora : '',
          decoration: const InputDecoration(labelText: 'LoRA'),
          items: [const DropdownMenuItem(value: '', child: Text('なし')), ...loraOpts.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis)))],
          onChanged: running ? null : (v) => setState(() => lora = v ?? ''),
        ),
        if (lora.isNotEmpty) Slider(value: loraStrength, min: 0.1, max: 1.5, divisions: 14, label: loraStrength.toStringAsFixed(1), onChanged: running ? null : (v) => setState(() => loraStrength = v)),
      ],
      const SizedBox(height: 12),
      if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
      if (!running) FilledButton.icon(onPressed: _run, icon: const Icon(Icons.play_arrow), label: Text(count > 1 ? '$count本つくる' : '生成する')),
      if (running) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${pct.floor()}%　$stage', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: pct <= 0 ? null : pct / 100, minHeight: 10),
        const SizedBox(height: 8),
        Text('経過 ${elapsed ~/ 60}分${elapsed % 60}秒${count > 1 ? '　（$doneCount/$count本 完了）' : ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _cancel, child: const Text('中止する')),
      ]))),
      if (!running && doneCount > 0 && error == null)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('できました。履歴タブで見られます。', style: TextStyle(color: Colors.greenAccent))),
    ]);
  }
}
