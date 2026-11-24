import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api.dart';
import 'store.dart';

// ---- セリフ欄の日本語を、H3の台詞の形式（発音の指定つき）で英語プロンプトへ反映する ----

String _speechNorm(String s) => s.replaceAll(RegExp(r'[\s。、．，！？!?,.「」『』“”"]'), '');

/// セリフ欄を1文ずつに分ける（句点・改行で区切る）
List<String> splitLines(String t) {
  final out = <String>[];
  final re = RegExp(r'[^。！？!?]+[。！？!?]?');
  for (final part in t.split(RegExp(r'[\n\r]+'))) {
    final p = part.trim();
    if (p.isEmpty) continue;
    for (final m in re.allMatches(p)) {
      final x = (m.group(0) ?? '').trim();
      if (x.isNotEmpty) out.add(x);
    }
  }
  return out;
}

String _speechAppendix(List<String> ls) {
  final b = StringBuffer();
  for (var i = 0; i < ls.length; i++) {
    if (i > 0) b.write(' ');
    b.write(i == 0
        ? 'The speaker (S1), a native Japanese speaker with a soft, relaxed, natural voice, dry close-mic sound with no echo, speaking in natural standard Japanese intonation at a calm pace, says: '
        : 'The speaker then says: ');
    b.write('<d>[Japanese] ${ls[i]}</d> Realistic lip articulation, no exaggerated mouth opening, no head turns while speaking.');
  }
  return b.toString();
}

/// 英語プロンプトにまだ入っていないセリフだけを、台詞タグつきで末尾へ足す（すでに入っていれば何もしない）
String reflectLines(String en, String lines) {
  final ls = splitLines(lines);
  if (ls.isEmpty) return en;
  final hay = _speechNorm(en);
  final missing = ls.where((l) => !hay.contains(_speechNorm(l))).toList();
  if (missing.isEmpty) return en;
  final base = en.trim();
  return base.isEmpty ? _speechAppendix(missing) : '$base ${_speechAppendix(missing)}';
}

// ---- 生成の予約（キュー） ----

class GenJob {
  final String id, mode, ja, lines, ratio, preset, lora, checkpoint, profile, enc;
  final int seconds, seed, estMin;
  final double loraStrength;
  final bool fast;
  final List<Map<String, dynamic>> refmods;
  final List<String> imagesB64;
  final String videoB64;
  String en;
  String state = 'wait'; // wait=待機 / run=生成中 / done=完了 / fail=失敗 / cancel=取り消し
  String? error;
  double pct = 0;
  String stage = '';
  DateTime? startedAt, endedAt;
  bool cancelRequested = false;

  GenJob({
    required this.id, required this.mode, required this.ja, required this.en, required this.lines,
    required this.ratio, required this.preset, required this.lora, required this.checkpoint,
    required this.profile, required this.enc, required this.seconds, required this.seed,
    required this.estMin, required this.loraStrength, required this.fast, required this.refmods,
    required this.imagesB64, required this.videoB64,
  });

  String get title {
    final t = (ja.trim().isNotEmpty ? ja.trim() : en.trim()).replaceAll(RegExp(r'\s+'), ' ');
    return t.isEmpty ? '（内容なし）' : t;
  }
}

class JobQueue extends ChangeNotifier {
  final AppState app;
  JobQueue(this.app);

  final List<GenJob> jobs = [];
  GenJob? current;
  bool _pumping = false;
  Timer? _tick;

  Uint8List? preview;
  int previewCount = 0;
  DateTime? previewAt;
  String previewStage = '';

  int get waiting => jobs.where((j) => j.state == 'wait').length;
  bool get active => current != null || waiting > 0;
  bool get hasFinished => jobs.any((j) => j.state == 'done' || j.state == 'fail' || j.state == 'cancel');

  /// 残りの目安（分）。生成中の1本は経過分を引く
  int get remainingMin {
    var t = 0;
    for (final j in jobs) {
      if (j.state == 'wait') {
        t += j.estMin;
      } else if (j.state == 'run') {
        final el = j.startedAt == null ? 0 : DateTime.now().difference(j.startedAt!).inMinutes;
        t += max(1, j.estMin - el);
      }
    }
    return t;
  }

  void add(List<GenJob> list) {
    jobs.addAll(list);
    notifyListeners();
    _pump();
  }

  void remove(GenJob j) {
    if (j.state == 'run') return;
    jobs.remove(j);
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.state == 'done' || j.state == 'fail' || j.state == 'cancel');
    notifyListeners();
  }

  Future<void> cancelCurrent() async {
    final j = current;
    if (j == null) return;
    j.cancelRequested = true;
    j.stage = '中止しています';
    notifyListeners();
    final st = app.status;
    if (st != null) await ComfyApi(st.comfyUrl).interrupt();
  }

  Future<void> cancelAll() async {
    for (final j in jobs) {
      if (j.state == 'wait') j.state = 'cancel';
    }
    notifyListeners();
    await cancelCurrent();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        GenJob? j;
        for (final x in jobs) {
          if (x.state == 'wait') { j = x; break; }
        }
        if (j == null) break;
        current = j;
        j.state = 'run';
        j.startedAt = DateTime.now();
        j.stage = '準備中';
        j.pct = 0;
        preview = null;
        previewCount = 0;
        _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
        notifyListeners();
        try {
          await _runOne(j);
          if (j.cancelRequested) {
            j.state = 'cancel';
          } else {
            j.state = 'done';
            j.pct = 100;
          }
        } catch (e) {
          if (j.cancelRequested) {
            j.state = 'cancel';
          } else {
            j.state = 'fail';
            j.error = e.toString();
          }
        }
        j.endedAt = DateTime.now();
        current = null;
        notifyListeners();
      }
    } finally {
      _pumping = false;
      current = null;
      _tick?.cancel();
      _tick = null;
      notifyListeners();
    }
  }

  static String stageOf(double p) {
    if (p < 5) return '準備中';
    if (p < 35) return '1段目（下書きを作っています）';
    if (p < 90) return '2段目（高画質にしています）';
    return '書き出し中';
  }

  Future<void> _runOne(GenJob j) async {
    await app.ensureFresh();
    final st = app.status;
    if (st == null || !st.isRunning) throw ApiException('接続できていません。接続タブで再接続してください');
    final api = HelperApi(st);
    final comfy = ComfyApi(st.comfyUrl);

    if (j.en.trim().isEmpty) {
      j.stage = '英語プロンプトを作っています';
      notifyListeners();
      j.en = await api.translate(j.ja, seconds: j.seconds, lines: j.lines);
    }
    j.en = reflectLines(j.en, j.lines);
    if (j.cancelRequested) return;

    final rnd = Random();
    final cid = 'app${DateTime.now().millisecondsSinceEpoch}${rnd.nextInt(9999)}';
    j.stage = '準備中';
    notifyListeners();
    WebSocketChannel? ch;
    StreamSubscription? sub;
    try {
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
              preview = Uint8List.fromList(b.sublist(at));
              previewCount++;
              previewAt = DateTime.now();
              previewStage = j.stage;
              notifyListeners();
            } catch (_) {}
            return;
          }
          try {
            final x = jsonDecode(m);
            if (x['type'] == 'progress') {
              final d = x['data'];
              final v = (d['value'] as num).toDouble(), mx = (d['max'] as num).toDouble();
              final node = d['node']?.toString();
              double np = j.pct;
              if (node == '132') {
                np = 5 + 30 * v / mx;
              } else if (node == '198') {
                np = 35 + 55 * v / mx;
              }
              if (np > j.pct) {
                j.pct = np;
                j.stage = stageOf(np);
                notifyListeners();
              }
            }
          } catch (_) {}
        }, onError: (_) {}, cancelOnError: false);
      } catch (_) {}

      final pid = await api.generate(
        mode: j.mode, promptEn: j.en.trim(), seconds: j.seconds.toDouble(), aspect: j.ratio,
        preset: j.preset, seed: j.seed, imagesB64: j.imagesB64, lora: j.lora, loraStrength: j.loraStrength,
        clientId: cid, checkpoint: j.checkpoint, profile: j.profile, fast: j.fast, enc: j.enc,
        refmods: j.refmods, videoB64: j.videoB64,
      );

      VideoRef? ref;
      var failSince = DateTime.now();
      while (ref == null && !j.cancelRequested) {
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
      if (j.cancelRequested || ref == null) return;

      j.pct = 95;
      j.stage = '端末に保存中';
      notifyListeners();
      final id = '${DateTime.now().millisecondsSinceEpoch}';
      String? path;
      for (var t = 0; t < 4 && path == null; t++) {
        try {
          path = await app.saveVideo(id, comfy.viewUri(ref));
        } catch (e) {
          if (t == 3) rethrow;
          await Future.delayed(const Duration(seconds: 3));
        }
      }
      app.addHistory(HistoryItem(
        id: id, ja: j.ja.trim(), en: j.en.trim(), mode: j.mode, ratio: j.ratio, preset: j.preset,
        lora: j.lora, path: path!, seconds: j.seconds, seed: j.seed, createdAt: DateTime.now(),
      ));
    } finally {
      await sub?.cancel();
      await ch?.sink.close();
    }
  }
}

// ---- 予約の一覧（生成タブに表示） ----

class QueuePanel extends StatelessWidget {
  final JobQueue q;
  const QueuePanel({super.key, required this.q});

  static const _modeName = {'t2v': '文字', 'i2v': '画像', 'ref2v': '参照画像', 'v2v': '参照動画', 'swap': '入れ替え'};

  @override
  Widget build(BuildContext context) {
    if (q.jobs.isEmpty) return const SizedBox.shrink();
    final rem = q.remainingMin;
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(
          q.active ? '予約 ${q.jobs.where((j) => j.state == 'wait' || j.state == 'run').length}件　残り約$rem分（目安）' : '予約（すべて終わりました）',
          style: const TextStyle(fontWeight: FontWeight.bold))),
        if (q.hasFinished) TextButton(onPressed: q.clearFinished, child: const Text('終わった分を消す')),
      ]),
      if (q.active)
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent, padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
          onPressed: () => q.cancelAll(), icon: const Icon(Icons.stop_circle_outlined, size: 18), label: const Text('全部取り消す'))),
      for (final j in q.jobs) _row(context, j),
    ])));
  }

  Widget _row(BuildContext context, GenJob j) {
    final info = '${_modeName[j.mode] ?? j.mode}・${j.seconds}秒・${j.ratio}・シード${j.seed}';
    if (j.state == 'run') {
      final elapsed = j.startedAt == null ? 0 : DateTime.now().difference(j.startedAt!).inSeconds;
      return Padding(padding: const EdgeInsets.only(top: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('生成中　${j.pct.floor()}%　${j.stage}', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(j.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        Text(info, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: j.pct <= 0 ? null : j.pct / 100, minHeight: 10),
        const SizedBox(height: 4),
        Text('経過 ${elapsed ~/ 60}分${elapsed % 60}秒', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (q.preview != null) ...[
          const SizedBox(height: 6),
          Text('途中経過（1コマ目・ぼやけています）　${q.previewCount}回目／${q.previewAt == null ? 0 : DateTime.now().difference(q.previewAt!).inSeconds}秒前に更新／${q.previewStage}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Center(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 300), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(q.preview!, gaplessPlayback: true, fit: BoxFit.contain)))),
        ] else if (j.pct >= 5)
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('途中経過の画像を待っています…（出ない場合はColabの再起動が必要です）', style: TextStyle(fontSize: 12, color: Colors.grey))),
        const SizedBox(height: 6),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: j.cancelRequested ? null : () => q.cancelCurrent(),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(j.cancelRequested ? '中止しています…' : 'この1本を中止する')),
      ]));
    }
    IconData icon;
    Color color;
    String label;
    switch (j.state) {
      case 'wait': icon = Icons.schedule; color = Colors.grey; label = '待機'; break;
      case 'done': icon = Icons.check_circle_outline; color = Colors.greenAccent; label = '完了（履歴タブで見られます）'; break;
      case 'fail': icon = Icons.error_outline; color = Colors.redAccent; label = '失敗'; break;
      default: icon = Icons.block; color = Colors.grey; label = '取り消し';
    }
    return Padding(padding: const EdgeInsets.only(top: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label　${j.title}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        Text(info, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        if (j.state == 'fail' && j.error != null) SelectableText(j.error!, style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
      ])),
      if (j.state == 'wait') IconButton(visualDensity: VisualDensity.compact, onPressed: () => q.remove(j), icon: const Icon(Icons.close, size: 18)),
    ]));
  }
}
