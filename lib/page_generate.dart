import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'widgets.dart';
import 'store.dart';
import 'page_models.dart';
import 'page_refmod.dart';
import 'queue.dart';

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

  bool busyText = false;
  String? error;

  // 生成中は、英語プロンプトを作る処理（同じGPUを使う）が使えない
  bool get textLocked => s.queue.active;

  AppState get s => widget.state;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    s.addListener(_onState);
    s.queue.addListener(_onQueue);
    _loadLoras();
  }

  @override
  void dispose() {
    s.removeListener(_onState);
    s.queue.removeListener(_onQueue);
    super.dispose();
  }

  void _onQueue() { if (mounted) setState(() {}); }

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
    if (textLocked) { setState(() => error = '生成中は使えません。終わってからお試しください'); return; }
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

  // セリフ欄は、英語に変換するとき（または予約するとき）に、発音の指定つきの台詞タグとして英語プロンプトへ反映する
  String _jaFull() => ja.text.trim();

  // 追記モード: ONのとき、ランダム生成・英語変換は、英語の枠の今の文章を消さずに後ろへ足す
  bool appendMode = true;
  String _mergeEn(String old, String add) {
    if (!appendMode || old.trim().isEmpty) return add;
    return '${old.trim()} $add';
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
    if (textLocked) { setState(() => error = '生成中は英語に変換できません。日本語のまま予約すると、順番が来たときに自動で変換します'); return; }
    setState(() { busyText = true; error = null; });
    try {
      final r = await HelperApi(st).translate(_jaFull(), seconds: seconds, lines: lines.text.trim());
      en.text = _mergeEn(en.text, r);
      en.text = reflectLines(en.text, lines.text);
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  // 入力の内容を「予約」に足す。空いていればすぐ生成が始まり、生成中なら順番を待つ
  Future<void> _enqueue() async {
    await s.ensureFresh();
    final st = s.status;
    if (st == null || !st.isRunning) { setState(() => error = '接続できていません。接続タブで再接続してください'); return; }
    if (mode == 'v2v' && refVideo == null) { setState(() => error = '参照する動画をえらんでください'); return; }
    if ((mode == 'i2v' || mode == 'ref2v') && images.isEmpty) { setState(() => error = '画像をえらんでください'); return; }
    if (ja.text.trim().isEmpty && en.text.trim().isEmpty) { setState(() => error = 'プロンプトを入れてください（ランダム生成も使えます）'); return; }
    final p = _preset();
    if (seconds > p.maxSec) seconds = p.maxSec;
    setState(() { error = null; busyText = true; });
    try {
      String vb64 = '';
      if (mode == 'v2v') {
        final vb = await refVideo!.readAsBytes();
        if (vb.length > 60 * 1024 * 1024) throw Exception('参照動画が大きすぎます（60MB以下にしてください）');
        vb64 = base64Encode(vb);
      }
      final b64 = <String>[];
      for (final f in images.take(maxImages)) { b64.add(base64Encode(await f.readAsBytes())); }
      // セリフは、英語がすでにあれば今すぐ反映して英語の枠にも見せる（無ければ、順番が来たときの英語変換に渡す）
      if (en.text.trim().isNotEmpty) en.text = reflectLines(en.text, lines.text);
      final rnd = Random();
      final base = int.tryParse(seedCtl.text) ?? 0;
      final list = <GenJob>[];
      for (var i = 0; i < count; i++) {
        final seed = seedFixed ? base + i : rnd.nextInt(1 << 31);
        list.add(GenJob(
          id: 'q${DateTime.now().microsecondsSinceEpoch}_$i', mode: mode, ja: ja.text.trim(), en: en.text.trim(), lines: lines.text.trim(),
          ratio: ratio, preset: preset, lora: lora, checkpoint: s.checkpoint, profile: s.profile,
          enc: (s.enc32 && s.profile.isEmpty) ? '32b' : '', seconds: seconds, seed: seed, estMin: p.estMin,
          loraStrength: loraStrength, fast: s.fast,
          refmods: [for (final e in refSel.entries) {'name': e.key, 'strength': e.value}],
          imagesB64: b64, videoB64: vb64,
        ));
      }
      final wasActive = s.queue.active;
      s.queue.add(list);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasActive ? '予約に${list.length}本を足しました（順番に作ります）' : '${list.length}本の生成を始めます'),
          duration: const Duration(seconds: 3)));
      }
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => busyText = false);
  }

  Widget _chips<T>(List<T> values, T cur, String Function(T) label, void Function(T) pick) => Wrap(
        spacing: 8, runSpacing: 4,
        children: values.map((v) => ChoiceChip(label: Text(label(v)), selected: v == cur, onSelected: (_) => pick(v))).toList(),
      );

  @override
  Widget build(BuildContext context) {
    final st = s.status;
    final p = _preset();
    final presets = (st?.presets.isNotEmpty ?? false) ? st!.presets : [PresetInfo('high', '高画質 960×1728', 10, 12, true)];
    final durs = [5, 8, 10].where((d) => d <= p.maxSec).toList();
    if (!durs.contains(seconds)) seconds = durs.last;

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
        onSelectionChanged: (v) => setState(() { mode = v.first; if (images.length > maxImages) images.removeRange(maxImages, images.length); }),
      ),
      if (mode == 'v2v') ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _pickVideo, icon: const Icon(Icons.video_library_outlined),
          label: Text(refVideo == null ? '参照する動画をえらぶ' : '選択中: ${refVideo!.name}')),
        const SizedBox(height: 4),
        SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('人物の外見は書かない（動き・構図だけ読み取る）', style: TextStyle(fontSize: 13)),
          subtitle: const Text('オンにすると、元の人物と別の人物にしやすくなります。髪型・服装は下の枠から「追加」で足せます', style: TextStyle(fontSize: 11)),
          value: vpNoLook, onChanged: (v) => setState(() => vpNoLook = v)),
        OutlinedButton.icon(onPressed: busyText || textLocked || refVideo == null ? null : _videoPrompt, icon: const Icon(Icons.auto_awesome_outlined),
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
              Positioned(right: 8, top: 0, child: InkWell(onTap: () => setState(() => images.removeAt(i)), child: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)))),
            ]),
          if (images.length < maxImages)
            InkWell(onTap: _pick, child: Container(width: 96, height: 96, decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.add_photo_alternate_outlined))),
        ])),
        Text(mode == 'i2v' ? '最初のフレームになる画像を1枚' : '参照する画像を最大3枚（人物や物など）', style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
      const SizedBox(height: 12),
      TextField(controller: ja, minLines: 2, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: 'プロンプト（日本語）', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: hair, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '髪型（日本語）', hintText: '例: 黒髪のロングで、前髪は斜め分け', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: outfit, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '服装（日本語）', hintText: '例: 白いニットに、紺のロングスカート', border: OutlineInputBorder())),
      Row(children: [Expanded(child: Text('イメージを日本語で入れて「追加」を押すと、H3向けの英語に変換して、いまの英語プロンプトへ追記します（元の文章は変えません）', style: TextStyle(fontSize: 12, color: Colors.grey))), const SizedBox(width: 8), FilledButton.tonal(onPressed: busyText || textLocked ? null : _addDetail, child: const Text('追加'))]),
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('追記モード（ランダム生成・英語変換で今の英語を消さない）', style: TextStyle(fontSize: 13)), value: appendMode, onChanged: (v) => setState(() => appendMode = v)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: busyText || textLocked ? null : _random, icon: const Icon(Icons.casino_outlined), label: const Text('ランダム生成'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(onPressed: busyText || textLocked ? null : _translate, icon: const Icon(Icons.translate), label: const Text('英語に変換'))),
      ]),
      if (textLocked) const Padding(padding: EdgeInsets.only(top: 4), child: Text('生成中は、英語変換・ランダム生成・追加・動画からのプロンプト作りは使えません。日本語のまま予約すると、順番が来たときに自動で英語に変換します。', style: TextStyle(fontSize: 11, color: Colors.grey))),
      if (busyText) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      const SizedBox(height: 8),
      TextField(controller: en, minLines: 2, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: '英語プロンプト（直せます）', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: lines, minLines: 1, maxLines: null, keyboardType: TextInputType.multiline, decoration: const InputDecoration(labelText: 'セリフ（日本語・そのまま話します）', hintText: '例: こんにちは、今日もいい天気だね', helperText: '英語に変換するとき、または予約するときに、発音の指定つきで英語プロンプトへ入ります', helperMaxLines: 2, border: OutlineInputBorder())),
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
        ChoiceChip(label: const Text('ランダム'), selected: !seedFixed, onSelected: (_) => setState(() => seedFixed = false)),
        const SizedBox(width: 8),
        ChoiceChip(label: const Text('固定'), selected: seedFixed, onSelected: (_) => setState(() => seedFixed = true)),
        const SizedBox(width: 8),
        if (seedFixed) Expanded(child: TextField(controller: seedCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, hintText: '数字'))),
      ]),
      Row(children: [
        const Text('本数（シードを変えて作る）'),
        IconButton(onPressed: count <= 1 ? null : () => setState(() => count--), icon: const Icon(Icons.remove_circle_outline)),
        Text('$count'),
        IconButton(onPressed: count >= 4 ? null : () => setState(() => count++), icon: const Icon(Icons.add_circle_outline)),
        Text(count > 1 ? '（約${p.estMin * count}分）' : '', style: const TextStyle(color: Colors.grey)),
      ]),
      if (count > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(seedFixed ? '固定したシードに1ずつ足して作ります。' : 'シードを毎回変えて作ります。できた動画は履歴に並ぶので、良い方を選び、残りは削除できます。セリフが欠けたり不自然になる場合に有効です。', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
      const SizedBox(height: 8),
      Text('RefMod（キャラ固定）', style: Theme.of(context).textTheme.titleSmall),
      if (refOpts.isEmpty) const Text('まだありません。下のボタンで参照画像から作れます', style: TextStyle(fontSize: 12, color: Colors.grey)),
      if (refOpts.isNotEmpty) Wrap(spacing: 8, children: [
        for (final r in refOpts)
          FilterChip(
            label: Text(r), selected: refSel.containsKey(r),
            onSelected: (v) => setState(() { if (v) { refSel[r] = 1.0; } else { refSel.remove(r); } }),
          ),
      ]),
      for (final e in refSel.entries)
        Row(children: [
          Expanded(flex: 2, child: Text('${e.key} の強さ', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          Expanded(flex: 3, child: Slider(value: e.value, min: 0.1, max: 1.0, divisions: 9, label: e.value.toStringAsFixed(1), onChanged: (v) => setState(() => refSel[e.key] = v))),
        ]),
      OutlinedButton.icon(
        onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => RefmodPage(state: s))); _loadLoras(); },
        icon: const Icon(Icons.face_retouching_natural),
        label: const Text('RefModを作る・管理'),
      ),
      DropdownButtonFormField<String>(
        value: const ['', 'pika', 'prism', 'prism_pika', 'prism_lora', 'prism_dmad'].contains(s.profile) ? s.profile : '',
        decoration: const InputDecoration(labelText: 'モデル（先に「モデル管理」でパックを入れる）'),
        items: const [
          DropdownMenuItem(value: '', child: Text('標準①（髪・質感・音が強い）')),
          DropdownMenuItem(value: 'pika', child: Text('Pika H3 Flex（顔が映える・やや速い）')),
          DropdownMenuItem(value: 'prism', child: Text('試験：PRISM INT8（8ステップ）')),
          DropdownMenuItem(value: 'prism_pika', child: Text('試験：PRISM＋Pika 合体済み')),
          DropdownMenuItem(value: 'prism_lora', child: Text('試験：PRISM＋PikaのLoRAを重ねる')),
          DropdownMenuItem(value: 'prism_dmad', child: Text('試験：PRISM DMAD-PDMD')),
        ],
        onChanged: (v) => setState(() => s.setProfile(v ?? '')),
      ),
      if (s.profile.isNotEmpty)
        SwitchListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          title: const Text('高速化（Veda）'),
          subtitle: const Text('速くなりますが、画質が少し下がる場合があります。', style: TextStyle(fontSize: 11)),
          value: s.fast, onChanged: (v) => setState(() => s.setFast(v)),
        ),
      SwitchListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        title: const Text('32B文字読み取り（標準①向け）'),
        subtitle: const Text('標準①で画質が上がりました。Pikaでは差がほぼなく遅くなるため、Pika選択時は自動でオフになります。先に「モデル管理」でパックを入れます。', style: TextStyle(fontSize: 11)),
        value: s.enc32, onChanged: (v) => setState(() => s.setEnc32(v)),
      ),
      OutlinedButton.icon(
        onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => ModelsPage(state: s))); _loadLoras(); },
        icon: const Icon(Icons.tune),
        label: Text('モデル管理（チェックポイント・LoRA）${s.checkpoint.isEmpty ? '' : '\n使用中: ${s.checkpoint}'}', textAlign: TextAlign.center),
      ),
      if (loraOpts.isNotEmpty) ...[
        DropdownButtonFormField<String>(
          value: loraOpts.contains(lora) ? lora : '',
          decoration: const InputDecoration(labelText: 'LoRA'),
          items: [const DropdownMenuItem(value: '', child: Text('なし')), ...loraOpts.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis)))],
          onChanged: (v) => setState(() => lora = v ?? ''),
        ),
        if (lora.isNotEmpty) Slider(value: loraStrength, min: 0.1, max: 1.5, divisions: 14, label: loraStrength.toStringAsFixed(1), onChanged: (v) => setState(() => loraStrength = v)),
      ],
      const SizedBox(height: 12),
      if (error != null) ErrorBox(error!, color: Colors.redAccent),
      FilledButton.icon(
        onPressed: busyText ? null : _enqueue,
        icon: Icon(s.queue.active ? Icons.playlist_add : Icons.play_arrow),
        label: Text(s.queue.active ? (count > 1 ? '予約に$count本を足す' : '予約に足す') : (count > 1 ? '$count本つくる' : '生成する'))),
      const SizedBox(height: 4),
      const Text('生成中でも、内容を変えてもう一度押すと、順番待ちに足せます（1本ずつ順に作ります）。アプリを閉じると予約は消えるので、生成が終わるまで開いたままにしてください。', style: TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 8),
      QueuePanel(q: s.queue),
    ]);
  }
}
