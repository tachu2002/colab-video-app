import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'store.dart';

/// 参照画像から RefMod（キャラ固定用の小さなファイル）を作る・消す
class RefmodPage extends StatefulWidget {
  final AppState state;
  const RefmodPage({super.key, required this.state});
  @override
  State<RefmodPage> createState() => _RefmodPageState();
}

class _RefmodPageState extends State<RefmodPage> {
  List<String> mods = [];
  final List<XFile> images = [];
  final nameCtl = TextEditingController();
  bool high = false, busy = false;
  String? error, info;
  Timer? _t;

  HelperApi? get _api => widget.state.status == null ? null : HelperApi(widget.state.status!);

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _t?.cancel(); nameCtl.dispose(); super.dispose(); }

  Future<void> _load() async {
    final api = _api;
    if (api == null) { setState(() => error = '先に接続してください'); return; }
    try {
      final r = await api.refmods();
      if (mounted) setState(() { mods = r; error = null; });
    } catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  Future<void> _pick() async {
    final f = await ImagePicker().pickMultiImage(maxWidth: 1536);
    if (f.isEmpty) return;
    setState(() { images.addAll(f); if (images.length > 8) images.removeRange(8, images.length); });
  }

  Future<void> _create() async {
    final api = _api;
    if (api == null) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty || images.isEmpty) { setState(() => error = '名前（英数字）と画像をいれてください'); return; }
    setState(() { busy = true; error = null; info = '作っています…（1〜3分かかります）'; });
    try {
      final b64 = <String>[];
      for (final f in images) { b64.add(base64Encode(await f.readAsBytes())); }
      final id = await api.createRefmod(name, b64, high ? 'high' : 'standard');
      _t = Timer.periodic(const Duration(seconds: 3), (t) async {
        try {
          final j = await api.refmodJob(id);
          if (j['state'] == 'done') {
            t.cancel();
            if (mounted) setState(() { busy = false; info = '「${j['name']}」ができました。生成画面で選べます'; images.clear(); nameCtl.clear(); });
            _load();
          } else if (j['state'] == 'error') {
            t.cancel();
            if (mounted) setState(() { busy = false; info = null; error = '作れませんでした: ${j['error']}'; });
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() { busy = false; info = null; error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RefMod（キャラ固定）')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('同じ人物の写真を1〜8枚えらぶと、小さな参照ファイルになります。生成画面でLoRAのように選んで使えます。作ったものはGoogleドライブにも保存されます。', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 12),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        if (info != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(info!, style: const TextStyle(color: Colors.greenAccent))),
        TextField(controller: nameCtl, enabled: !busy, decoration: const InputDecoration(labelText: '名前（英数字。例: hiyori）', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        SizedBox(height: 96, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (var i = 0; i < images.length; i++)
            Stack(children: [
              Padding(padding: const EdgeInsets.only(right: 8), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: FutureBuilder(
                future: images[i].readAsBytes(),
                builder: (c, snap) => snap.hasData ? Image.memory(snap.data!, width: 96, height: 96, fit: BoxFit.cover) : const SizedBox(width: 96, height: 96),
              ))),
              Positioned(right: 8, top: 0, child: InkWell(onTap: busy ? null : () => setState(() => images.removeAt(i)), child: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)))),
            ]),
          if (images.length < 8)
            InkWell(onTap: busy ? null : _pick, child: Container(width: 96, height: 96, decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.add_photo_alternate_outlined))),
        ])),
        SwitchListTile(
          contentPadding: EdgeInsets.zero, value: high, onChanged: busy ? null : (v) => setState(() => high = v),
          title: const Text('細かく取り込む'), subtitle: const Text('顔の再現は良くなりますが、生成が少し遅くなります'),
        ),
        FilledButton.icon(onPressed: busy ? null : _create, icon: const Icon(Icons.auto_fix_high), label: Text(busy ? '作成中…' : 'RefModを作る')),
        const SizedBox(height: 16),
        Text('作成済み', style: Theme.of(context).textTheme.titleSmall),
        if (mods.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('まだありません', style: TextStyle(color: Colors.grey))),
        for (final m in mods)
          ListTile(
            contentPadding: EdgeInsets.zero, title: Text(m),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: busy ? null : () async {
              final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
                title: Text('「$m」を消しますか？'), content: const Text('Googleドライブからも消えます。'),
                actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('消す'))]));
              if (ok == true) { try { await _api?.deleteRefmod(m); } catch (_) {} _load(); }
            }),
          ),
      ]),
    );
  }
}
