/// Client for the JioSaavn Python downloader service.
///
/// Communicates with a local Flask HTTP service that wraps the working
/// Python jiosaavn_core.py CLI. This avoids the Dart MP4 tagging issues
/// and leverages the proven Python implementation.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Base URL for the Python service (localhost only).
const _serviceBaseUrl = 'http://127.0.0.1:8765';

/// A search result from JioSaavn.
class JsSearchResult {
  final String kind; // 'song', 'album', 'playlist'
  final String url;
  final String title;
  final String subtitle;
  final String? image;

  JsSearchResult({
    required this.kind,
    required this.url,
    required this.title,
    required this.subtitle,
    this.image,
  });

  factory JsSearchResult.fromJson(Map<String, dynamic> json) {
    return JsSearchResult(
      kind: json['kind'] ?? '',
      url: json['url'] ?? '',
      title: json['title'] ?? '',
      subtitle: json['subtitle'] ?? '',
      image: json['image'],
    );
  }
}

/// Download progress from the Python service.
class JsDownloadProgress {
  final String status; // idle, downloading, completed, failed, stopped
  final int downloaded;
  final int skipped;
  final int failed;
  final String currentTrack;
  final double currentProgress; // 0.0 to 1.0
  final String currentSpeed;
  final List<Map<String, String>> failures;
  final String message;

  JsDownloadProgress({
    required this.status,
    required this.downloaded,
    required this.skipped,
    required this.failed,
    required this.currentTrack,
    required this.currentProgress,
    required this.currentSpeed,
    required this.failures,
    required this.message,
  });

  factory JsDownloadProgress.fromJson(Map<String, dynamic> json) {
    return JsDownloadProgress(
      status: json['status'] ?? 'idle',
      downloaded: json['downloaded'] ?? 0,
      skipped: json['skipped'] ?? 0,
      failed: json['failed'] ?? 0,
      currentTrack: json['current_track'] ?? '',
      currentProgress: (json['current_progress'] ?? 0.0) as double,
      currentSpeed: json['current_speed'] ?? '0.0MB/s',
      failures: List<Map<String, String>>.from(
        (json['failures'] ?? []).map((f) => Map<String, String>.from(f)),
      ),
      message: json['message'] ?? '',
    );
  }
}

/// Download configuration.
class JsDownloadConfig {
  final String outputDir;
  final String quality;
  final int workers;
  final bool lyrics;
  final bool cover;
  final bool overwrite;
  final String? genre;
  final String? template;
  final bool noExplicit;
  final int? afterYear;
  final int? beforeYear;

  JsDownloadConfig({
    this.outputDir = 'Downloads',
    this.quality = '320',
    this.workers = 4,
    this.lyrics = true,
    this.cover = true,
    this.overwrite = false,
    this.genre,
    this.template,
    this.noExplicit = false,
    this.afterYear,
    this.beforeYear,
  });

  Map<String, dynamic> toJson() {
    return {
      'output_dir': outputDir,
      'quality': quality,
      'workers': workers,
      'lyrics': lyrics,
      'cover': cover,
      'overwrite': overwrite,
      'genre': genre,
      'template': template,
      'no_explicit': noExplicit,
      'after_year': afterYear,
      'before_year': beforeYear,
    };
  }
}

/// Client for the Python downloader service.
class PythonDownloaderClient {
  final http.Client _client;
  final Duration _timeout;

  PythonDownloaderClient({
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _timeout = timeout;

  /// Check if the Python service is running.
  Future<bool> isServiceRunning() async {
    try {
      final response = await _client
          .get(Uri.parse('$_serviceBaseUrl/status'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Start the Python service as a background process.
  ///
  /// Returns the process if successfully started.
  Future<Process?> startService() async {
    // Find the service.py file
    final serviceScript = 'lib/jiosaavn/python_backend/service.py';
    final absScript = '${Directory.current.path}/$serviceScript';

    if (!await File(absScript).exists()) {
      // Try alternative locations
      final alt1 = '${Directory.current.path}/../lib/jiosaavn/python_backend/service.py';
      if (await File(alt1).exists()) {
        return await _startPythonProcess(alt1);
      }
      return null;
    }

    return await _startPythonProcess(absScript);
  }

  Future<Process?> _startPythonProcess(String scriptPath) async {
    try {
      // Use the project venv Python if available, otherwise fall back to python3
      final venvPython = '${Directory.current.path}/venv/bin/python';
      final pythonExecutable = await File(venvPython).exists() ? venvPython : 'python3';

      // Check if Flask is installed
      final flaskCheck = await Process.run(
        pythonExecutable,
        ['-c', 'import flask; print(flask.__version__)'],
      );
      if (flaskCheck.exitCode != 0) {
        // Try installing Flask
        await Process.run(
          pythonExecutable,
          ['-m', 'pip', 'install', '--break-system-packages', 'flask', 'flask-cors'],
        );
      }

      final process = await Process.start(
        pythonExecutable,
        [scriptPath],
        mode: ProcessStartMode.inheritStdio,
      );

      // Wait for service to be ready
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await isServiceRunning()) {
          return process;
        }
      }

      // Service didn't start in time
      process.kill();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Stop the Python service.
  Future<void> stopService(Process? process) async {
    if (process != null) {
      process.kill();
    }
  }

  /// Search JioSaavn for songs, albums, and playlists.
  Future<List<JsSearchResult>> search(String query, {int limit = 20}) async {
    final response = await _client
        .post(
          Uri.parse('$_serviceBaseUrl/search'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'limit': limit}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Search failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    final results = (data['results'] as List<dynamic>? ?? []);
    return results.map((r) => JsSearchResult.fromJson(r)).toList();
  }

  /// Start a download.
  ///
  /// [kind] is one of: 'song', 'album', 'playlist', 'artist'
  /// [token] is the JioSaavn token (from URL or search result)
  Future<void> download({
    required String kind,
    required String token,
    String outputDir = 'Downloads',
    String quality = '320',
    bool overwrite = false,
    bool lyrics = true,
    bool cover = true,
    int workers = 4,
    String? genre,
    String? template,
    bool noExplicit = false,
    int? afterYear,
    int? beforeYear,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$_serviceBaseUrl/download'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'kind': kind,
            'token': token,
            'output_dir': outputDir,
            'quality': quality,
            'overwrite': overwrite,
            'lyrics': lyrics,
            'cover': cover,
            'workers': workers,
            'genre': genre,
            'template': template,
            'no_explicit': noExplicit,
            'after_year': afterYear,
            'before_year': beforeYear,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Download start failed: ${response.body}');
    }
  }

  /// Get current download progress.
  Future<JsDownloadProgress> getProgress() async {
    final response = await _client
        .get(Uri.parse('$_serviceBaseUrl/progress'))
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Progress failed: ${response.body}');
    }

    return JsDownloadProgress.fromJson(jsonDecode(response.body));
  }

  /// Stream download progress via Server-Sent Events.
  Stream<JsDownloadProgress> streamProgress() async* {
    final request = http.Request('GET', Uri.parse('$_serviceBaseUrl/progress/stream'));
    final response = await _client.send(request).timeout(const Duration(seconds: 30));

    await for (final line in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data: ')) {
        final jsonStr = line.substring(6);
        if (jsonStr.isNotEmpty) {
          try {
            yield JsDownloadProgress.fromJson(jsonDecode(jsonStr));
          } catch (_) {
            // Skip malformed lines
          }
        }
      }
    }
  }

  /// Stop the current download.
  Future<void> stopDownload() async {
    final response = await _client
        .post(Uri.parse('$_serviceBaseUrl/stop'))
        .timeout(_timeout);

    if (response.statusCode != 200 && response.statusCode != 409) {
      throw Exception('Stop failed: ${response.body}');
    }
  }

  /// Get download configuration.
  Future<JsDownloadConfig> getConfig() async {
    final response = await _client
        .get(Uri.parse('$_serviceBaseUrl/config'))
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Config failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    return JsDownloadConfig(
      outputDir: data['output_dir'] ?? 'Downloads',
      quality: data['quality'] ?? '320',
      workers: data['workers'] ?? 4,
      lyrics: data['lyrics'] ?? true,
      cover: data['cover'] ?? true,
      overwrite: data['overwrite'] ?? false,
      genre: data['genre'],
      template: data['template'],
      noExplicit: data['no_explicit'] ?? false,
      afterYear: data['after_year'],
      beforeYear: data['before_year'],
    );
  }

  /// Save download configuration.
  Future<void> setConfig(JsDownloadConfig config) async {
    final response = await _client
        .post(
          Uri.parse('$_serviceBaseUrl/config'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(config.toJson()),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Save config failed: ${response.body}');
    }
  }

  void close() {
    _client.close();
  }
}

/// Singleton instance for easy access.
final pythonDownloader = PythonDownloaderClient();
