import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'store.dart';

class HistoryPage extends StatefulWidget {
  final AppState state;
  const HistoryPage({super.key, required this.state});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() { super.initState(); widget.state.addListener(_r); }
  void _r() { if (mounted) setState(() {}); }
  @override
  void dispose() { widget.state.removeListener(_r); super.dispose(); }

  static const modeName = {'t2v': '文字→動画', 'i2v': '画像→動画', 'ref2v': '参照画像→動画', 'v2v': '参照動画→動画'};

  @override
  Widget build(BuildContext context) {
    final h = widget.state.history;
    if (h.isEmpty) return const Center(child: Text('まだ動画がありません', style: TextStyle(color: Colors.grey)));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: h.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final it = h[i];
        return Card(child: ListTile(
          leading: const Icon(Icons.play_circle_outline, size: 36),
          title: Text(it.ja.isEmpty ? it.en : it.ja, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('${modeName[it.mode]} ・ ${it.seconds}秒 ・ ${it.ratio} ・ ${it.createdAt.month}/${it.createdAt.day} ${it.createdAt.hour}:${it.createdAt.minute.toString().padLeft(2, '0')}'),
          onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => DetailPage(state: widget.state, item: it))),
        ));
      },
    );
  }
}

class DetailPage extends StatefulWidget {
  final AppState state;
  final HistoryItem item;
  const DetailPage({super.key, required this.state, required this.item});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late VideoPlayerController c;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    c = VideoPlayerController.file(File(widget.item.path))
      ..initialize().then((_) { if (mounted) setState(() { ready = true; c.setLooping(true); c.play(); }); });
  }

  @override
  void dispose() { c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return Scaffold(
      appBar: AppBar(title: const Text('動画'), actions: [
        IconButton(icon: const Icon(Icons.download), tooltip: 'ダウンロードに保存', onPressed: () async {
          final m = ScaffoldMessenger.of(context);
          try {
            await widget.state.saveToDownloads(it);
            m.showSnackBar(const SnackBar(content: Text('「ダウンロード」の中の「ColabVideo」フォルダに保存しました')));
          } catch (e) {
            m.showSnackBar(SnackBar(content: Text('保存できませんでした: $e')));
          }
        }),
        IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async {
          final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('この動画を消しますか？'), content: const Text('端末からも消えます。元に戻せません。'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('やめる')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('消す'))],
          ));
          if (ok == true) { await widget.state.deleteHistory(it); if (mounted) Navigator.pop(context); }
        }),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (ready) AspectRatio(aspectRatio: c.value.aspectRatio, child: GestureDetector(onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()), child: VideoPlayer(c)))
        else const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
        const SizedBox(height: 12),
        Text(it.ja),
        const SizedBox(height: 8),
        Text(it.en, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        Text('シード ${it.seed} ・ 画質 ${it.preset}${it.lora.isEmpty ? '' : ' ・ LoRA ${it.lora}'}', style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(onPressed: () async {
          final m = ScaffoldMessenger.of(context);
          try { await widget.state.saveToDownloads(it); m.showSnackBar(const SnackBar(content: Text('「ダウンロード」の中の「ColabVideo」フォルダに保存しました'))); } catch (e) { m.showSnackBar(SnackBar(content: Text('保存できませんでした: $e'))); }
        }, icon: const Icon(Icons.download), label: const Text('ダウンロードに保存')),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: () { widget.state.regenerate(it); Navigator.pop(context); }, icon: const Icon(Icons.replay), label: const Text('同じ設定でつくり直す')),
      ]),
    );
  }
}
