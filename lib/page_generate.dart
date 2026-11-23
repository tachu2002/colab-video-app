import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api.dart';
import 'widgets.dart';
import 'store.dart';
import 'page_models.dart';
import 'page_refmod.dart';

class GeneratePage extends StatefulWidget {
  final AppState state;
  const GeneratePage({super.key, required this.state});
  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  String mode = 't2v';
  final ja = TextEditingController(), en = TextEditingController(), lines = TextEditingController(), hair = TextEditingController(), outfit = TextEditingController(), seedCtl = TextEditingController();
  final List<XFile> images = [];
  XFile? refVideo;
  String vpStage = '';
  bool vpNoLook = true;
  int seconds = 5;
  String ratio = '9:16';
  String preset = 'high';
  bool seedFixed = false;
  int count = 1;
  String lora = '';
  double loraStrength = 0.8;
  List<String> loraOpts = [];
  List<String> refOpts = [];
  final Map<String, double> refSel = {};

  bool running = false, cancel = false, busyText = false;
  double pct = 0;
  String stage = '';
  Uint8List? preview;
  int previewCount = 0;
  DateTime? previewAt;
  String previewStage = '';
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
    if (st.isRunning) {
      try {
        final l = await HelperApi(st).loras();
        if (mounted) setState(() => loraOpts = l);
      } catch (_) {}
      try {
        final r = await HelperApi(st).refmods();
        if (mounted) setState(() { refOpts = r; refSel.removeWhere((k, _) => !r.contains(k)); });
      } catch (_) {}
    }
  }

  PresetInfo _preset() {
    final list = s.status?.presets ?? [];
    return list.firstWhere((p) => p.id == preset, orElse: () => PresetInfo(preset, preset, 10, 12, false));
  }

  int get maxImages => mode == 'i2v' ? 1 : (mode == 'ref2v' ? 3 : 0);

  // 参照動画の中身を読み取って、H3用の英語プロンプトを作る
  Future<void> _videoPrompt() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    if (refVideo == null) { setState(() => error = '先に動画をえらんでください'); return; }
    setState(() { busyText = true; error = null; vpStage = '動画を送っています'; });
    try {
      final vb = await refVideo!.readAsBytes();
      if (vb.length > 60 * 1024 * 1024) throw Exception('動画が大きすぎます（60MB以下にしてください）');
      final r = await HelperApi(st).videoPrompt(base64Encode(vb), seconds, (t) { if (mounted) setState(() => vpStage = t); }, () => !mounted, noLook: vpNoLook);
      en.text = r;
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() { busyText = false; vpStage = ''; });
  }

  Future<void> _pickVideo() async {
    final f = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 15));
    if (f != null) setState(() => refVideo = f);
  }

  Future<void> _pick() async {
    final room = maxImages - images.length;
    if (room <= 0) return;
    final files = await _picker.pickMultiImage(maxWidth: 1280, maxHeight: 1280, imageQuality: 90, limit: room < 2 ? 2 : room);
    if (files.isEmpty) return;
    setState(() => images.addAll(files.take(room)));
  }

  // セリフの枠は、翻訳せずにそのまま「話す言葉」として生成時に英語プロンプトの末尾へ足す
  String _jaFull() => ja.text.trim();

  // 追記モード: ONのとき、ランダム生成・英語変換は、英語の枠の今の文章を消さずに後ろへ足す
  bool appendMode = true;
  String _mergeEn(String old, String add) {
    if (!appendMode || old.trim().isEmpty) return add;
    return '${old.trim()} $add';
  }

  // セリフ欄に書いた日本語は、翻訳せずにそのまま「話す言葉」として英語プロンプトに足す
  String _withLines(String p) {
    var r = p;
    final t = lines.text.trim();
    if (t.isNotEmpty) r += ' The character speaks in Japanese, saying exactly: "$t"';
    return r;
  }

  Future<void> _random() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    setState(() { busyText = true; error = null; });
    try {
      final r = await HelperApi(st).random(seconds);
      ja.text = appendMode && ja.text.trim().isNotEmpty ? '${ja.text.trim()}。${r['ja']!}' : r['ja']!; en.text = _mergeEn(en.text, r['en']!);
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  // 髪型・服装のイメージ（日本語）を、H3向けの英語に変換して、いまの英語プロンプトへ追記する
  Future<void> _addDetail() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    if (hair.text.trim().isEmpty && outfit.text.trim().isEmpty) { setState(() => error = '髪型か服装を入れてください'); return; }
    if (en.text.trim().isEmpty) { setState(() => error = '先に英語のプロンプトを作ってください（英語に変換／ランダム生成）'); return; }
    setState(() { busyText = true; error = null; });
    try {
      en.text = await HelperApi(st).addDetail(en.text, hair.text.trim(), outfit.text.trim());
      hair.clear(); outfit.clear();
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  Future<void> _translate() async {
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '先に接続タブで接続してください'); return; }
    if (_jaFull().isEmpty) return;
    setState(() { busyText = true; error = null; });
    try { en.text = _mergeEn(en.text, await HelperApi(st).translate(_jaFull(), seconds)); } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  String _stageOf(double p) {
    if (p < 5) return '準備中';
    if (p < 35) return '1段目（下書きを作っています）';
    if (p < 90) return '2段目（高画質にしています）';
    return '書き出し中';
  }

  Future<void> _run() async {
    await s.ensureFresh();
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '接続できていません。接続タブで再接続してください'); return; }
    if (mode == 'v2v' && refVideo == null) { setState(() => error = '参照する動画をえらんでください'); return; }
    if ((mode == 'i2v' || mode == 'ref2v') && images.isEmpty) { setState(() => error = '画像をえらんでください'); return; }
    if (ja.text.trim().isEmpty && en.text.trim().isEmpty) { setState(() => error = 'プロンプトを入れてください（ランダム生成も使えます）'); return; }
    final p = _preset();
    if (seconds > p.maxSec) seconds = p.maxSec;
    setState(() { running = true; cancel = false; error = null; doneCount = 0; pct = 0; stage = '準備中'; startedAt = DateTime.now(); preview = null; previewCount = 0; });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    final api = HelperApi(st);
    final comfy = ComfyApi(st.comfyUrl);
    try {
      if (en.text.trim().isEmpty) {
        en.text = await api.translate(_jaFull(), seconds);
      }
      String vb64 = '';
      if (mode == 'v2v') {
        final vb = await refVideo!.readAsBytes();
        if (vb.length > 60 * 1024 * 1024) throw Exception('参照動画が大きすぎます（60MB以下にしてください）');
        vb64 = base64Encode(vb);
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
            if (m is! String) {
              // 途中経過の画像（先頭のコマ）。JPEG/PNGの印を探して取り出す
              try {
                final b = m is Uint8List ? m : Uint8List.fromList((m as List).cast<int>());
                if (b.length < 16) return;
                final t = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
                if (t != 1 && t != 4) return;
                var at = -1;
                for (var k = 4; k < b.length - 4 && k < 4096; k++) {
                  if ((b[k] == 0xFF && b[k + 1] == 0xD8 && b[k + 2] == 0xFF) ||
                      (b[k] == 0x89 && b[k + 1] == 0x50 && b[k + 2] == 0x4E && b[k + 3] == 0x47)) { at = k; break; }
                }
                if (at < 0) return;
                if (mounted) setState(() { preview = Uint8List.fromList(b.sublist(at)); previewCount++; previewAt = DateTime.now(); previewStage = stage; });
              } catch (_) {}
              return;
            }
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
          mode: mode, promptEn: _withLines(en.text.trim()), seconds: seconds.toDouble(), aspect: ratio,
          preset: preset, seed: seed, imagesB64: b64, lora: lora, loraStrength: loraStrength, clientId: cid, checkpoint: s.checkpoint,
          refmods: [for (final e in refSel.entries) {'name': e.key, 'strength': e.value}],
          videoB64: vb64,
        );
        VideoRef? ref;
        var failSince = DateTime.now();
        while (ref == null && !cancel) {
          await Future.delayed(const Duration(seconds: 3));
          try {
            ref = await comfy.result(pid);
            failSince = DateTime.now();
          } on ApiException {
            rethrow; // 生成そのものの失敗
          } catch (_) {
            // 通信の一時的な切断は無視して待ち続ける（5分続いたらあきらめる）
            if (DateTime.now().difference(failSince).inMinutes >= 5) rethrow;
          }
        }
        sub?.cancel();
        ch?.sink.close();
        if (cancel || ref == null) break;
        setState(() { pct = 95; stage = '端末に保存中'; });
        final id = '${DateTime.now().millisecondsSinceEpoch}';
        String? path;
        for (var t = 0; t < 4 && path == null; t++) {
          try { path = await s.saveVideo(id, comfy.viewUri(ref)); }
          catch (e) { if (t == 3) rethrow; await Future.delayed(const Duration(seconds: 3)); }
        }
        s.addHistory(HistoryItem(
          id: id, ja: ja.text.trim(), en: en.text.trim(), mode: mode, ratio: ratio, preset: preset,
          lora: lora, path: path!, seconds: seconds, seed: seed, createdAt: DateTime.now(),
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
          ButtonSegment(value: 'v2v', label: Text('参照動画')),
        ],
        selected: {mode},
        onSelectionChanged: running ? null : (v) => setState(() { mode = v.first; if (images.length > maxImages) images.removeRange(maxImages, images.length); }),
      ),
      if (mode == 'v2v') ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: running ? null : _pickVideo, icon: const Icon(Icons.video_library_outlined),
          label: Text(refVideo == null ? '参照する動画をえらぶ' : '選択中: ${refVideo!.name}')),
        const SizedBox(height: 4),
        SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('人物の外見は書かない（動き・構図だけ読み取る）', style: TextStyle(fontSize: 13)),
          subtitle: const Text('オンにすると、元の人物と別の人物にしやすくなります。髪型・服装は下の枠から「追加」で足せます', style: TextStyle(fontSize: 11)),
          value: vpNoLook, onChanged: (v) => setState(() => vpNoLook = v)),
        OutlinedButton.icon(onPressed: busyText || running || refVideo == null ? null : _videoPrompt, icon: const Icon(Icons.auto_awesome_outlined),
          label: Text(busyText && vpStage.isNotEmpty ? vpStage : '動画からプロンプトを作る（英語の枠に入ります）')),
        const Text('動きと構図を真似します。先頭の3秒だけを使います（2秒以上の動画）。人物や服装はプロンプトで指定します', style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
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
      TextField(controller: ja, minLines: 2, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: 'プロンプト（日本語）', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: hair, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '髪型（日本語）', hintText: '例: 黒髪のロングで、前髪は斜め分け', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: outfit, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '服装（日本語）', hintText: '例: 白いニットに、紺のロングスカート', border: OutlineInputBorder())),
      Row(children: [Expanded(child: Text('イメージを日本語で入れて「追加」を押すと、H3向けの英語に変換して、いまの英語プロンプトへ追記します（元の文章は変えません）', style: TextStyle(fontSize: 12, color: Colors.grey))), const SizedBox(width: 8), FilledButton.tonal(onPressed: busyText || running ? null : _addDetail, child: const Text('追加'))]),
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('追記モード（ランダム生成・英語変換で今の英語を消さない）', style: TextStyle(fontSize: 13)), value: appendMode, onChanged: (v) => setState(() => appendMode = v)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: busyText || running ? null : _random, icon: const Icon(Icons.casino_outlined), label: const Text('ランダム生成'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(onPressed: busyText || running ? null : _translate, icon: const Icon(Icons.translate), label: const Text('英語に変換'))),
      ]),
      if (busyText) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      const SizedBox(height: 8),
      TextField(controller: en, minLines: 2, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '英語プロンプト（直せます）', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: lines, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: 'セリフ（日本語・そのまま話します）', hintText: '例: こんにちは、今日もいい天気だね', border: OutlineInputBorder())),
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
      const SizedBox(height: 8),
      Text('RefMod（キャラ固定）', style: Theme.of(context).textTheme.titleSmall),
      if (refOpts.isEmpty) const Text('まだありません。下のボタンで参照画像から作れます', style: TextStyle(fontSize: 12, color: Colors.grey)),
      if (refOpts.isNotEmpty) Wrap(spacing: 8, children: [
        for (final r in refOpts)
          FilterChip(
            label: Text(r), selected: refSel.containsKey(r),
            onSelected: running ? null : (v) => setState(() { if (v) { refSel[r] = 1.0; } else { refSel.remove(r); } }),
          ),
      ]),
      for (final e in refSel.entries)
        Row(children: [
          Expanded(flex: 2, child: Text('${e.key} の強さ', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          Expanded(flex: 3, child: Slider(value: e.value, min: 0.1, max: 1.0, divisions: 9, label: e.value.toStringAsFixed(1), onChanged: running ? null : (v) => setState(() => refSel[e.key] = v))),
        ]),
      OutlinedButton.icon(
        onPressed: running ? null : () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => RefmodPage(state: s))); _loadLoras(); },
        icon: const Icon(Icons.face_retouching_natural),
        label: const Text('RefModを作る・管理'),
      ),
      OutlinedButton.icon(
        onPressed: running ? null : () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => ModelsPage(state: s))); _loadLoras(); },
        icon: const Icon(Icons.tune),
        label: Text('モデル管理（チェックポイント・LoRA）${s.checkpoint.isEmpty ? '' : '\n使用中: ${s.checkpoint}'}', textAlign: TextAlign.center),
      ),
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
      if (error != null) ErrorBox(error!, color: Colors.redAccent),
      if (!running) FilledButton.icon(onPressed: _run, icon: const Icon(Icons.play_arrow), label: Text(count > 1 ? '$count本つくる' : '生成する')),
      if (running) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${pct.floor()}%　$stage', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: pct <= 0 ? null : pct / 100, minHeight: 10),
        const SizedBox(height: 8),
        Text('経過 ${elapsed ~/ 60}分${elapsed % 60}秒${count > 1 ? '　（$doneCount/$count本 完了）' : ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Text('途中経過（1コマ目・ぼやけています）　$previewCount回目／${previewAt == null ? 0 : DateTime.now().difference(previewAt!).inSeconds}秒前に更新／$previewStage', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Center(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 360), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(preview!, gaplessPlayback: true, fit: BoxFit.contain)))),
          const SizedBox(height: 4),
          const Text('更新は各段階で4回だけです。2段目は1段目の仕上げなので、見た目はあまり変わりません。構図が崩れていたら中止してください。', style: TextStyle(fontSize: 12)),
        ] else if (pct >= 5)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('途中経過の画像を待っています…（出ない場合はColabの再起動が必要です）', style: TextStyle(fontSize: 12, color: Colors.grey))),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: cancel ? null : _cancel, icon: const Icon(Icons.stop_circle_outlined), label: Text(cancel ? '中止しています…' : '失敗なので中止する')),
      ]))),
      if (!running && doneCount > 0 && error == null)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('できました。履歴タブで見られます。', style: TextStyle(color: Colors.greenAccent))),
    ]);
  }
}
