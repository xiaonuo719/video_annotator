import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const VideoAnnotatorApp());
}

// ==================== Domain ====================

class ClipSegment {
  final String id;
  final int startMs;
  final int endMs;
  final String type; // "接管" or "亮点" or "不足"
  final int index;
  final String? remark;
  final DateTime wallClockTime;
  final String? audioPath;

  ClipSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.type,
    required this.index,
    this.remark,
    required this.wallClockTime,
    this.audioPath,
  });

  ClipSegment copyWith({
    String? id,
    int? startMs,
    int? endMs,
    String? type,
    int? index,
    String? remark,
    DateTime? wallClockTime,
    String? audioPath,
  }) {
    return ClipSegment(
      id: id ?? this.id,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      type: type ?? this.type,
      index: index ?? this.index,
      remark: remark ?? this.remark,
      wallClockTime: wallClockTime ?? this.wallClockTime,
      audioPath: audioPath ?? this.audioPath,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startMs': startMs,
      'endMs': endMs,
      'type': type,
      'index': index,
      'remark': remark,
      'wallClockTime': wallClockTime.toIso8601String(),
      'audioPath': audioPath,
    };
  }

  factory ClipSegment.fromJson(Map<String, dynamic> json) {
    return ClipSegment(
      id: json['id'] as String,
      startMs: json['startMs'] as int,
      endMs: json['endMs'] as int,
      type: json['type'] as String,
      index: json['index'] as int,
      remark: json['remark'] as String?,
      wallClockTime: DateTime.parse(json['wallClockTime'] as String),
      audioPath: json['audioPath'] as String?,
    );
  }

  String toTxtLine() {
    final remarkPart = remark != null && remark!.isNotEmpty ? ' — $remark' : '';
    return '${_msToTime(startMs)},${_msToTime(endMs)},$type #$index$remarkPart';
  }

  String get timeRange => '${_msToTime(startMs)} → ${_msToTime(endMs)}';

  String get startTimeStr => _msToTime(startMs);

  String get durationStr {
    final sec = (endMs - startMs) ~/ 1000;
    return '${sec}s';
  }

  static String _msToTime(int ms) {
    final totalSeconds = ms ~/ 1000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}

class Project {
  final int version = 1;
  final String name;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ClipSegment> clips;

  Project({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    List<ClipSegment>? clips,
  }) : clips = clips ?? [];

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'clips': clips.map((c) => c.toJson()).toList(),
    };
  }

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      clips: (json['clips'] as List<dynamic>)
          .map((c) => ClipSegment.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ==================== Project Service ====================

class ProjectService {
  static const _uuid = Uuid();

  static Future<String> get _projectDir async {
    Directory? baseDir;

    if (Platform.isAndroid) {
      // Prefer external storage so data is visible in file managers and
      // survives app updates. On Android 4.4+ no runtime permission is
      // required to access the app-specific external directory.
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          baseDir = extDir;
        }
      } catch (e) {
        debugPrint('Failed to get external storage directory: $e');
      }
    }

    // Fall back to internal app documents directory when external storage is
    // unavailable (e.g. removable media not mounted) or on non-Android platforms.
    baseDir ??= await getApplicationDocumentsDirectory();

    final projectDir = Directory('${baseDir.path}/video_annotator_projects');

    debugPrint('Project directory path: ${projectDir.path}');

    if (!await projectDir.exists()) {
      debugPrint('Creating project directory...');
      await projectDir.create(recursive: true);
      debugPrint('Project directory created.');
    }
    return projectDir.path;
  }

  static Future<String> generateProjectPath() async {
    final dir = await _projectDir;
    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return '$dir/$timestamp.va';
  }

  static Future<String> getRecordingsDir(String projectPath) async {
    final dir = Directory('${_getProjectPath(projectPath)}/recordings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  static String _getProjectPath(String projectPath) {
    return projectPath.replaceAll(RegExp(r'[/\\][^/\\]+$'), '');
  }

  static Future<void> saveProject(Project project, String projectPath) async {
    final file = File(projectPath);
    await file.writeAsString(jsonEncode(project.toJson()), flush: true);
  }

  static Future<Project?> loadProject(String projectPath) async {
    try {
      final file = File(projectPath);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return Project.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  static Future<List<String>> listProjects() async {
    final dir = await _projectDir;
    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final files = await directory.list().toList();
    return files
        .whereType<File>()
        .where((f) => f.path.endsWith('.va'))
        .map((f) => f.path)
        .toList()
      ..sort((a, b) => b.compareTo(a)); // newest first
  }

  static Future<void> deleteProject(String projectPath) async {
    final file = File(projectPath);
    if (await file.exists()) {
      await file.delete();
    }
    // Delete recordings directory
    final recordingsDir = Directory(
      '${_getProjectPath(projectPath)}/recordings',
    );
    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
    }
  }

  static String generateClipId() => _uuid.v4();
}

// ==================== Whisper Models ====================

enum WhisperModelSize { tiny, base, small, medium }

extension WhisperModelSizeExt on WhisperModelSize {
  String get displayName {
    switch (this) {
      case WhisperModelSize.tiny:
        return 'Tiny (~39MB)';
      case WhisperModelSize.base:
        return 'Base (~140MB)';
      case WhisperModelSize.small:
        return 'Small (~466MB)';
      case WhisperModelSize.medium:
        return 'Medium (~1.5GB)';
    }
  }

  String get fileName {
    switch (this) {
      case WhisperModelSize.tiny:
        return 'ggml-tiny.bin';
      case WhisperModelSize.base:
        return 'ggml-base.bin';
      case WhisperModelSize.small:
        return 'ggml-small.bin';
      case WhisperModelSize.medium:
        return 'ggml-medium.bin';
    }
  }

  WhisperModel get toWhisperModel {
    switch (this) {
      case WhisperModelSize.tiny:
        return WhisperModel.tiny;
      case WhisperModelSize.base:
        return WhisperModel.base;
      case WhisperModelSize.small:
        return WhisperModel.small;
      case WhisperModelSize.medium:
        return WhisperModel.medium;
    }
  }
}

// ==================== Whisper Service ====================

class WhisperService {
  static const _downloadHost =
      'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main';

  static Future<String> get _modelDir async {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  static Future<bool> isModelDownloaded(WhisperModelSize size) async {
    final dir = await _modelDir;
    final file = File('$dir/${size.fileName}');
    return file.existsSync();
  }

  static Future<bool> downloadModel(
    WhisperModelSize size, {
    void Function(double progress)? onProgress,
    void Function(String error)? onError,
  }) async {
    final dir = await _modelDir;
    final file = File('$dir/${size.fileName}');

    if (file.existsSync()) return true;

    try {
      final uri = Uri.parse('$_downloadHost/${size.fileName}');
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        onError?.call('下载失败: HTTP ${response.statusCode}');
        return false;
      }

      final contentLength = response.contentLength;
      int received = 0;

      final raf = file.openSync(mode: FileMode.write);
      await for (var chunk in response) {
        raf.writeFromSync(chunk);
        received += chunk.length;
        if (contentLength > 0 && onProgress != null) {
          onProgress(received / contentLength);
        }
      }
      await raf.close();
      return true;
    } catch (e) {
      if (file.existsSync()) {
        file.deleteSync();
      }
      onError?.call('下载失败: $e');
      return false;
    }
  }

  static Future<void> deleteModel(WhisperModelSize size) async {
    final dir = await _modelDir;
    final file = File('$dir/${size.fileName}');
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  static Future<String?> transcribe(
    String audioPath,
    WhisperModelSize size, {
    String? apiKey,
    String? apiEndpoint,
  }) async {
    final normalizedApiKey = apiKey?.trim();
    final normalizedApiEndpoint = apiEndpoint?.trim();

    // If API mode is configured, use API
    if (normalizedApiKey != null &&
        normalizedApiKey.isNotEmpty &&
        normalizedApiEndpoint != null &&
        normalizedApiEndpoint.isNotEmpty) {
      return _transcribeViaApi(
        audioPath,
        normalizedApiKey,
        normalizedApiEndpoint,
      );
    }

    // Otherwise use local model
    return _transcribeLocal(audioPath, size);
  }

  static Future<String?> _transcribeLocal(
    String audioPath,
    WhisperModelSize size,
  ) async {
    final dir = await _modelDir;
    final modelFile = File('$dir/${size.fileName}');

    // Check if model exists
    if (!modelFile.existsSync()) {
      return null;
    }

    // Check if audio file exists
    final audioFile = File(audioPath);
    if (!audioFile.existsSync()) {
      return null;
    }

    final whisper = Whisper(
      model: size.toWhisperModel,
      modelDir: dir,
      downloadHost: _downloadHost,
    );

    try {
      final result = await whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioPath,
          language: 'zh',
          isNoTimestamps: true,
        ),
      );
      return result.text.trim();
    } catch (e) {
      return null;
    }
  }

  static Future<String?> _transcribeViaApi(
    String audioPath,
    String apiKey,
    String apiEndpoint,
  ) async {
    try {
      final file = File(audioPath);
      if (!file.existsSync()) {
        return null;
      }

      final uri = Uri.parse(apiEndpoint);
      final request = await HttpClient().postUrl(uri);
      final boundary =
          'video_annotator_${DateTime.now().microsecondsSinceEpoch}';
      final filename = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'audio.wav';

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');

      void writeField(String name, String value) {
        request.write('--$boundary\r\n');
        request.write(
          'Content-Disposition: form-data; name="$name"\r\n\r\n',
        );
        request.write(value);
        request.write('\r\n');
      }

      writeField('model', 'whisper-1');
      writeField('language', 'zh');
      request.write('--$boundary\r\n');
      request.write(
        'Content-Disposition: form-data; name="file"; filename="$filename"\r\n',
      );
      request.write('Content-Type: audio/wav\r\n\r\n');
      await request.addStream(file.openRead());
      request.write('\r\n--$boundary--\r\n');

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody) as Map<String, dynamic>;
        return json['text'] as String?;
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
}

// ==================== State ====================

// MethodChannel for volume button events from native Android
const _volumeChannel = MethodChannel('video_annotator/volume_buttons');

// SharedPreferences keys
const _prefWindowSeconds = 'window_seconds';
const _prefModelSize = 'model_size';
const _prefUseApiMode = 'use_api_mode';
const _prefApiKey = 'api_key';
const _prefApiEndpoint = 'api_endpoint';

class AppState extends ChangeNotifier {
  bool _isRunning = false;
  int _elapsedMs = 0;
  int _highlightCount = 0;
  int _issueCount = 0;
  int _windowSeconds = 30;
  final List<ClipSegment> _clips = [];
  Timer? _timer;

  // Recording state
  bool _isRecording = false;
  int _recordingSecondsLeft = 10;
  String? _recordingType; // '接管' or '亮点' or '不足'
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordingPath;
  String? _recordingId;
  int _recordingStartMs = 0; // Save elapsed when recording starts

  // Model state
  WhisperModelSize _selectedModelSize = WhisperModelSize.base;
  bool _isModelDownloaded = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;

  // API mode
  bool _useApiMode = false;
  String? _apiKey;
  String? _apiEndpoint;

  // Project state
  String? _currentProjectPath;
  DateTime? _projectCreatedAt;
  bool _isDirty = false;

  // Transcription state
  String? _transcribingClipId;

  // Navigation state
  int _selectedIndex = 0;

  // Getters
  bool get isRunning => _isRunning;
  int get elapsedMs => _elapsedMs;
  int get windowSeconds => _windowSeconds;
  List<ClipSegment> get clips => List.unmodifiable(_clips);
  bool get isRecording => _isRecording;
  int get recordingSecondsLeft => _recordingSecondsLeft;
  String? get recordingType => _recordingType;
  bool get isModelDownloaded => _isModelDownloaded;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get currentProjectPath => _currentProjectPath;
  bool get isDirty => _isDirty;
  int get selectedIndex => _selectedIndex;
  WhisperModelSize get selectedModelSize => _selectedModelSize;
  bool get useApiMode => _useApiMode;
  String? get apiKey => _apiKey;
  String? get apiEndpoint => _apiEndpoint;
  bool get isApiConfigured =>
      _useApiMode &&
      (_apiKey?.trim().isNotEmpty ?? false) &&
      (_apiEndpoint?.trim().isNotEmpty ?? false);
  bool get isModelAvailable => _isModelDownloaded || isApiConfigured;
  String? get transcribingClipId => _transcribingClipId;

  String get formattedTime {
    final totalSeconds = _elapsedMs ~/ 1000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  String get projectName {
    if (_currentProjectPath == null) return '未命名项目';
    final name = _currentProjectPath!.split('/').last.replaceAll('.va', '');
    return name;
  }

  void setSelectedIndex(int index) {
    _selectedIndex = index;
    notifyListeners();
  }

  Future<void> checkModelStatus() async {
    _isModelDownloaded = await WhisperService.isModelDownloaded(_selectedModelSize);
    await ensureStoragePermission();
    notifyListeners();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _windowSeconds = prefs.getInt(_prefWindowSeconds) ?? 30;
    final modelIndex = prefs.getInt(_prefModelSize) ?? WhisperModelSize.base.index;
    _selectedModelSize = WhisperModelSize.values[modelIndex.clamp(0, WhisperModelSize.values.length - 1)];
    _useApiMode = prefs.getBool(_prefUseApiMode) ?? false;
    _apiKey = prefs.getString(_prefApiKey);
    _apiEndpoint = prefs.getString(_prefApiEndpoint);
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefWindowSeconds, _windowSeconds);
    await prefs.setInt(_prefModelSize, _selectedModelSize.index);
    await prefs.setBool(_prefUseApiMode, _useApiMode);
    if (_apiKey != null) {
      await prefs.setString(_prefApiKey, _apiKey!);
    } else {
      await prefs.remove(_prefApiKey);
    }
    if (_apiEndpoint != null) {
      await prefs.setString(_prefApiEndpoint, _apiEndpoint!);
    } else {
      await prefs.remove(_prefApiEndpoint);
    }
  }

  void setupVolumeButtons() {
    _volumeChannel.setMethodCallHandler((call) async {
      // Ignore volume events when the session is not active or a recording is
      // already in progress to prevent accidental duplicate marks.
      if (!_isRunning || _isRecording) return;
      switch (call.method) {
        case 'volumeUp':
          onMarkButtonPressed('亮点');
          break;
        case 'volumeDown':
          onMarkButtonPressed('不足');
          break;
      }
    });
  }

  Future<void> downloadModel() async {
    if (_isDownloading || _isModelDownloaded) return;
    _isDownloading = true;
    _downloadProgress = 0;
    notifyListeners();

    try {
      final downloaded = await WhisperService.downloadModel(
        _selectedModelSize,
        onProgress: (p) {
          _downloadProgress = p;
          notifyListeners();
        },
      );
      _isModelDownloaded =
          downloaded &&
          await WhisperService.isModelDownloaded(_selectedModelSize);
    } catch (e) {
      // Download failed silently
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> deleteModel() async {
    await WhisperService.deleteModel(_selectedModelSize);
    _isModelDownloaded = false;
    notifyListeners();
  }

  void setSelectedModelSize(WhisperModelSize size) {
    if (_selectedModelSize == size) return;
    _selectedModelSize = size;
    _saveSettings();
    checkModelStatus();
  }

  void setUseApiMode(bool value) {
    _useApiMode = value;
    _saveSettings();
    notifyListeners();
  }

  void setApiKey(String? value) {
    _apiKey = value?.trim();
    _saveSettings();
    notifyListeners();
  }

  void setApiEndpoint(String? value) {
    _apiEndpoint = value?.trim();
    _saveSettings();
    notifyListeners();
  }

  void setWindowSeconds(int seconds) {
    _windowSeconds = seconds.clamp(5, 120);
    _saveSettings();
    notifyListeners();
  }

  Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // App-specific external storage (getExternalStorageDirectory) does not
    // require any runtime permission on Android 4.4+ (API 19+).
    // However, MANAGE_EXTERNAL_STORAGE is declared in the manifest for
    // Android 11+ devices where broader access may be needed. Request it
    // so the user is prompted once.
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;

    // On Android ≤ 12 (API 32), the legacy WRITE_EXTERNAL_STORAGE is still
    // useful for accessing shared storage. permission_handler v12 returns
    // `granted` automatically on Android 13+ where this permission no longer
    // exists.
    final storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;

    // Request legacy storage first (shows a normal dialog on Android ≤ 12).
    final storageResult = await Permission.storage.request();
    if (storageResult.isGranted) return true;

    // Request MANAGE_EXTERNAL_STORAGE – on Android 11+ this opens the
    // system Settings screen; the user must toggle the switch there.
    final manageResult = await Permission.manageExternalStorage.request();
    return manageResult.isGranted;
  }

  Future<void> ensureStoragePermission() async {
    if (!Platform.isAndroid) return;

    // Request permissions sequentially so the user sees one dialog at a time.
    await requestStoragePermission();

    final manageStatus = await Permission.manageExternalStorage.status;
    final storageStatus = await Permission.storage.status;

    debugPrint(
      'Storage permission status: manageExternalStorage=$manageStatus, storage=$storageStatus',
    );
  }

  void start() async {
    if (_isRunning) return;

    // Auto-create project if none exists
    if (_currentProjectPath == null) {
      await newProject();
    }

    _isRunning = true;
    WakelockPlus.enable();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _elapsedMs += 100;
      notifyListeners();
    });
    notifyListeners();
  }

  void stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    WakelockPlus.disable();
    _timer?.cancel();
    _timer = null;

    // Auto-save project when stopping
    if (_currentProjectPath != null && _clips.isNotEmpty) {
      await _autoSaveProject();
    }

    notifyListeners();
  }

  void toggle() {
    if (_isRunning) {
      stop();
    } else {
      start();
    }
  }

  void onMarkButtonPressed(String type) async {
    if (_isRecording) return;

    _recordingType = type;
    _recordingSecondsLeft = 10;
    _recordingId = ProjectService.generateClipId();
    _recordingStartMs = _elapsedMs; // Save elapsed at button press

    // Check if we can do recording + transcription
    final canRecord = _isModelDownloaded || isApiConfigured;

    if (!canRecord) {
      // No-model mode: add clip immediately without audio
      _addClipImmediate(type);
      return;
    }

    // Request microphone permission
    final hasPermission = await requestMicrophonePermission();
    if (!hasPermission) {
      // Permission denied, fall back to no-model mode
      _recordingId = null;
      _addClipImmediate(type);
      return;
    }

    _isRecording = true;
    notifyListeners();

    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _recordingPath!,
      );
    } catch (e) {
      // Recording failed, fall back to no-model mode
      _isRecording = false;
      _recordingId = null;
      notifyListeners();
      _addClipImmediate(type);
      return;
    }

    Timer.periodic(const Duration(seconds: 1), (t) {
      _recordingSecondsLeft--;
      notifyListeners();
      if (_recordingSecondsLeft <= 0) {
        t.cancel();
        _stopRecordingAndTranscribe();
      }
    });
  }

  void _addClipImmediate(String type) {
    if (_recordingId == null) return;
    final clipId = _recordingId!;
    final wallClock = DateTime.now();
    final elapsed = _recordingStartMs;

    if (type == '亮点') {
      _highlightCount++;
    } else if (type == '不足') {
      _issueCount++;
    }

    final start = (elapsed - _windowSeconds * 1000).clamp(0, elapsed);
    final end = elapsed + _windowSeconds * 1000;

    final clip = ClipSegment(
      id: clipId,
      startMs: start,
      endMs: end,
      type: type,
      index: type == '亮点' ? _highlightCount : _issueCount,
      wallClockTime: wallClock,
      audioPath: null,
    );
    _clips.add(clip);
    _isDirty = true;
    _recordingId = null;
    notifyListeners();

    // Auto-save if project is open
    if (_currentProjectPath != null) {
      _autoSaveProject();
    }
  }

  void cancelRecording() {
    if (!_isRecording) return;
    _recorder.cancel();
    _isRecording = false;
    _recordingType = null;
    _recordingSecondsLeft = 10;
    _recordingId = null;
    notifyListeners();
  }

  void _stopRecordingAndTranscribe() async {
    if (!_isRecording || _recordingPath == null || _recordingId == null) return;

    final path = _recordingPath!;
    final type = _recordingType!;
    final elapsed = _recordingStartMs; // Use saved elapsed at recording start
    final clipId = _recordingId!;
    final wallClock = DateTime.now();

    _isRecording = false;
    _recordingType = null;
    _recordingSecondsLeft = 10;
    _recordingId = null;
    notifyListeners();

    await _recorder.stop();

    // Copy audio to project directory if project is open
    String? audioPath;
    if (_currentProjectPath != null) {
      try {
        final recordingsDir = await ProjectService.getRecordingsDir(
          _currentProjectPath!,
        );
        audioPath = '$recordingsDir/$clipId.wav';
        await File(path).copy(audioPath);
        // Delete temp file
        await File(path).delete();
      } catch (e) {
        audioPath = null;
      }
    }

    final start = (elapsed - _windowSeconds * 1000).clamp(0, elapsed);
    final end = elapsed + _windowSeconds * 1000;

    if (type == '亮点') {
      _highlightCount++;
    } else if (type == '不足') {
      _issueCount++;
    }

    final clip = ClipSegment(
      id: clipId,
      startMs: start,
      endMs: end,
      type: type,
      index: type == '亮点' ? _highlightCount : _issueCount,
      wallClockTime: wallClock,
      audioPath: audioPath,
    );
    _clips.add(clip);
    _isDirty = true;
    notifyListeners();

    // Transcribe in background (use original temp path if not copied)
    _transcribingClipId = clipId;
    notifyListeners();

    final transcribePath = audioPath ?? path;
    final remark = await WhisperService.transcribe(
      transcribePath,
      _selectedModelSize,
      apiKey: _useApiMode ? _apiKey : null,
      apiEndpoint: _useApiMode ? _apiEndpoint : null,
    );

    _transcribingClipId = null;

    final idx = _clips.indexWhere((c) => c.id == clipId);
    if (idx != -1) {
      _clips[idx] = _clips[idx].copyWith(remark: remark);
      _isDirty = true;
      notifyListeners();
    }

    // Auto-save if project is open
    if (_currentProjectPath != null) {
      await _autoSaveProject();
    }
  }

  Future<void> _autoSaveProject() async {
    if (_currentProjectPath == null) return;
    final project = Project(
      name: projectName,
      createdAt: _projectCreatedAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      clips: _clips,
    );
    await ProjectService.saveProject(project, _currentProjectPath!);
    _isDirty = false;
    notifyListeners();
  }

  void removeClip(ClipSegment clip) {
    _clips.remove(clip);
    _isDirty = true;
    notifyListeners();
  }

  void reset() {
    stop();
    _elapsedMs = 0;
    _highlightCount = 0;
    _issueCount = 0;
    _clips.clear();
    _isDirty = true;
    notifyListeners();
  }

  String generateTxt() {
    final sorted = List<ClipSegment>.from(_clips)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    return sorted.map((c) => c.toTxtLine()).join('\n');
  }

  // Project management
  Future<void> newProject() async {
    final projectPath = await ProjectService.generateProjectPath();
    _currentProjectPath = projectPath;
    _projectCreatedAt = DateTime.now();
    _isDirty = false;
    reset();
    notifyListeners();
  }

  Future<void> loadProject(String projectPath) async {
    final project = await ProjectService.loadProject(projectPath);
    if (project == null) return;

    _currentProjectPath = projectPath;
    _projectCreatedAt = project.createdAt;
    _clips.clear();
    _clips.addAll(project.clips);

    // Restore counts
    _highlightCount = _clips.where((c) => c.type == '亮点').length;
    _issueCount = _clips.where((c) => c.type == '不足').length;

    // Estimate elapsed time from last clip
    if (_clips.isNotEmpty) {
      _elapsedMs = _clips.map((c) => c.endMs).reduce((a, b) => a > b ? a : b);
    } else {
      _elapsedMs = 0;
    }

    _isDirty = false;
    notifyListeners();
  }

  Future<void> saveProject() async {
    if (_currentProjectPath == null) {
      await newProject();
    }
    await _autoSaveProject();
  }

  Future<void> deleteCurrentProject() async {
    if (_currentProjectPath != null) {
      await ProjectService.deleteProject(_currentProjectPath!);
      _currentProjectPath = null;
      _projectCreatedAt = null;
      reset();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}

// ==================== App ====================

class VideoAnnotatorApp extends StatelessWidget {
  const VideoAnnotatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState();
        state.loadSettings().then((_) => state.checkModelStatus());
        state.setupVolumeButtons();
        return state;
      },
      child: MaterialApp(
        title: '视频标注工具',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1976D2),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1976D2),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const MainScreen(),
      ),
    );
  }
}

// ==================== Main Screen with Navigation ====================

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 800;

        if (isWide) {
          // Wide screen: NavigationRail on the left
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: state.selectedIndex,
                  onDestinationSelected: state.setSelectedIndex,
                  labelType: NavigationRailLabelType.all,
                  leading: const SizedBox(height: 8),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('主页'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder),
                      label: Text('项目'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: Text('设置'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildContent(state.selectedIndex)),
              ],
            ),
          );
        } else {
          // Narrow screen: BottomNavigationBar
          return Scaffold(
            body: _buildContent(state.selectedIndex),
            bottomNavigationBar: NavigationBar(
              selectedIndex: state.selectedIndex,
              onDestinationSelected: state.setSelectedIndex,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '主页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '项目',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
          );
        }
      },
    );
  }

  Widget _buildContent(int index) {
    switch (index) {
      case 0:
        return const _HomePage();
      case 1:
        return const _ProjectsPage();
      case 2:
        return const _SettingsPage();
      default:
        return const _HomePage();
    }
  }
}

// ==================== Home Page ====================

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ProjectHeader(),
            _ProjectActionsRow(),
            const Divider(height: 1),
            Expanded(child: _ClipListSection()),
            _MarkButtonsRow(),
          ],
        ),
      ),
    );
  }
}

// ==================== Project Header ====================

class _ProjectHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project name row
          Row(
            children: [
              Expanded(
                child: Text(
                  state.projectName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (state.isDirty)
                const Text('*', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          // Timer and controls row
          Row(
            children: [
              IconButton(
                onPressed: () => state.toggle(),
                icon: Icon(
                  state.isRunning ? Icons.stop : Icons.play_arrow,
                  color: state.isRunning ? Colors.red : Colors.green,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: (state.isRunning ? Colors.red : Colors.green)
                      .withAlpha(26),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                state.formattedTime,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w300,
                  fontFamily: 'monospace',
                  color: state.isRunning
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${state.clips.length} 个片段',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==================== Project Actions Row ====================

class _ProjectActionsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                state.newProject();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已创建新项目')),
                );
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: state.clips.isNotEmpty
                  ? () {
                      state.saveProject();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已保存: ${state.projectName}')),
                      );
                    }
                  : null,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: state.currentProjectPath != null
                  ? () => _confirmDeleteProject(context, state)
                  : null,
              icon: Icon(Icons.delete, size: 18, color: Colors.red.shade400),
              label: Text('删除',
                  style: TextStyle(color: Colors.red.shade400)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteProject(BuildContext context, AppState state) async {
    final name = state.projectName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除项目 "$name" 吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await state.deleteCurrentProject();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除: $name')),
        );
      }
    }
  }
}

// ==================== Projects Page ====================

class _ProjectsPage extends StatefulWidget {
  const _ProjectsPage();

  @override
  State<_ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<_ProjectsPage> {
  List<String> _projects = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);
    final projects = await ProjectService.listProjects();
    setState(() {
      _projects = projects;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadProjects,
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _projects.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.folder_open,
                      size: 64,
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '暂无项目',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '在主页标记片段后自动创建项目',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withAlpha(
                          150,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _projects.length,
                itemBuilder: (ctx, i) {
                  final path = _projects[i];
                  final name = path.split('/').last.replaceAll('.va', '');
                  final isCurrentProject = state.currentProjectPath == path;

                  return Card(
                    color: isCurrentProject
                        ? theme.colorScheme.primaryContainer
                        : null,
                    child: ListTile(
                      leading: Icon(
                        Icons.video_file,
                        color: isCurrentProject
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontWeight: isCurrentProject
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrentProject)
                            Chip(
                              label: const Text('当前'),
                              labelStyle: TextStyle(
                                fontSize: 10,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                              backgroundColor: theme.colorScheme.primary,
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _confirmDelete(context, path),
                            tooltip: '删除',
                          ),
                        ],
                      ),
                      onTap: () async {
                        final project = await ProjectService.loadProject(path);
                        if (project != null && context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _ProjectViewerPage(
                                projectPath: path,
                                project: project,
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String path) async {
    final name = path.split('/').last.replaceAll('.va', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除项目 "$name" 吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await ProjectService.deleteProject(path);
      _loadProjects();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除: $name')));
      }
    }
  }
}

// ==================== Mode Chip ====================

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withAlpha(77),
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ==================== Settings Page ====================

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  TextEditingController _apiKeyController = TextEditingController();
  TextEditingController _apiEndpointController = TextEditingController();

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final state = Provider.of<AppState>(context, listen: false);
      _apiKeyController = TextEditingController(text: state.apiKey ?? '');
      _apiEndpointController = TextEditingController(text: state.apiEndpoint ?? '');
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiEndpointController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Project management section
            Text(
              '项目管理',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('新建项目'),
                    subtitle: const Text('创建空白项目'),
                    onTap: () {
                      state.newProject();
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已创建新项目')));
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.save),
                    title: const Text('保存项目'),
                    subtitle: const Text('保存当前项目'),
                    enabled: state.clips.isNotEmpty,
                    onTap: () {
                      state.saveProject();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已保存: ${state.projectName}')),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_forever,
                      color: Colors.red,
                    ),
                    title: const Text(
                      '删除当前项目',
                      style: TextStyle(color: Colors.red),
                    ),
                    subtitle: const Text('删除项目文件和相关录音'),
                    enabled: state.currentProjectPath != null,
                    onTap: () => _confirmDeleteProject(context, state),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Model and API section
            Text(
              '语音转文字',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Mode selection
                    Row(
                      children: [
                        Expanded(
                          child: _ModeChip(
                            label: '本地模型',
                            selected: !state.useApiMode,
                            onTap: () => state.setUseApiMode(false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ModeChip(
                            label: 'API 模式',
                            selected: state.useApiMode,
                            onTap: () => state.setUseApiMode(true),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    if (!state.useApiMode) ...[
                      // Model size selection
                      Text('模型大小', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      DropdownButton<WhisperModelSize>(
                        value: state.selectedModelSize,
                        isExpanded: true,
                        items: WhisperModelSize.values.map((size) {
                          return DropdownMenuItem(
                            value: size,
                            child: Text(size.displayName),
                          );
                        }).toList(),
                        onChanged: (size) {
                          if (size != null) {
                            state.setSelectedModelSize(size);
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      // Model status / download
                      state.isModelDownloaded
                          ? Row(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '已下载 ${state.selectedModelSize.displayName}',
                                    style: const TextStyle(color: Colors.green),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    await state.deleteModel();
                                  },
                                  child: const Text(
                                    '删除',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            )
                          : state.isDownloading
                          ? Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: state.downloadProgress,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${(state.downloadProgress * 100).toInt()}%',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            )
                          : SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () => state.downloadModel(),
                                icon: const Icon(Icons.download),
                                label: const Text('下载模型'),
                              ),
                            ),
                    ] else ...[
                      // API configuration
                      TextField(
                        controller: _apiKeyController,
                        decoration: const InputDecoration(
                          labelText: 'API Key',
                          hintText: 'sk-...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => state.setApiKey(v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _apiEndpointController,
                        decoration: const InputDecoration(
                          labelText: 'API Endpoint',
                          hintText: 'https://api.openai.com/v1/audio/transcriptions',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => state.setApiEndpoint(v),
                      ),
                    ],

                    const SizedBox(height: 12),
                    // No-model mode hint
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withAlpha(77),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              state.isModelDownloaded || state.isApiConfigured
                                  ? '支持录音标注'
                                  : state.useApiMode
                                  ? '请先填写有效的 API Key 和 Endpoint'
                                  : '无模型/无API，仅标记时间点',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Time window section
            Text(
              '时间窗口',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      '前后 ${state.windowSeconds} 秒（共 ${state.windowSeconds * 2} 秒）',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Slider(
                      value: state.windowSeconds.toDouble(),
                      min: 5,
                      max: 120,
                      divisions: 23,
                      label: '${state.windowSeconds}s',
                      onChanged: (v) {
                        state.setWindowSeconds(v.round());
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // About section
            Text(
              '关于',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('视频标注工具'),
                subtitle: const Text('版本 1.0.0'),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.volume_up,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('音量键快速标记'),
                subtitle: const Text('计时运行时：音量+ → 亮点，音量- → 不足'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteProject(
    BuildContext context,
    AppState state,
  ) async {
    if (state.currentProjectPath == null) return;

    final name = state.projectName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除项目 "$name" 吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await state.deleteCurrentProject();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除: $name')));
      }
    }
  }
}

// ==================== Project Viewer Page (Read-only) ====================

class _ProjectViewerPage extends StatefulWidget {
  final String projectPath;
  final Project project;

  const _ProjectViewerPage({required this.projectPath, required this.project});

  @override
  State<_ProjectViewerPage> createState() => _ProjectViewerPageState();
}

class _ProjectViewerPageState extends State<_ProjectViewerPage> {
  String? _playingClipId;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _playingClipId = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _exportTxt() async {
    final sorted = List<ClipSegment>.from(widget.project.clips)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final content = sorted.map((c) => c.toTxtLine()).join('\n');

    final dir = await getTemporaryDirectory();
    final name = widget.projectPath.split('/').last.replaceAll('.va', '');
    final file = File('${dir.path}/$name.txt');
    await file.writeAsString(content);

    await Share.shareXFiles(
      [XFile(file.path)],
      text: '视频标注导出',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.projectPath.split('/').last.replaceAll('.va', '');

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _exportTxt,
            tooltip: '导出TXT',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Project info header
            Container(
              padding: const EdgeInsets.all(16),
              color: theme.colorScheme.surfaceContainerHighest.withAlpha(77),
              child: Row(
                children: [
                  Icon(
                    Icons.video_file,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '创建: ${_formatDate(widget.project.createdAt)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '片段数: ${widget.project.clips.length}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Clip list
            Expanded(
              child: widget.project.clips.isEmpty
                  ? Center(
                      child: Text(
                        '无片段',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: widget.project.clips.length,
                      itemBuilder: (ctx, i) {
                        final clip = widget.project.clips[i];
                        return _ViewerClipItem(
                          clip: clip,
                          isPlaying: _playingClipId == clip.id,
                          onPlay: clip.audioPath != null
                              ? () => _playAudio(clip)
                              : null,
                          onStop: _playingClipId == clip.id
                              ? () => _stopAudio()
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playAudio(ClipSegment clip) async {
    if (clip.audioPath == null) return;

    // Stop any currently playing audio
    await _audioPlayer.stop();

    try {
      await _audioPlayer.setFilePath(clip.audioPath!);
      await _audioPlayer.play();
      setState(() {
        _playingClipId = clip.id;
      });
    } catch (e) {
      // Playback failed
      setState(() {
        _playingClipId = null;
      });
    }
  }

  void _stopAudio() {
    _audioPlayer.stop();
    setState(() {
      _playingClipId = null;
    });
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _ViewerClipItem extends StatelessWidget {
  final ClipSegment clip;
  final bool isPlaying;
  final VoidCallback? onPlay;
  final VoidCallback? onStop;

  const _ViewerClipItem({
    required this.clip,
    this.isPlaying = false,
    this.onPlay,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHighlight = clip.type == '亮点';
    final isTakeover = clip.type == '接管';
    final bgColor = isTakeover
        ? const Color(0xFFE3F2FD)
        : isHighlight
        ? const Color(0xFFFFE082).withAlpha(51)
        : const Color(0xFFEF9A9A).withAlpha(51);
    final labelColor = isTakeover
        ? const Color(0xFF1976D2)
        : isHighlight
        ? const Color(0xFFFF8F00)
        : const Color(0xFFD32F2F);

    return Card(
      color: bgColor,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 32,
                  decoration: BoxDecoration(
                    color: labelColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Show video timeline start time
                      Text(
                        clip.startTimeStr,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: labelColor.withAlpha(26),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              clip.type,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: labelColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            clip.durationStr,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (clip.audioPath != null)
                            GestureDetector(
                              onTap: isPlaying ? onStop : onPlay,
                              child: Icon(
                                isPlaying ? Icons.stop_circle : Icons.play_circle,
                                size: 20,
                                color: isPlaying
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          else
                            Icon(
                              Icons.mic_off,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant.withAlpha(77),
                            ),
                          const SizedBox(width: 4),
                          Text(
                            _formatTime(clip.wallClockTime),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (clip.remark != null && clip.remark!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.format_quote,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        clip.remark!,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}

// ==================== Mark Buttons Row ====================

class _MarkButtonsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _CompactMarkButton(
              type: '接管',
              color: const Color(0xFF1976D2),
              textColor: Colors.white,
              isRecording: state.isRecording && state.recordingType == '接管',
              recordingSecondsLeft: state.recordingSecondsLeft,
              onTap: () {
                if (!state.isModelAvailable && state.isRecording) {
                  return;
                }
                if (!state.isRecording) {
                  state.onMarkButtonPressed('接管');
                }
              },
              onCancel: () => state.cancelRecording(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _CompactMarkButton(
              type: '亮点',
              color: const Color(0xFFFFA000),
              textColor: Colors.black,
              isRecording: state.isRecording && state.recordingType == '亮点',
              recordingSecondsLeft: state.recordingSecondsLeft,
              onTap: () {
                if (!state.isModelAvailable && state.isRecording) {
                  return;
                }
                if (!state.isRecording) {
                  state.onMarkButtonPressed('亮点');
                }
              },
              onCancel: () => state.cancelRecording(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _CompactMarkButton(
              type: '不足',
              color: const Color(0xFFD32F2F),
              textColor: Colors.white,
              isRecording: state.isRecording && state.recordingType == '不足',
              recordingSecondsLeft: state.recordingSecondsLeft,
              onTap: () {
                if (!state.isModelAvailable && state.isRecording) {
                  return;
                }
                if (!state.isRecording) {
                  state.onMarkButtonPressed('不足');
                }
              },
              onCancel: () => state.cancelRecording(),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== Compact Mark Button ====================

class _CompactMarkButton extends StatefulWidget {
  final String type;
  final Color color;
  final Color textColor;
  final bool isRecording;
  final int recordingSecondsLeft;
  final VoidCallback onTap;
  final VoidCallback onCancel;

  const _CompactMarkButton({
    required this.type,
    required this.color,
    required this.textColor,
    required this.isRecording,
    required this.recordingSecondsLeft,
    required this.onTap,
    required this.onCancel,
  });

  @override
  State<_CompactMarkButton> createState() => _CompactMarkButtonState();
}

class _CompactMarkButtonState extends State<_CompactMarkButton> {
  bool _flash = false;

  void _triggerFlash() {
    setState(() => _flash = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isThisRecording = widget.isRecording;

    return GestureDetector(
      onTap: () {
        if (isThisRecording) {
          widget.onCancel();
        } else {
          _triggerFlash();
          widget.onTap();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 112,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isThisRecording
              ? widget.color.withAlpha(77)
              : _flash
              ? widget.color
              : widget.color.withAlpha(200),
          boxShadow: [
            BoxShadow(
              color: widget.color.withAlpha(_flash ? 150 : 51),
              blurRadius: _flash ? 12 : 4,
            ),
          ],
        ),
        child: Center(
          child: isThisRecording
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: widget.recordingSecondsLeft / 10,
                        color: widget.textColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${widget.recordingSecondsLeft}s',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: widget.textColor,
                      ),
                    ),
                  ],
                )
              : Text(
                  widget.type,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: widget.textColor,
                  ),
                ),
        ),
      ),
    );
  }
}

// ==================== Clip List ====================

class _ClipListSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.clips.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bookmark_border,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: 12),
            Text(
              '还没有标记任何片段',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '点击下方按钮开始标注',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withAlpha(150),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: state.clips.length,
      itemBuilder: (ctx, i) {
        final clip = state.clips[i];
        return _ClipItem(clip: clip, onDelete: () => state.removeClip(clip));
      },
    );
  }
}

class _ClipItem extends StatelessWidget {
  final ClipSegment clip;
  final VoidCallback onDelete;

  const _ClipItem({required this.clip, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHighlight = clip.type == '亮点';
    final isTakeover = clip.type == '接管';
    final bgColor = isTakeover
        ? const Color(0xFFE3F2FD)
        : isHighlight
        ? const Color(0xFFFFE082).withAlpha(51)
        : const Color(0xFFEF9A9A).withAlpha(51);
    final labelColor = isTakeover
        ? const Color(0xFF1976D2)
        : isHighlight
        ? const Color(0xFFFF8F00)
        : const Color(0xFFD32F2F);

    return Card(
      color: bgColor,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: labelColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clip.startTimeStr,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: labelColor.withAlpha(26),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          clip.type,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: labelColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        clip.durationStr,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (clip.audioPath != null) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.mic,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                  if (clip.remark != null && clip.remark!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withAlpha(13),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        clip.remark!,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.primary,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

