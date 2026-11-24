import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'queue.dart';

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
  double? unitsBase, unitsRate; // アプリで入力した残りユニットと消費ペース
  DateTime? unitsBaseAt;
  String checkpoint = ''; // 空 = 標準のH3
  String profile = ''; // 空=標準 / pika / prism / prism_dmad
  bool fast = false;
  bool enc32 = false;
  late SharedPreferences _p;
  late final JobQueue queue = JobQueue(this); // 生成の予約（順番に1本ずつ作る）

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final s = _p.getString('status');
    if (s != null) {
      try { status = ColabStatus.fromJson(jsonDecode(s)); } catch (_) {}
    }
    checkpoint = _p.getString('checkpoint') ?? '';
    profile = _p.getString('profile') ?? '';
    fast = _p.getBool('fast') ?? false;
    enc32 = _p.getBool('enc32') ?? false;
    unitsBase = _p.getDouble('unitsBase');
    unitsRate = _p.getDouble('unitsRate');
    final ub = _p.getString('unitsBaseAt');
    unitsBaseAt = ub == null ? null : DateTime.tryParse(ub);
    final h = _p.getString('history');
    if (h != null) {
      try {
        history = (jsonDecode(h) as List).map((e) => HistoryItem.fromJson(e)).toList();
      } catch (_) {}
    }
    // 動画ファイルが無くなった履歴は取り除く（再インストールなどで消えた場合）
    final before = history.length;
    history.removeWhere((e) => !File(e.path).existsSync());
    if (history.length != before) _p.setString('history', jsonEncode(history.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  void _saveStatus(Map<String, dynamic> raw) {
    status = ColabStatus.fromJson(raw);
    _p.setString('status', jsonEncode(raw));
  }

  static const statusFileId = '18xyhxgp8Z4mnfzZkhsjZg9tIpj29GG8g';

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

  /// Colabの「リソースを表示」で見た値を入れる
  void setUnits(double remaining, double? rate) {
    unitsBase = remaining; unitsRate = rate; unitsBaseAt = DateTime.now();
    _p.setDouble('unitsBase', remaining);
    if (rate != null) { _p.setDouble('unitsRate', rate); } else { _p.remove('unitsRate'); }
    _p.setString('unitsBaseAt', unitsBaseAt!.toIso8601String());
    notifyListeners();
  }

  /// 入力した値から、Colabが動いていた時間ぶんを引いた概算
  double? estimatedUnits(bool running) {
    if (unitsBase == null) return null;
    if (!running || unitsRate == null || unitsBaseAt == null) return unitsBase;
    final h = DateTime.now().difference(unitsBaseAt!).inSeconds / 3600;
    final v = unitsBase! - unitsRate! * h;
    return v < 0 ? 0 : v;
  }

  void setProfile(String v) { profile = v; _p.setString('profile', v); notifyListeners(); }
  void setEnc32(bool v) { enc32 = v; _p.setBool('enc32', v); notifyListeners(); }
  void setFast(bool v) { fast = v; _p.setBool('fast', v); notifyListeners(); }

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
  static const _chan = MethodChannel('app/save');

  Future<void> saveToDownloads(HistoryItem it) async {
    if (!await File(it.path).exists()) throw ApiException('動画ファイルが端末に見つかりません');
    try {
      await _chan.invokeMethod('saveToDownloads', {'path': it.path, 'name': 'video_${it.id}.mp4'});
    } on PlatformException catch (e) {
      throw ApiException(e.message ?? '保存できませんでした');
    }
  }

  // ---- 履歴 ----
  Future<Directory> _videoDir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/videos');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 動画を端末へ保存する。回線が途中で切れても、続きから再開して取り直す（最大12回）
  Future<String> saveVideo(String id, Uri url) async {
    final f = File('${(await _videoDir()).path}/$id.mp4');
    final part = File('${f.path}.part');
    if (await part.exists()) await part.delete();
    int? total;
    Object? lastErr;
    for (var attempt = 0; attempt < 12; attempt++) {
      final have = await part.exists() ? await part.length() : 0;
      final client = http.Client();
      try {
        final req = http.Request('GET', url);
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final res = await client.send(req).timeout(const Duration(seconds: 60));
        if (res.statusCode != 200 && res.statusCode != 206) throw ApiException('動画の取得に失敗しました (${res.statusCode})');
        final resumed = res.statusCode == 206;
        if (!resumed && have > 0) await part.writeAsBytes(const []);   // 続きに対応していないときは、最初から
        final len = res.contentLength;
        if (len != null) total = (resumed ? have : 0) + len;
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        try {
          await sink.addStream(res.stream.timeout(const Duration(seconds: 60)));
        } finally {
          await sink.close();
        }
        final got = await part.length();
        if (total == null || got >= total) {
          if (await f.exists()) await f.delete();
          await part.rename(f.path);
          return f.path;
        }
        lastErr = '途中で切れました ($got/$total)';
      } catch (e) {
        lastErr = e;
      } finally {
        client.close();
      }
      await Future.delayed(Duration(seconds: 2 + attempt));
    }
    throw ApiException('動画の取得が途中で切れました。通信の良い場所で、履歴の「同じ設定でつくり直す」か、もう一度お試しください: $lastErr');
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
