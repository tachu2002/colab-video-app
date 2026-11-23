import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// ノートブックが Drive に書き出す status.json の中身
class ColabStatus {
  final String comfyUrl, helperUrl, token, gpuName, gpuKey, usageSource, state;
  final DateTime? updatedAt;
  final double? unitsPerHour, unitsRemaining;
  final List<PresetInfo> presets;
  final List<String> loras;

  ColabStatus({
    required this.comfyUrl, required this.helperUrl, required this.token,
    required this.gpuName, required this.gpuKey, required this.usageSource,
    required this.state, required this.updatedAt, required this.unitsPerHour,
    required this.unitsRemaining, required this.presets, required this.loras,
  });

  factory ColabStatus.fromJson(Map<String, dynamic> j) {
    final gpu = (j['gpu'] ?? {}) as Map;
    final usage = (j['usage'] ?? {}) as Map;
    final models = (j['models'] ?? {}) as Map;
    return ColabStatus(
      comfyUrl: (j['comfy_url'] ?? '') as String,
      helperUrl: (j['helper_url'] ?? '') as String,
      token: (j['helper_token'] ?? '') as String,
      gpuName: (gpu['name'] ?? '') as String,
      gpuKey: (gpu['key'] ?? '') as String,
      usageSource: (usage['source'] ?? 'unavailable') as String,
      state: (j['state'] ?? '') as String,
      updatedAt: DateTime.tryParse((j['updated_at'] ?? '') as String),
      unitsPerHour: (usage['units_per_hour'] as num?)?.toDouble(),
      unitsRemaining: (usage['units_remaining'] as num?)?.toDouble(),
      presets: ((j['presets'] ?? []) as List)
          .map((e) => PresetInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      loras: ((models['loras'] ?? []) as List).map((e) => e.toString()).toList(),
    );
  }

  /// 更新が90秒以上止まっていたら「停止中」とみなす
  bool get isStale {
    if (updatedAt == null) return true;
    return DateTime.now().toUtc().difference(updatedAt!.toUtc()).inSeconds > 90;
  }

  bool get isRunning => !isStale && state == 'running';
}

class PresetInfo {
  final String id, label;
  final int maxSec, estMin;
  final bool measured;
  PresetInfo(this.id, this.label, this.maxSec, this.estMin, this.measured);
  factory PresetInfo.fromJson(Map<String, dynamic> j) => PresetInfo(
        j['id'] as String, j['label'] as String,
        (j['max_sec'] as num).toInt(), (j['est_min'] as num).toInt(),
        (j['measured'] ?? false) as bool,
      );
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// ヘルパーAPI（Colab上のFastAPI）とのやり取り
class HelperApi {
  final ColabStatus s;
  HelperApi(this.s);

  Map<String, String> get _h => {'X-Token': s.token, 'Content-Type': 'application/json'};

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('${s.helperUrl}$path');
    final req = http.Request(method, uri)..headers.addAll(_h);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 240)));
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      String msg = text;
      try { msg = (jsonDecode(text)['detail'] ?? text).toString(); } catch (_) {}
      throw ApiException(msg);
    }
    return jsonDecode(text);
  }

  /// 動画 → H3用の英語プロンプト。時間がかかるので、ジョブにして進み具合を聞きに行く
  Future<String> videoPrompt(String videoB64, int seconds, void Function(String) onStage, bool Function() cancelled) async {
    final j = await _send('POST', '/video_prompt', {'video_b64': videoB64, 'seconds': seconds});
    final id = j['job'] as String;
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0).inMinutes < 25) {
      if (cancelled()) throw ApiException('中止しました');
      await Future.delayed(const Duration(seconds: 3));
      Map r;
      try { r = await _send('GET', '/video_prompt/job/$id') as Map; } on ApiException { rethrow; } catch (_) { continue; }
      onStage((r['stage'] ?? '').toString());
      if (r['state'] == 'done') return r['en'] as String;
      if (r['state'] == 'error') throw ApiException((r['error'] ?? '失敗しました').toString());
    }
    throw ApiException('時間がかかりすぎました。もう一度試してください');
  }

  Future<String> addDetail(String en, String hair, String outfit) async {
    final j = await _send('POST', '/add_detail', {'en': en, 'hair': hair, 'outfit': outfit});
    return j['en'] as String;
  }

  Future<bool> health() async {
    try {
      final r = await http.get(Uri.parse('${s.helperUrl}/health')).timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> random([int seconds = 5]) async {
    final j = await _send('POST', '/random', {'seconds': seconds});
    return {'ja': j['ja'] as String, 'en': j['en'] as String};
  }

  Future<String> translate(String ja, [int seconds = 5]) async {
    final j = await _send('POST', '/translate', {'ja': ja, 'seconds': seconds});
    return j['en'] as String;
  }

  Future<List<String>> loras() async {
    final j = await _send('GET', '/loras');
    return (j['loras'] as List).map((e) => e.toString()).toList();
  }

  Future<Map<String, dynamic>> models() async => Map<String, dynamic>.from(await _send('GET', '/models'));

  Future<Map<String, dynamic>> download(String url, String kind, String filename, String token) async =>
      Map<String, dynamic>.from(await _send('POST', '/download', {'url': url, 'kind': kind, 'filename': filename, 'token': token}));

  Future<Map<String, dynamic>> driveList() async => Map<String, dynamic>.from(await _send('GET', '/drive/list'));

  Future<Map<String, dynamic>> driveImport(String kind, String name) async =>
      Map<String, dynamic>.from(await _send('POST', '/drive/import', {'kind': kind, 'name': name}));

  Future<Map<String, dynamic>> downloadStatus(String id) async => Map<String, dynamic>.from(await _send('GET', '/download/$id'));

  Future<List<String>> refmods() async {
    final j = await _send('GET', '/refmods');
    return (j['refmods'] as List).map((e) => e.toString()).toList();
  }

  Future<String> createRefmod(String name, List<String> imagesB64, String detail, [bool faceCrop = false]) async {
    final j = await _send('POST', '/refmods', {'name': name, 'images_b64': imagesB64, 'detail': detail, 'face_crop': faceCrop});
    return j['id'] as String;
  }

  Future<Map<String, dynamic>> refmodJob(String id) async => Map<String, dynamic>.from(await _send('GET', '/refmods/job/$id'));

  Future<void> deleteRefmod(String name) async { await _send('DELETE', '/refmods?name=${Uri.encodeQueryComponent(name)}'); }

  Future<void> deleteLora(String name) async { await _send('DELETE', '/models?kind=lora&name=${Uri.encodeQueryComponent(name)}'); }

  /// 生成を開始して prompt_id を返す
  Future<String> generate({
    required String mode, required String promptEn, required double seconds,
    required String aspect, required String preset, required int seed,
    required List<String> imagesB64, required String lora,
    required double loraStrength, required String clientId, String checkpoint = '',
    List<Map<String, dynamic>> refmods = const [], String videoB64 = '',
  }) async {
    final j = await _send('POST', '/generate', {
      'mode': mode, 'prompt_en': promptEn, 'seconds': seconds, 'aspect': aspect,
      'preset': preset, 'seed': seed, 'images_b64': imagesB64, 'lora': lora,
      'lora_strength': loraStrength, 'client_id': clientId, 'checkpoint': checkpoint, 'refmods': refmods, 'video_b64': videoB64,
    });
    return j['prompt_id'] as String;
  }
}

class VideoRef {
  final String filename, subfolder, type;
  VideoRef(this.filename, this.subfolder, this.type);
}

/// ComfyUI本体（進捗の受信・結果の取得・中止）
class ComfyApi {
  final String base;
  ComfyApi(this.base);

  Uri wsUri(String clientId) {
    final u = Uri.parse(base);
    return Uri(scheme: u.scheme == 'https' ? 'wss' : 'ws', host: u.host,
        port: u.hasPort ? u.port : null, path: '/ws', queryParameters: {'clientId': clientId});
  }

  /// 完成していれば動画の場所を返す。失敗ならApiException、まだなら null
  Future<VideoRef?> result(String promptId) async {
    final r = await http.get(Uri.parse('$base/history/$promptId')).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final e = j[promptId];
    if (e == null) return null;
    final status = e['status'] as Map<String, dynamic>?;
    if (status != null && status['status_str'] == 'error') {
      String msg = '生成に失敗しました';
      for (final m in (status['messages'] as List)) {
        if (m is List && m.isNotEmpty && m[0] == 'execution_error') {
          msg = (m[1]['exception_message'] ?? msg).toString();
        }
      }
      throw ApiException(msg);
    }
    final outs = (e['outputs'] ?? {}) as Map<String, dynamic>;
    for (final o in outs.values) {
      final imgs = (o['images'] ?? []) as List;
      if (imgs.isNotEmpty) {
        final f = imgs.first as Map<String, dynamic>;
        return VideoRef(f['filename'] as String, (f['subfolder'] ?? '') as String, (f['type'] ?? 'output') as String);
      }
    }
    return null;
  }

  Uri viewUri(VideoRef v) => Uri.parse('$base/view').replace(queryParameters: {
        'filename': v.filename, 'subfolder': v.subfolder, 'type': v.type,
      });

  Future<void> interrupt() async {
    try { await http.post(Uri.parse('$base/interrupt')).timeout(const Duration(seconds: 15)); } catch (_) {}
    try {
      await http.post(Uri.parse('$base/queue'), headers: {'Content-Type': 'application/json'}, body: '{"clear":true}').timeout(const Duration(seconds: 15));
    } catch (_) {}
  }
}
