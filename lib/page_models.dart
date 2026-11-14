import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'store.dart';

/// チェックポイントの切り替えと、LoRAの追加（URLからColabへダウンロード）
class ModelsPage extends StatefulWidget {
  final AppState state;
  const ModelsPage({super.key, required this.state});
  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  List<String> checkpoints = [], loras = [];
  String defaultCkpt = '';
  String? error;
  bool loading = true;
  final url = TextEditingController(), fname = TextEditingController(), token = TextEditingController();
  String kind = 'lora';
  Map<String, dynamic>? job;
  Timer? _t;

  HelperApi? get _api => widget.state.status == null ? null : HelperApi(widget.state.status!);

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  Future<void> _load() async {
    final api = _api;
    if (api == null) { setState(() { loading = false; error = '先に接続してください'; }); return; }
    try {
      final m = await api.models();
      if (!mounted) return;
      setState(() {
        checkpoints = (m['checkpoints'] as List).map((e) => e.toString()).toList();
        loras = (m['loras'] as List).map((e) => e.toString()).toList();
        defaultCkpt = (m['default'] ?? '').toString();
        loading = false; error = null;
      });
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString(); });
    }
  }

  Future<void> _start() async {
    final api = _api;
    if (api == null || url.text.trim().isEmpty) return;
    try {
      final j = await api.download(url.text.trim(), kind, fname.text.trim(), token.text.trim());
      setState(() { job = j; error = null; });
      _t?.cancel();
      _t = Timer.periodic(const Duration(seconds: 3), (_) async {
        try {
          final s = await api.downloadStatus(j['id']);
          if (!mounted) return;
          setState(() => job = s);
          if (s['state'] != 'running') { _t?.cancel(); if (s['state'] == 'done') { url.clear(); fname.clear(); _load(); } }
        } catch (_) {}
      });
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  String _mb(num b) => '${(b / 1048576).toStringAsFixed(b > 1073741824 ? 0 : 1)}MB';

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final cur = s.checkpoint;
    final running = job != null && job!['state'] == 'running';
    return Scaffold(
      appBar: AppBar(title: const Text('モデル管理'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (loading) const LinearProgressIndicator(),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: const TextStyle(color: Colors.orangeAccent))),
        Text('チェックポイント（本体モデル）', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('標準以外は、H3専用の高速化の設定と合わない場合があります。うまく動かない時は「標準」に戻してください。', style: TextStyle(fontSize: 12, color: Colors.grey)),
        RadioListTile<String>(
          value: '', groupValue: cur, title: const Text('標準（このアプリ推奨のH3）'),
          subtitle: defaultCkpt.isEmpty ? null : Text(defaultCkpt, style: const TextStyle(fontSize: 11)),
          onChanged: (v) => setState(() => s.setCheckpoint('')),
        ),
        for (final c in checkpoints.where((c) => c != defaultCkpt))
          RadioListTile<String>(
            value: c, groupValue: cur, title: Text(c, style: const TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => s.setCheckpoint(c)),
          ),
        const Divider(height: 32),
        Text('LoRA', style: Theme.of(context).textTheme.titleMedium),
        if (loras.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('まだありません。下から追加できます。', style: TextStyle(color: Colors.grey))),
        for (final l in loras)
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero, title: Text(l, style: const TextStyle(fontSize: 13)),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                title: const Text('このLoRAを消しますか？'), content: Text(l),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('やめる')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('消す'))],
              ));
              if (ok == true) { try { await _api?.deleteLora(l); } catch (e) { setState(() => error = e.toString()); } _load(); }
            }),
          ),
        const Divider(height: 32),
        Text('追加する（URLからColabへダウンロード）', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'lora', label: Text('LoRA')), ButtonSegment(value: 'checkpoint', label: Text('チェックポイント'))],
          selected: {kind}, onSelectionChanged: running ? null : (v) => setState(() => kind = v.first),
        ),
        const SizedBox(height: 8),
        TextField(controller: url, decoration: const InputDecoration(labelText: 'ファイルのURL（HuggingFace / CivitAI）', border: OutlineInputBorder()), minLines: 1, maxLines: 3),
        const SizedBox(height: 8),
        TextField(controller: fname, decoration: const InputDecoration(labelText: '保存名（空ならURLから自動）', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: token, obscureText: true, decoration: const InputDecoration(labelText: 'トークン（必要な時だけ）', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: running ? null : _start, icon: const Icon(Icons.cloud_download), label: const Text('ダウンロードして追加')),
        if (job != null) Padding(padding: const EdgeInsets.only(top: 12), child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job!['name'].toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (job!['state'] == 'running') ...[
            LinearProgressIndicator(value: (job!['total'] ?? 0) > 0 ? (job!['bytes'] as num) / (job!['total'] as num) : null),
            const SizedBox(height: 4),
            Text('${_mb(job!['bytes'])}${(job!['total'] ?? 0) > 0 ? ' / ${_mb(job!['total'])}' : ''}', style: const TextStyle(fontSize: 12)),
          ],
          if (job!['state'] == 'done') const Text('追加できました', style: TextStyle(color: Colors.greenAccent)),
          if (job!['state'] == 'error') Text(job!['error'].toString(), style: const TextStyle(color: Colors.orangeAccent)),
        ])))),
        const SizedBox(height: 8),
        const Text('Colabを止めると、追加したファイルは消えます（次回は同じURLからまた追加してください）。', style: TextStyle(fontSize: 12, color: Colors.grey)),
      ]),
    );
  }
}
