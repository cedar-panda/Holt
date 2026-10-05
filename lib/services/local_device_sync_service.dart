import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup_service.dart';

/// One-use, local-network transfer of Holt's existing encrypted full backup.
/// The pairing code never travels over HTTP: a short-lived challenge is proved
/// with HMAC, while the backup itself remains AES-GCM encrypted with that code.
class LocalDeviceSyncService {
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const int _maximumBytes = 8 * 1024 * 1024 * 1024;

  static String createPairingCode() {
    final random = Random.secure();
    final raw = List.generate(
      20,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
    return '${raw.substring(0, 5)}-${raw.substring(5, 10)}-'
        '${raw.substring(10, 15)}-${raw.substring(15)}';
  }

  static String normalizeCode(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static bool isValidCode(String code) {
    final normalized = normalizeCode(code);
    return normalized.length == 20 &&
        normalized.split('').every((letter) => _alphabet.contains(letter));
  }

  static bool isPrivateIpv4(String input) {
    final address = InternetAddress.tryParse(input);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }

  static ({String address, int port}) parseTarget(String input) {
    final match = RegExp(r'^\s*([0-9.]+):(\d{1,5})\s*$').firstMatch(input);
    if (match == null || !isPrivateIpv4(match.group(1)!)) {
      throw const FormatException('Enter the sender’s private Wi-Fi address.');
    }
    final port = int.parse(match.group(2)!);
    if (port < 1 || port > 65535) {
      throw const FormatException('Invalid transfer port.');
    }
    return (address: match.group(1)!, port: port);
  }

  static Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final preferred = <String>[];
    final other = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!isPrivateIpv4(address.address)) continue;
        if (RegExp(
          r'^(en0|wlan\d*|wifi\d*)$',
          caseSensitive: false,
        ).hasMatch(interface.name)) {
          preferred.add(address.address);
        } else {
          other.add(address.address);
        }
      }
    }
    return {...preferred, ...other}.toList(growable: false);
  }

  static Future<LocalDeviceSyncHost> startHost({
    required String code,
    void Function()? onDelivered,
    void Function()? onExpired,
  }) async {
    if (!isValidCode(code)) {
      throw const FormatException('Invalid pairing code.');
    }
    final artifact = await BackupService.exportPortableBundle(
      password: normalizeCode(code),
    );
    try {
      if (await File(artifact).length() > _maximumBytes) {
        throw const FormatException('Backup exceeds the transfer size limit.');
      }
      final addresses = await localAddresses();
      if (addresses.isEmpty) {
        throw const SocketException('No private Wi-Fi address is available.');
      }
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      return LocalDeviceSyncHost._(
        server: server,
        artifact: File(artifact),
        code: normalizeCode(code),
        addresses: addresses,
        onDelivered: onDelivered,
        onExpired: onExpired,
      ).._listen();
    } catch (_) {
      await BackupService.discardExportArtifact(artifact);
      rethrow;
    }
  }

  static Future<File> receive({
    required String target,
    required String code,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!isValidCode(code)) {
      throw const FormatException('Invalid pairing code.');
    }
    final endpoint = parseTarget(target);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false
      ..findProxy = (_) => 'DIRECT';
    File? output;
    try {
      final base = Uri(
        scheme: 'http',
        host: endpoint.address,
        port: endpoint.port,
      );
      final challengeRequest = await client.getUrl(
        base.replace(path: '/challenge'),
      );
      challengeRequest.followRedirects = false;
      final challengeResponse = await challengeRequest.close().timeout(
        const Duration(seconds: 15),
      );
      if (challengeResponse.statusCode != HttpStatus.ok) {
        throw const FormatException('The sender is unavailable.');
      }
      final challengeBody = await utf8.decoder
          .bind(challengeResponse)
          .join()
          .timeout(const Duration(seconds: 15));
      final challenge = jsonDecode(challengeBody);
      if (challenge is! Map<String, dynamic> ||
          challenge['type'] != 'holt_local_sync_v1' ||
          challenge['nonce'] is! String) {
        throw const FormatException('This is not a Holt transfer.');
      }
      final nonce = challenge['nonce'] as String;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce)) {
        throw const FormatException('Invalid transfer challenge.');
      }
      final proof = _proof(normalizeCode(code), nonce);
      final request = await client.getUrl(base.replace(path: '/transfer'));
      request.followRedirects = false;
      request.headers.set('X-Holt-Proof', proof);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw const FormatException(
          'The pairing code was rejected or expired.',
        );
      }
      final expected = response.contentLength;
      if (expected > _maximumBytes) {
        throw const FormatException('Backup exceeds the transfer size limit.');
      }
      final directory = await getTemporaryDirectory();
      output = File(
        p.join(
          directory.path,
          'holt_sync_${DateTime.now().microsecondsSinceEpoch}.holt.backup',
        ),
      );
      final sink = output.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(minutes: 2),
        )) {
          received += chunk.length;
          if (received > _maximumBytes ||
              (expected >= 0 && received > expected)) {
            throw const FormatException('Invalid transfer size.');
          }
          sink.add(chunk);
          onProgress?.call(received, expected < 0 ? null : expected);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if ((expected >= 0 && received != expected) ||
          !await BackupService.isEncryptedBackup(output.path)) {
        throw const FormatException('The received backup is incomplete.');
      }
      return output;
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static String _proof(String code, String nonce) =>
      Hmac(sha256, utf8.encode(code)).convert(utf8.encode(nonce)).toString();
}

class LocalDeviceSyncHost {
  final HttpServer _server;
  final File _artifact;
  final String _code;
  final void Function()? _onDelivered;
  final void Function()? _onExpired;
  final List<String> addresses;
  StreamSubscription<HttpRequest>? _subscription;
  String? _challenge;
  DateTime? _challengeAt;
  Timer? _expiry;
  bool _used = false;
  bool _closed = false;
  int _failedProofs = 0;

  LocalDeviceSyncHost._({
    required HttpServer server,
    required File artifact,
    required String code,
    required this.addresses,
    void Function()? onDelivered,
    void Function()? onExpired,
  }) : _server = server,
       _artifact = artifact,
       _code = code,
       _onDelivered = onDelivered,
       _onExpired = onExpired;

  int get port => _server.port;
  bool get isUsed => _used;
  bool get isClosed => _closed;

  void _listen() {
    _expiry = Timer(const Duration(minutes: 10), () {
      _onExpired?.call();
      unawaited(close());
    });
    _subscription = _server.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var delivered = false;
    try {
      if (_closed ||
          _used ||
          request.method != 'GET' ||
          !LocalDeviceSyncService.isPrivateIpv4(
            request.connectionInfo?.remoteAddress.address ?? '',
          )) {
        response.statusCode = HttpStatus.forbidden;
      } else if (request.uri.path == '/challenge') {
        final random = Random.secure();
        _challenge = List.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        _challengeAt = DateTime.now();
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({'type': 'holt_local_sync_v1', 'nonce': _challenge}),
        );
      } else if (request.uri.path == '/transfer') {
        final challenge = _challenge;
        final proof = request.headers.value('X-Holt-Proof') ?? '';
        _challenge = null;
        if (challenge == null ||
            _challengeAt == null ||
            DateTime.now().difference(_challengeAt!) >
                const Duration(minutes: 1) ||
            !_constantTimeEquals(
              proof,
              LocalDeviceSyncService._proof(_code, challenge),
            )) {
          _failedProofs++;
          response.statusCode = HttpStatus.forbidden;
          if (_failedProofs >= 5) unawaited(close());
        } else {
          _used = true;
          _expiry?.cancel();
          response.headers.contentType = ContentType.binary;
          response.contentLength = await _artifact.length();
          await response.addStream(_artifact.openRead());
          delivered = true;
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      if (_used && !delivered) {
        // A disconnected receiver did not consume the one-use transfer.
        _used = false;
        _expiry = Timer(const Duration(minutes: 10), () {
          _onExpired?.call();
          unawaited(close());
        });
      }
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      try {
        await response.close();
        if (delivered) _onDelivered?.call();
      } catch (_) {}
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    await _subscription?.cancel();
    await _server.close(force: true);
    await BackupService.discardExportArtifact(_artifact.path);
  }
}
