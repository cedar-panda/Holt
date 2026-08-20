import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Password-encrypted wrapper for Holt portable ZIP backups.
///
/// The file is streamed in independent AES-256-GCM chunks so large media
/// backups do not have to be loaded into memory at once. The password is
/// expanded with PBKDF2-HMAC-SHA256 and a fresh random salt for every export.
class EncryptedBackupBundle {
  static const int formatVersion = 1;
  static const int defaultIterations = 600000;
  static const int defaultChunkSize = 1024 * 1024;
  static const int _macLength = 16;
  static const int _saltLength = 16;
  static const int _noncePrefixLength = 8;
  static const int _maxHeaderLength = 64 * 1024;
  static const int _maxIterations = 2000000;
  static const List<int> magic = <int>[
    0x48,
    0x4F,
    0x4C,
    0x54,
    0x42,
    0x4B,
    0x50,
    0x31,
  ]; // HOLTBKP1

  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _secureRandom = Random.secure();

  static Future<bool> isEncrypted(File file) async {
    if (!await file.exists() || await file.length() < magic.length) {
      return false;
    }
    final handle = await file.open();
    try {
      final prefix = await handle.read(magic.length);
      return _bytesEqual(prefix, magic);
    } finally {
      await handle.close();
    }
  }

  static Future<File> encrypt({
    required File source,
    required File destination,
    required String password,
    int iterations = defaultIterations,
    int chunkSize = defaultChunkSize,
  }) async {
    _validatePassword(password);
    _validateParameters(iterations: iterations, chunkSize: chunkSize);
    if (source.absolute.path == destination.absolute.path) {
      throw ArgumentError('Source and destination must be different files');
    }

    final salt = _randomBytes(_saltLength);
    final noncePrefix = _randomBytes(_noncePrefixLength);
    final headerBytes = utf8.encode(
      jsonEncode(<String, Object>{
        'type': 'holt_encrypted_backup',
        'version': formatVersion,
        'kdf': 'pbkdf2-hmac-sha256',
        'iterations': iterations,
        'salt': base64Encode(salt),
        'cipher': 'aes-256-gcm',
        'chunk_size': chunkSize,
        'nonce_prefix': base64Encode(noncePrefix),
      }),
    );
    final headerLengthBytes = _uint32(headerBytes.length);
    final associatedPrefix = <int>[
      ...magic,
      ...headerLengthBytes,
      ...headerBytes,
    ];
    final secretKey = await _deriveKey(
      password: password,
      salt: salt,
      iterations: iterations,
    );

    final input = await source.open();
    final output = await destination.open(mode: FileMode.write);
    var chunkIndex = 0;
    try {
      await output.writeFrom(associatedPrefix);
      while (true) {
        final clearText = await input.read(chunkSize);
        if (clearText.isEmpty) break;
        final indexBytes = _uint32(chunkIndex);
        final secretBox = await _cipher.encrypt(
          clearText,
          secretKey: secretKey,
          nonce: <int>[...noncePrefix, ...indexBytes],
          aad: <int>[...associatedPrefix, ...indexBytes],
        );
        await output.writeFrom(_uint32(secretBox.cipherText.length));
        await output.writeFrom(secretBox.cipherText);
        await output.writeFrom(secretBox.mac.bytes);
        chunkIndex = _nextChunkIndex(chunkIndex);
      }

      // An authenticated empty final record prevents clean chunk-boundary
      // truncation from being accepted as a complete backup.
      final indexBytes = _uint32(chunkIndex);
      final finalBox = await _cipher.encrypt(
        const <int>[],
        secretKey: secretKey,
        nonce: <int>[...noncePrefix, ...indexBytes],
        aad: <int>[...associatedPrefix, ...indexBytes],
      );
      await output.writeFrom(_uint32(0));
      await output.writeFrom(finalBox.mac.bytes);
      await output.flush();
      return destination;
    } catch (_) {
      await output.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    } finally {
      await input.close();
      try {
        await output.close();
      } catch (_) {
        // The error path may already have closed the handle.
      }
    }
  }

  static Future<File> decrypt({
    required File source,
    required File destination,
    required String password,
  }) async {
    _validatePassword(password);
    if (source.absolute.path == destination.absolute.path) {
      throw ArgumentError('Source and destination must be different files');
    }

    final input = await source.open();
    RandomAccessFile? output;
    var completed = false;
    try {
      final foundMagic = await _readExact(input, magic.length);
      if (!_bytesEqual(foundMagic, magic)) {
        throw const FormatException('不是 Holt 加密備份檔');
      }
      final headerLengthBytes = await _readExact(input, 4);
      final headerLength = _readUint32(headerLengthBytes);
      if (headerLength <= 0 || headerLength > _maxHeaderLength) {
        throw const FormatException('加密備份標頭無效');
      }
      final headerBytes = await _readExact(input, headerLength);
      final header = _decodeHeader(headerBytes);
      final iterations = header.iterations;
      final chunkSize = header.chunkSize;
      final noncePrefix = header.noncePrefix;
      final associatedPrefix = <int>[
        ...magic,
        ...headerLengthBytes,
        ...headerBytes,
      ];
      final secretKey = await _deriveKey(
        password: password,
        salt: header.salt,
        iterations: iterations,
      );

      output = await destination.open(mode: FileMode.write);
      var chunkIndex = 0;
      while (true) {
        final cipherLength = _readUint32(await _readExact(input, 4));
        if (cipherLength > chunkSize) {
          throw const FormatException('加密備份資料區塊無效');
        }
        final cipherText = await _readExact(input, cipherLength);
        final macBytes = await _readExact(input, _macLength);
        final indexBytes = _uint32(chunkIndex);
        final clearText = await _cipher.decrypt(
          SecretBox(
            cipherText,
            nonce: <int>[...noncePrefix, ...indexBytes],
            mac: Mac(macBytes),
          ),
          secretKey: secretKey,
          aad: <int>[...associatedPrefix, ...indexBytes],
        );

        if (cipherLength == 0) {
          if (clearText.isNotEmpty ||
              await input.position() != await input.length()) {
            throw const FormatException('加密備份尾端無效');
          }
          await output.flush();
          completed = true;
          return destination;
        }
        await output.writeFrom(clearText);
        chunkIndex = _nextChunkIndex(chunkIndex);
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('備份密碼錯誤或檔案已損壞');
    } finally {
      await input.close();
      if (output != null) await output.close();
      if (!completed) {
        if (await destination.exists()) await destination.delete();
      }
    }
  }

  static _EncryptedHeader _decodeHeader(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['type'] != 'holt_encrypted_backup' ||
          decoded['version'] != formatVersion ||
          decoded['kdf'] != 'pbkdf2-hmac-sha256' ||
          decoded['cipher'] != 'aes-256-gcm') {
        throw const FormatException('不支援的加密備份格式');
      }
      final iterations = decoded['iterations'];
      final chunkSize = decoded['chunk_size'];
      final salt = base64Decode(decoded['salt'] as String);
      final noncePrefix = base64Decode(decoded['nonce_prefix'] as String);
      if (iterations is! int || chunkSize is! int) {
        throw const FormatException('加密備份參數無效');
      }
      _validateParameters(iterations: iterations, chunkSize: chunkSize);
      if (salt.length != _saltLength ||
          noncePrefix.length != _noncePrefixLength) {
        throw const FormatException('加密備份參數無效');
      }
      return _EncryptedHeader(
        iterations: iterations,
        chunkSize: chunkSize,
        salt: salt,
        noncePrefix: noncePrefix,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('加密備份標頭無效');
    }
  }

  static Future<SecretKey> _deriveKey({
    required String password,
    required List<int> salt,
    required int iterations,
  }) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
  }

  static void _validatePassword(String password) {
    if (password.isEmpty) throw const FormatException('備份密碼不可為空');
  }

  static void _validateParameters({
    required int iterations,
    required int chunkSize,
  }) {
    if (iterations < 10000 || iterations > _maxIterations) {
      throw const FormatException('加密備份 KDF 參數無效');
    }
    if (chunkSize < 4096 || chunkSize > 16 * 1024 * 1024) {
      throw const FormatException('加密備份區塊大小無效');
    }
  }

  static List<int> _randomBytes(int length) => List<int>.generate(
    length,
    (_) => _secureRandom.nextInt(256),
    growable: false,
  );

  static int _nextChunkIndex(int current) {
    if (current >= 0xFFFFFFFF) {
      throw const FormatException('加密備份過大');
    }
    return current + 1;
  }

  static Uint8List _uint32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.big);
    return data.buffer.asUint8List();
  }

  static int _readUint32(List<int> bytes) =>
      ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0, Endian.big);

  static Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
    final bytes = await file.read(length);
    if (bytes.length != length) {
      throw const FormatException('加密備份不完整');
    }
    return Uint8List.fromList(bytes);
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}

class _EncryptedHeader {
  const _EncryptedHeader({
    required this.iterations,
    required this.chunkSize,
    required this.salt,
    required this.noncePrefix,
  });

  final int iterations;
  final int chunkSize;
  final List<int> salt;
  final List<int> noncePrefix;
}
