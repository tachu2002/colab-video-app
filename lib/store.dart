import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';

class HistoryItem {
  final String id, ja, en, mode, ratio, preset, lora, path;
  final int seconds, seed;
  final DateTime createdAt;
  HistoryItem({
    required this.id, required this.ja, required this.en, required this.mode,
    required this.ratio, required this.preset, required this.lora, required this.path,
    required this.seconds, required this.seed, required this.createdAt,
  });
  Map<String, dynamic> toJson() => {
        'id': id, 'ja': ja, 'en': en, 'mode': mode, 'ratio': ratio, 'preset': preset,
        'lora': lora, 'path': path, 'seconds': seconds, 'seed': seed,
        'createdAt': createdAt.toIso8601String(),
      };
  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        id: j['id'], ja: j['ja'], en: j['en'], mode: j['mode'], ratio: j['ratio'],
        preset: j['preset'], lora: j['lora'], path: j['path'], seconds: j['seconds'],
        seed: j['seed'], createdAt: DateTime.parse(j['createdAt']),
      );
}

/// アプリ全体の状態（接続情報・履歴）。端末の中だけに保存する。
class AppState extends ChangeNotifier {
  ColabStatus? status;
  List<HistoryItem> history = [];
  String? driveError;
  bool busy = false;
  String checkpoint = ''; // 空 = 標準のH3
  late SharedPreferences _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final s = _p.getString('status');
    if (s != null) {
      try { status = ColabStatus.fromJson(jsonDecode(s)); } catch (_) {}
    }
    checkpoint = _p.getString('checkpoint') ?? '';
    final h = _p.getString('history');
    if (h != null) {
      try {
        history = (jsonDecode(h) as List).map((e) => HistoryItem.fromJson(e)).toList();
      } catch (_) {}
    }
    notifyListeners();
  }

  void _saveStatus(Map<String, dynamic> raw) {
    status = ColabStatus.fromJson(raw);
    _p.setString('status', jsonEncode(raw));
  }

  static const statusFileId = '1FE8pG48hFteyNRhyDWzcDbAfjWufkyYZ';

  /// 共有リンクの status.json を自動で読む（貼り付け不要）
  Future<void> refreshFromDrive() async {
    if (busy) return;
    busy = true; driveError = null; notifyListeners();
    try {
      final t = DateTime.now().millisecondsSinceEpoch;
      final urls = [
        'https://drive.usercontent.google.com/download?id=$statusFileId&export=download&t=$t',
        'https://drive.google.com/uc?export=download&id=$statusFileId&t=$t',
      ];
      Object? last;
      for (final u in urls) {
        try {
          final r = await http.get(Uri.parse(u), headers: {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 20));
          if (r.statusCode != 200) { last = 'HTTP ${r.statusCode}'; continue; }
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (j is Map<String, dynamic> && j['comfy_url'] != null) {
            _saveStatus(j);
            last = null;
            break;
          }
          last = '形式が違います';
        } catch (e) { last = e; }
      }
      if (last != null) throw ApiException('接続情報を読めませんでした（$last）。Colabが動いているか、通信を確認してください');
    } catch (e) {
      driveError = e.toString();
    } finally {
      busy = false; notifyListeners();
    }
  }

  void setCheckpoint(String v) { checkpoint = v; _p.setString('checkpoint', v); notifyListeners(); }

  /// 古ければ読み直す（生成前など）
  Future<void> ensureFresh() async {
    if (status == null || status!.isStale) await refreshFromDrive();
  }

  /// Drive連携を使わず、URLとトークンを直接入れる場合
  void setManual({required String comfyUrl, required String helperUrl, required String token}) {
    final raw = <String, dynamic>{
      'comfy_url': comfyUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      'helper_url': helperUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      'helper_token': token.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'state': 'running',
      'gpu': {'name': '手動入力', 'key': ''},
      'usage': {'source': 'unavailable'},
      'models': {'loras': []},
      'presets': [
        {'id': 'standard', 'label': '標準 704×1280', 'max_sec': 10, 'est_min': 3, 'measured': true},
        {'id': 'high', 'label': '高画質 960×1728', 'max_sec': 10, 'est_min': 12, 'measured': true},
        {'id': 'fullhd', 'label': 'フルHD 1088×1920', 'max_sec': 8, 'est_min': 11, 'measured': true},
      ],
    };
    _saveStatus(raw);
    notifyListeners();
  }

  /// 貼り付けた文字から接続情報を作る（status.json の中身そのまま、または comfy_url / helper_url / helper_token を含むJSON）
  String? setFromText(String text) {
    try {
      final j = jsonDecode(text.trim());
      if (j is! Map) return '形式が違います';
      final c = (j['comfy_url'] ?? '').toString(), h = (j['helper_url'] ?? '').toString(), tk = (j['helper_token'] ?? '').toString();
      if (c.isEmpty || h.isEmpty || tk.isEmpty) return 'comfy_url / helper_url / helper_token が足りません';
      setManual(comfyUrl: c, helperUrl: h, token: tk);
      return null;
    } catch (_) {
      return 'JSONとして読めませんでした。コピーし直してください';
    }
  }

  /// 動画をスマホの「ダウンロード」フォルダへ保存
  Future<void> saveToDownloads(HistoryItem it) async {
    if (!await File(it.path).exists()) throw ApiException('動画ファイルが端末に見つかりません');
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = 'ColabVideo';
    final res = await MediaStore().saveFile(
      tempFilePath: it.path,
      dirType: DirType.download,
      dirName: DirName.download,
    );
    // 返り値がnull、または保存の成否を持つ場合は失敗として扱う
    if (res == null) throw ApiException('保存できませんでした（端末が書き込みを受け付けませんでした）');
  }

  // ---- 履歴 ----
  Future<Directory> _videoDir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/videos');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> saveVideo(String id, Uri url) async {
    final r = await http.get(url).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) throw ApiException('動画の取得に失敗しました (${r.statusCode})');
    final f = File('${(await _videoDir()).path}/$id.mp4');
    await f.writeAsBytes(r.bodyBytes);
    return f.path;
  }

  void addHistory(HistoryItem it) {
    history.insert(0, it);
    _persistHistory();
  }

  Future<void> deleteHistory(HistoryItem it) async {
    history.removeWhere((e) => e.id == it.id);
    try { await File(it.path).delete(); } catch (_) {}
    _persistHistory();
  }

  void _persistHistory() {
    _p.setString('history', jsonEncode(history.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  // 生成画面で使う「再生成」用の一時置き場
  HistoryItem? regenerateFrom;
  int requestedTab = -1;
  void regenerate(HistoryItem it) {
    regenerateFrom = it;
    requestedTab = 1;
    notifyListeners();
  }
}
