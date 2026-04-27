import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
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
  final String type; // "亮点" or "不足"
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
    final dir = await getApplicationSupportDirectory();
    final projectDir = Directory('${dir.path}/projects');
    if (!await projectDir.exists()) {
      await projectDir.create(recursive: true);
    }
    return projectDir.path;
  }

  static Future<String> generateProjectPath() async {
    final dir = await _projectDir;
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return '$dir/video_annotator_$timestamp.va';
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

// ==================== Whisper Service ====================

class WhisperService {
  static const _model = WhisperModel.base;
  static const _downloadHost =
      'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main';
  static const _modelFileName = 'ggml-base.bin';
  static const _modelSizeLabel = '~140MB';

  static Future<String> get _modelDir async {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  static Future<bool> isModelDownloaded() async {
    final dir = await _modelDir;
    final file = File('$dir/$_modelFileName');
    return file.existsSync();
  }

  static Future<void> downloadModel({
    void Function(double progress)? onProgress,
  }) async {
    final dir = await _modelDir;
    final file = File('$dir/$_modelFileName');

    if (file.existsSync()) return;

    final uri = Uri.parse('$_downloadHost/$_modelFileName');
    final request = await HttpClient().getUrl(uri);
    final response = await request.close();

    final contentLength = response.contentLength ?? 0;
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
  }

  static Future<void> deleteModel() async {
    final dir = await _modelDir;
    final file = File('$dir/$_modelFileName');
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  static Future<String?> transcribe(String audioPath) async {
    final dir = await _modelDir;
    final whisper = Whisper(
      model: _model,
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
      return result.text?.trim();
    } catch (e) {
      return null;
    }
  }
}

// ==================== State ====================

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
  String? _recordingType; // '亮点' or '不足'
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordingPath;
  String? _recordingId;

  // Model state
  bool _isModelDownloaded = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;

  // Project state
  String? _currentProjectPath;
  bool _isDirty = false;

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
    _isModelDownloaded = await WhisperService.isModelDownloaded();
    notifyListeners();
  }

  Future<void> downloadModel() async {
    if (_isDownloading || _isModelDownloaded) return;
    _isDownloading = true;
    _downloadProgress = 0;
    notifyListeners();

    try {
      await WhisperService.downloadModel(
        onProgress: (p) {
          _downloadProgress = p;
          notifyListeners();
        },
      );
      _isModelDownloaded = true;
    } catch (e) {
      // Download failed silently
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> deleteModel() async {
    await WhisperService.deleteModel();
    _isModelDownloaded = false;
    notifyListeners();
  }

  void setWindowSeconds(int seconds) {
    _windowSeconds = seconds.clamp(5, 120);
    notifyListeners();
  }

  void start() async {
    if (_isRunning) return;
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

    if (!_isModelDownloaded) {
      return;
    }

    _recordingType = type;
    _recordingSecondsLeft = 10;
    _isRecording = true;
    _recordingId = ProjectService.generateClipId();
    notifyListeners();

    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: _recordingPath!,
    );

    Timer.periodic(const Duration(seconds: 1), (t) {
      _recordingSecondsLeft--;
      notifyListeners();
      if (_recordingSecondsLeft <= 0) {
        t.cancel();
        _stopRecordingAndTranscribe();
      }
    });
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
    final elapsed = _elapsedMs;
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
        audioPath = '$recordingsDir/$clipId.m4a';
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
    } else {
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
    final transcribePath = audioPath ?? path;
    final remark = await WhisperService.transcribe(transcribePath);

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
      createdAt: DateTime.now(),
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
    _isDirty = false;
    reset();
    notifyListeners();
  }

  Future<void> loadProject(String projectPath) async {
    final project = await ProjectService.loadProject(projectPath);
    if (project == null) return;

    _currentProjectPath = projectPath;
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
      create: (_) => AppState()..checkModelStatus(),
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.projectName),
            if (state.isDirty) ...[
              const SizedBox(width: 4),
              const Text('*', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ],
        ),
        centerTitle: true,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(flex: 2, child: _TimerSection()),
            const Divider(height: 1),
            Expanded(flex: 3, child: _ClipListSection()),
            _BottomActionsSection(),
          ],
        ),
      ),
    );
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
        title: const Text('项目列表'),
        centerTitle: true,
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
                        await state.loadProject(path);
                        state.setSelectedIndex(0);
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('已打开: $name')));
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

// ==================== Settings Page ====================

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
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

            // Model download section
            Text(
              '语音转文字模型',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text('Whisper Base 模型（约 140MB）', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: state.isModelDownloaded
                    ? Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '已下载',
                              style: TextStyle(color: Colors.green),
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

// ==================== Timer Section ====================

class _TimerSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            state.formattedTime,
            style: TextStyle(
              fontSize: 88,
              fontWeight: FontWeight.w200,
              fontFamily: 'monospace',
              letterSpacing: 4,
              color: state.isRunning
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withAlpha(180),
            ),
          ),
          Text(
            '已标记 ${state.clips.length} 个片段 · ±${state.windowSeconds}s',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _ClickToggleButton(),
          const SizedBox(height: 20),
          if (state.isRunning)
            _MarkButtons()
          else
            Text(
              '点击按钮开始计时',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== Toggle Button ====================

class _ClickToggleButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isRunning = state.isRunning;
    final color = isRunning
        ? const Color(0xFFD32F2F)
        : theme.colorScheme.primary;
    final thumbIcon = isRunning ? Icons.stop : Icons.play_arrow;
    final label = isRunning ? '点击停止' : '点击开始';

    return SizedBox(
      width: 200,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: () => state.toggle(),
        icon: Icon(thumbIcon, size: 26),
        label: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          elevation: 4,
        ),
      ),
    );
  }
}

// ==================== Mark Buttons ====================

class _MarkButtons extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Row(
      children: [
        Expanded(
          child: _MarkButton(
            type: '亮点',
            label: '⭐ 亮点',
            color: const Color(0xFFFFA000),
            textColor: Colors.black,
            count: state.clips.where((c) => c.type == '亮点').length,
            isRecording: state.isRecording && state.recordingType == '亮点',
            recordingSecondsLeft: state.recordingSecondsLeft,
            isTranscribing: state.isRecording && state.recordingType == '亮点',
            onTap: () {
              if (!state.isModelDownloaded) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('请先在设置中下载语音模型'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              if (!state.isRecording) {
                state.onMarkButtonPressed('亮点');
              }
            },
            onCancel: () => state.cancelRecording(),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _MarkButton(
            type: '不足',
            label: '⚠ 不足',
            color: const Color(0xFFD32F2F),
            textColor: Colors.white,
            count: state.clips.where((c) => c.type == '不足').length,
            isRecording: state.isRecording && state.recordingType == '不足',
            recordingSecondsLeft: state.recordingSecondsLeft,
            isTranscribing: state.isRecording && state.recordingType == '不足',
            onTap: () {
              if (!state.isModelDownloaded) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('请先在设置中下载语音模型'),
                    duration: Duration(seconds: 2),
                  ),
                );
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
    );
  }
}

class _MarkButton extends StatefulWidget {
  final String type;
  final String label;
  final Color color;
  final Color textColor;
  final int count;
  final bool isRecording;
  final int recordingSecondsLeft;
  final bool isTranscribing;
  final VoidCallback onTap;
  final VoidCallback onCancel;

  const _MarkButton({
    required this.type,
    required this.label,
    required this.color,
    required this.textColor,
    required this.count,
    required this.isRecording,
    required this.recordingSecondsLeft,
    required this.isTranscribing,
    required this.onTap,
    required this.onCancel,
  });

  @override
  State<_MarkButton> createState() => _MarkButtonState();
}

class _MarkButtonState extends State<_MarkButton> {
  bool _flash = false;

  void _triggerFlash() {
    setState(() => _flash = true);
    Future.delayed(const Duration(milliseconds: 400), () {
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
        duration: const Duration(milliseconds: 200),
        height: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isThisRecording
              ? widget.color.withAlpha(77)
              : _flash
              ? widget.color
              : widget.color.withAlpha(200),
          boxShadow: [
            BoxShadow(
              color: widget.color.withAlpha(_flash ? 150 : 77),
              blurRadius: _flash ? 16 : 8,
              spreadRadius: _flash ? 2 : 0,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isThisRecording) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: widget.recordingSecondsLeft / 10,
                      color: widget.textColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.recordingSecondsLeft}s',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: widget.textColor,
                    ),
                  ),
                ],
              ),
              Text(
                '点击取消',
                style: TextStyle(
                  fontSize: 11,
                  color: widget.textColor.withAlpha(180),
                ),
              ),
            ] else ...[
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: widget.textColor,
                ),
              ),
              if (widget.count > 0)
                Text(
                  '${widget.count}个',
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.textColor.withAlpha(180),
                  ),
                ),
            ],
          ],
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
              '滑动上方按钮开始标注',
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
    final bgColor = isHighlight
        ? const Color(0xFFFFE082).withAlpha(51)
        : const Color(0xFFEF9A9A).withAlpha(51);
    final labelColor = isHighlight
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
                    clip.timeRange,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${clip.type} #${clip.index}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: labelColor,
                        ),
                      ),
                      const SizedBox(width: 8),
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
                          clip.durationStr,
                          style: TextStyle(fontSize: 11, color: labelColor),
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

// ==================== Bottom Actions ====================

class _BottomActionsSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: state.clips.isEmpty ? null : state.reset,
              icon: const Icon(Icons.refresh),
              label: const Text('重置'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: state.clips.isEmpty
                  ? null
                  : () => _shareTxt(context, state),
              icon: const Icon(Icons.share),
              label: const Text('导出 TXT'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareTxt(BuildContext context, AppState state) async {
    final content = state.generateTxt();
    try {
      final dir = await getTemporaryDirectory();
      final fileName =
          'video_clips_${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(content);

      await Share.shareXFiles([XFile(file.path)], subject: '视频标注片段');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }
}
