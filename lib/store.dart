import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
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
  GoogleSignInAccount? account;

  final _google = GoogleSignIn(scopes: ['https://www.googleapis.com/auth/drive.readonly']);
  late SharedPreferences _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final s = _p.getString('status');
    if (s != null) {
      try { status = ColabStatus.fromJson(jsonDecode(s)); } catch (_) {}
    }
    final h = _p.getString('history');
    if (h != null) {
      try {
        history = (jsonDecode(h) as List).map((e) => HistoryItem.fromJson(e)).toList();
      } catch (_) {}
    }
    try { account = await _google.signInSilently(); } catch (_) {}
    notifyListeners();
  }

  void _saveStatus(Map<String, dynamic> raw) {
    status = ColabStatus.fromJson(raw);
    _p.setString('status', jsonEncode(raw));
  }

  /// Driveの ColabVideoApp/status.json を読む（ここが「再接続」の本体）
  Future<void> refreshFromDrive() async {
    busy = true; driveError = null; notifyListeners();
    try {
      account ??= await _google.signIn();
      if (account == null) throw ApiException('Googleアカウントでのサインインが必要です');
      final h = await account!.authHeaders;
      Future<dynamic> get(String url) async {
        final r = await http.get(Uri.parse(url), headers: h).timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) throw ApiException('Driveの読み取りに失敗しました (${r.statusCode})');
        return r;
      }
      final folders = jsonDecode((await get(
          'https://www.googleapis.com/drive/v3/files?q=${Uri.encodeQueryComponent("name='ColabVideoApp' and mimeType='application/vnd.google-apps.folder' and trashed=false")}&fields=files(id)')).body);
      if ((folders['files'] as List).isEmpty) throw ApiException('Driveに ColabVideoApp フォルダがありません。先にColabのノートブックを実行してください');
      final fid = folders['files'][0]['id'];
      final files = jsonDecode((await get(
          'https://www.googleapis.com/drive/v3/files?q=${Uri.encodeQueryComponent("'$fid' in parents and name='status.json' and trashed=false")}&fields=files(id)')).body);
      if ((files['files'] as List).isEmpty) throw ApiException('status.json がありません。Colabのノートブックを実行してください');
      final id = files['files'][0]['id'];
      final body = (await get('https://www.googleapis.com/drive/v3/files/$id?alt=media')).bodyBytes;
      _saveStatus(jsonDecode(utf8.decode(body)));
    } catch (e) {
      driveError = e.toString();
    } finally {
      busy = false; notifyListeners();
    }
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

  Future<void> signOut() async {
    await _google.signOut();
    account = null;
    notifyListeners();
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
