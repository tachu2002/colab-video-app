import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'store.dart';

class ConnectPage extends StatefulWidget {
  final AppState state;
  const ConnectPage({super.key, required this.state});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  Timer? _timer;
  bool? _healthy;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_rebuild);
    // 表示中は30秒ごとにDriveを読み直す（サインイン済みのときだけ）
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.state.account != null && !widget.state.busy) widget.state.refreshFromDrive();
    });
  }

  void _rebuild() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    _timer?.cancel();
    widget.state.removeListener(_rebuild);
    super.dispose();
  }

  Future<void> _test() async {
    final st = widget.state.status;
    if (st == null) return;
    setState(() { _testing = true; _healthy = null; });
    final ok = await HelperApi(st).health();
    if (mounted) setState(() { _testing = false; _healthy = ok; });
  }

  Future<void> _manual() async {
    final c = TextEditingController(), h = TextEditingController(), t = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接続情報を直接入力'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: c, decoration: const InputDecoration(labelText: 'ComfyUIのURL')),
            TextField(controller: h, decoration: const InputDecoration(labelText: 'ヘルパーのURL')),
            TextField(controller: t, decoration: const InputDecoration(labelText: 'トークン')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true && c.text.isNotEmpty && h.text.isNotEmpty && t.text.isNotEmpty) {
      widget.state.setManual(comfyUrl: c.text, helperUrl: h.text, token: t.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final st = s.status;
    final cs = Theme.of(context).colorScheme;
    String badge; Color color;
    if (st == null) { badge = '未接続'; color = Colors.grey; }
    else if (st.isRunning) { badge = '接続できます'; color = Colors.greenAccent; }
    else { badge = '停止中（Colab側が止まっています）'; color = Colors.orangeAccent; }

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('接続', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.circle, size: 14, color: color), const SizedBox(width: 8), Expanded(child: Text(badge, style: const TextStyle(fontWeight: FontWeight.bold)))]),
        if (st != null) ...[
          const SizedBox(height: 12),
          _row('現在のGPU', st.gpuName.isEmpty ? '-' : st.gpuName),
          _row('最終更新', st.updatedAt == null ? '-' : _ago(st.updatedAt!)),
          _row('消費ペース', st.unitsPerHour == null ? '未設定' : '${st.unitsPerHour} ユニット/時'),
        ],
      ]))),
      if (st != null) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Colabの使用状況', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(st.unitsRemaining == null ? '残りユニット: 取得できません' : '残りユニット: ${st.unitsRemaining!.toStringAsFixed(1)}',
            style: TextStyle(fontSize: 28, color: cs.primary, fontWeight: FontWeight.bold)),
        if (st.unitsRemaining == null)
          const Padding(padding: EdgeInsets.only(top: 6), child: Text(
              'ノートブックの設定セルに START_UNITS と UNITS_PER_HOUR を入れると、概算の残量が出ます。', style: TextStyle(fontSize: 12, color: Colors.grey))),
        if (st.unitsRemaining != null) Text(st.usageSource == 'estimate' ? '（起動時の値からの概算）' : '', style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ]))),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: s.busy ? null : s.refreshFromDrive,
        icon: s.busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
        label: Text(st != null && !st.isRunning ? '再接続（Driveを読み直す）' : 'Driveから接続情報を読む'),
      ),
      if (s.driveError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.driveError!, style: const TextStyle(color: Colors.redAccent))),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: st == null || _testing ? null : _test, icon: const Icon(Icons.wifi_tethering), label: const Text('接続テスト')),
      if (_healthy != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_healthy! ? '応答しました' : '応答がありません。Colabが動いているか確認してください', style: TextStyle(color: _healthy! ? Colors.greenAccent : Colors.orangeAccent))),
      const SizedBox(height: 8),
      TextButton(onPressed: _manual, child: const Text('URLとトークンを直接入力する')),
      if (s.account != null) TextButton(onPressed: s.signOut, child: Text('Googleアカウントを外す（${s.account!.email}）')),
      const SizedBox(height: 16),
      const Text('使い方: PCやスマホでColabのノートブックを「すべてのセルを実行」→ 最後のセルが動いている間だけ、このアプリから生成できます。止めるとここが「停止中」になります。',
          style: TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }

  Widget _row(String k, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: const TextStyle(color: Colors.grey)), Text(v)]));

  String _ago(DateTime t) {
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inSeconds < 60) return '${d.inSeconds}秒前';
    if (d.inMinutes < 60) return '${d.inMinutes}分前';
    return '${d.inHours}時間前';
  }
}
