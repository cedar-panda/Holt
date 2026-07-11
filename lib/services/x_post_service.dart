import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'secure_store.dart';

/// X (Twitter) OAuth2 PKCE + 發文服務
///
/// 憑證模型：
///   - client_id 全局一份（用戶在 X Developer Portal 自己申請，
///     App type = Native App / Public client，免 client_secret）
///   - access/refresh token 每角色一份（角色可綁不同 X 帳號）
/// 回調：redirect_uri = holt://x-callback（AndroidManifest 註冊 scheme，
///   main.dart 用 app_links 監聽後轉交 handleCallback）
/// ⚠️ 憑 X API v2 文檔編寫，未真機驗證。
class XPostService {
  static const String _authorizeUrl = 'https://x.com/i/oauth2/authorize';
  static const String _tokenUrl = 'https://api.x.com/2/oauth2/token';
  static const String _tweetUrl = 'https://api.x.com/2/tweets';
  static const String _meUrl = 'https://api.x.com/2/users/me';
  static const String redirectUri = 'holt://x-callback';
  static const String _scopes =
      'tweet.read tweet.write users.read offline.access';

  static const String _kClientId = 'x_client_id';

  // 進行中的授權流（一次只允許一個角色在連）
  static String? _pendingVerifier;
  static String? _pendingCharId;
  static String? _pendingState;

  /// 連接結果回調（x_post_panel 註冊，收 'ok' / 錯誤訊息）
  static void Function(String result)? onConnectResult;

  // ─── client_id ───
  static Future<String> clientId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kClientId) ?? '';
  }

  static Future<void> setClientId(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kClientId, v.trim());
  }

  // ─── token 存取（SecureStore，每角色）───
  static String _tk(String base, String charId) => 'x_${base}_$charId';

  static Future<bool> isConnected(String charId) async =>
      (await SecureStore.read(_tk('access', charId))).isNotEmpty;

  static Future<void> disconnect(String charId) async {
    await SecureStore.delete(_tk('access', charId));
    await SecureStore.delete(_tk('refresh', charId));
  }

  // ─── 授權流 ───
  static String _randomString(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// 開瀏覽器發起授權。回調由 handleCallback 接。
  static Future<String?> startConnect(String charId) async {
    final cid = await clientId();
    if (cid.isEmpty) return '請先填入 X App 的 Client ID';

    _pendingVerifier = _randomString(64);
    _pendingCharId = charId;
    _pendingState = _randomString(24);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(_pendingVerifier!)).bytes,
    ).replaceAll('=', '');

    final uri = Uri.parse(_authorizeUrl).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': cid,
        'redirect_uri': redirectUri,
        'scope': _scopes,
        'state': _pendingState!,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return ok ? null : '無法打開瀏覽器';
  }

  /// main.dart 收到 holt://x-callback 後調用
  static Future<void> handleCallback(Uri uri) async {
    final charId = _pendingCharId;
    final verifier = _pendingVerifier;
    _pendingCharId = null;
    _pendingVerifier = null;
    if (charId == null || verifier == null) return;

    final err = uri.queryParameters['error'];
    if (err != null) {
      onConnectResult?.call('授權被拒絕：$err');
      return;
    }
    if (uri.queryParameters['state'] != _pendingState) {
      onConnectResult?.call('state 校驗失敗，請重試');
      return;
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      onConnectResult?.call('回調缺少 code');
      return;
    }

    try {
      final resp = await http
          .post(
            Uri.parse(_tokenUrl),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'client_id': await clientId(),
              'redirect_uri': redirectUri,
              'code_verifier': verifier,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        onConnectResult?.call('換取 token 失敗 ${resp.statusCode}');
        return;
      }
      final data = jsonDecode(resp.body);
      await SecureStore.write(
        _tk('access', charId),
        data['access_token'] ?? '',
      );
      await SecureStore.write(
        _tk('refresh', charId),
        data['refresh_token'] ?? '',
      );
      onConnectResult?.call('ok');
    } catch (e) {
      onConnectResult?.call('連接失敗：$e');
    }
  }

  static Future<bool> _refresh(String charId) async {
    final rt = await SecureStore.read(_tk('refresh', charId));
    if (rt.isEmpty) return false;
    try {
      final resp = await http
          .post(
            Uri.parse(_tokenUrl),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'grant_type': 'refresh_token',
              'refresh_token': rt,
              'client_id': await clientId(),
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(resp.body);
      await SecureStore.write(
        _tk('access', charId),
        data['access_token'] ?? '',
      );
      final newRt = data['refresh_token'];
      if (newRt is String && newRt.isNotEmpty) {
        await SecureStore.write(_tk('refresh', charId), newRt);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 發推文。成功返回 null，失敗返回原因。401 自動 refresh 重試一次。
  static Future<String?> postTweet(String charId, String text) async {
    var token = await SecureStore.read(_tk('access', charId));
    if (token.isEmpty) return '尚未連接 X 帳號';
    final content = text.length > 280 ? text.substring(0, 280) : text;

    Future<http.Response> send(String tk) => http
        .post(
          Uri.parse(_tweetUrl),
          headers: {
            'Authorization': 'Bearer $tk',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'text': content}),
        )
        .timeout(const Duration(seconds: 30));

    try {
      var resp = await send(token);
      if (resp.statusCode == 401 && await _refresh(charId)) {
        token = await SecureStore.read(_tk('access', charId));
        resp = await send(token);
      }
      if (resp.statusCode == 201 || resp.statusCode == 200) return null;
      return '發文失敗 ${resp.statusCode}：${resp.body}';
    } catch (e) {
      return '發文失敗：$e';
    }
  }

  /// 取當前連接帳號的 @handle（成功順手回填 XPostSettings 用）
  static Future<String?> fetchHandle(String charId) async {
    var token = await SecureStore.read(_tk('access', charId));
    if (token.isEmpty) return null;
    try {
      var resp = await http
          .get(Uri.parse(_meUrl), headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401 && await _refresh(charId)) {
        token = await SecureStore.read(_tk('access', charId));
        resp = await http
            .get(Uri.parse(_meUrl), headers: {'Authorization': 'Bearer $token'})
            .timeout(const Duration(seconds: 20));
      }
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body)['data']?['username'] as String?;
    } catch (_) {
      return null;
    }
  }
}
