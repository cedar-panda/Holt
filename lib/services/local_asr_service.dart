import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// App-local streaming Chinese ASR.
///
/// The small Zipformer model is shipped as app assets. It is copied to the
/// app support directory once because sherpa-onnx needs real file paths for
/// its native ONNX runtime. No microphone audio is sent over the network.
class LocalAsrService {
  LocalAsrService._();

  static final LocalAsrService instance = LocalAsrService._();

  static const _sampleRate = 16000;
  static const _assetRoot = 'assets/asr_zh';
  static const _modelFiles = <String>[
    'encoder-epoch-99-avg-1.int8.onnx',
    'decoder-epoch-99-avg-1.onnx',
    'joiner-epoch-99-avg-1.int8.onnx',
    'tokens.txt',
  ];

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamController<String>? _resultController;
  Future<void>? _startFuture;
  String _committedText = '';
  String _activeText = '';
  bool _initialized = false;

  bool get isInitialized => _initialized;
  bool get isListening => _resultController != null;

  Future<bool> initialize({void Function(int percent)? onProgress}) async {
    if (_initialized) return true;
    try {
      onProgress?.call(5);
      sherpa.initBindings();
      final root = await getApplicationSupportDirectory();
      final modelDir = Directory('${root.path}/asr_zh');
      await modelDir.create(recursive: true);

      for (var i = 0; i < _modelFiles.length; i++) {
        final name = _modelFiles[i];
        final target = File('${modelDir.path}/$name');
        if (!await target.exists() || await target.length() == 0) {
          final data = await rootBundle.load('$_assetRoot/$name');
          await target.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
        }
        onProgress?.call(10 + (((i + 1) / _modelFiles.length) * 50).round());
      }

      final model = sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '${modelDir.path}/${_modelFiles[0]}',
          decoder: '${modelDir.path}/${_modelFiles[1]}',
          joiner: '${modelDir.path}/${_modelFiles[2]}',
        ),
        tokens: '${modelDir.path}/${_modelFiles[3]}',
        numThreads: 2,
        provider: 'cpu',
        debug: false,
        // This 2023 model is the original Zipformer transducer. Leaving the
        // type empty lets sherpa-onnx select the compatible implementation.
        modelType: '',
      );
      _recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(
          model: model,
          feat: const sherpa.FeatureConfig(sampleRate: _sampleRate),
          enableEndpoint: true,
          rule1MinTrailingSilence: 2.4,
          rule2MinTrailingSilence: 1.2,
        ),
      );
      _initialized = true;
      onProgress?.call(100);
      return true;
    } catch (_) {
      _recognizer?.free();
      _recognizer = null;
      return false;
    }
  }

  Future<Stream<String>> startRecognition() async {
    if (!_initialized || _recognizer == null) {
      throw StateError('Local ASR is not initialized');
    }
    if (_resultController != null) {
      await stopRecognition();
    }
    _resultController = StreamController<String>();
    _committedText = '';
    _activeText = '';
    _stream = _recognizer!.createStream();
    _recorder = AudioRecorder();
    _startFuture = _startRecorder();
    await _startFuture;
    return _resultController!.stream;
  }

  Future<void> _startRecorder() async {
    final recorder = _recorder!;
    if (!await recorder.hasPermission()) {
      throw StateError('Microphone permission is unavailable');
    }
    final audio = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 3200,
      ),
    );
    _audioSubscription = audio.listen(
      _acceptPcm16,
      onError: (Object error, StackTrace stack) {
        _resultController?.addError(error, stack);
      },
    );
  }

  void _acceptPcm16(Uint8List bytes) {
    final stream = _stream;
    final recognizer = _recognizer;
    if (stream == null || recognizer == null || bytes.length < 2) return;
    final samples = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      var value = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
      if (value >= 0x8000) value -= 0x10000;
      samples[i] = value / 32768.0;
    }
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    _publishCurrentResult();
  }

  void _publishCurrentResult() {
    final stream = _stream;
    final recognizer = _recognizer;
    if (stream == null || recognizer == null) return;
    final text = recognizer.getResult(stream).text.trim();
    if (recognizer.isEndpoint(stream)) {
      if (text.isNotEmpty) _committedText = _join(_committedText, text);
      _activeText = '';
      recognizer.reset(stream);
    } else {
      _activeText = text;
    }
    final full = _join(_committedText, _activeText);
    if (full.isNotEmpty) _resultController?.add(full);
  }

  String _join(String left, String right) {
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    final needsSpace =
        RegExp(r'[A-Za-z0-9]$').hasMatch(left) &&
        RegExp(r'^[A-Za-z0-9]').hasMatch(right);
    return needsSpace ? '$left $right' : '$left$right';
  }

  Future<void> stopRecognition() async {
    final controller = _resultController;
    if (controller == null) return;
    try {
      await _startFuture;
    } catch (_) {
      // The stream is still closed below so the UI can leave listening state.
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _recorder?.stop();
    _recorder?.dispose();
    _recorder = null;

    final stream = _stream;
    final recognizer = _recognizer;
    if (stream != null && recognizer != null) {
      stream.inputFinished();
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final remaining = recognizer.getResult(stream).text.trim();
      if (remaining.isNotEmpty) {
        _activeText = remaining;
      }
      final full = _join(_committedText, _activeText);
      if (full.isNotEmpty) controller.add(full);
      stream.free();
    }
    _stream = null;
    _resultController = null;
    await controller.close();
  }

  Future<void> cancelRecognition() async {
    final controller = _resultController;
    if (controller == null) return;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _recorder?.cancel();
    _recorder?.dispose();
    _recorder = null;
    _stream?.free();
    _stream = null;
    _resultController = null;
    await controller.close();
  }

  Future<void> dispose() async {
    await cancelRecognition();
    _recognizer?.free();
    _recognizer = null;
    _initialized = false;
  }
}
