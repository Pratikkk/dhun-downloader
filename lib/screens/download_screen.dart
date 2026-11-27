/// Download screen for the JioSaavn downloader integration.
///
/// Uses the Python jiosaavn-downloader CLI as a local HTTP service,
/// avoiding the Dart MP4 tagging issues entirely. The Python service
/// handles all API calls, downloads, and metadata embedding.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../jiosaavn/python_service_client.dart';

/// Screen for searching and downloading JioSaavn tracks.
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  bool _isDownloading = false;
  bool _isSearching = false;
  bool _serviceReady = false;
  bool _serviceStarting = false;
  String _serviceError = '';

  List<JsSearchResult> _searchResults = [];
  StreamSubscription<JsDownloadProgress>? _progressSubscription;
  JsDownloadProgress? _currentProgress;

  String _outputDir = 'Downloads';
  String _quality = '320';
  int _workers = 4;
  bool _lyrics = true;
  bool _cover = true;
  bool _overwrite = false;
  bool _noExplicit = false;
  int? _afterYear;
  int? _beforeYear;

  Process? _pythonProcess;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    setState(() {
      _serviceStarting = true;
      _serviceError = '';
    });

    try {
      _pythonProcess = await pythonDownloader.startService();

      if (_pythonProcess == null) {
        setState(() {
          _serviceError = 'Could not start Python service. '
              'Ensure Python 3 and Flask are installed.';
          _serviceStarting = false;
        });
        return;
      }

      final ready = await pythonDownloader.isServiceRunning();
      if (!ready) {
        setState(() {
          _serviceError = 'Python service started but is not responding.';
          _serviceStarting = false;
        });
        return;
      }

      final config = await pythonDownloader.getConfig();
      if (!mounted) return;
      setState(() {
        _outputDir = config.outputDir;
        _quality = config.quality;
        _workers = config.workers;
        _lyrics = config.lyrics;
        _cover = config.cover;
        _overwrite = config.overwrite;
        _noExplicit = config.noExplicit;
        _afterYear = config.afterYear;
        _beforeYear = config.beforeYear;
        _serviceReady = true;
        _serviceStarting = false;
      });

      _startProgressStream();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serviceError = 'Error starting service: $e';
        _serviceStarting = false;
      });
    }
  }

  void _startProgressStream() {
    _progressSubscription = pythonDownloader.streamProgress().listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _currentProgress = progress;
          _isDownloading = progress.status == 'downloading';
        });
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _isDownloading = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isDownloading = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    _progressSubscription?.cancel();
    pythonDownloader.close();
    if (_pythonProcess != null) {
      _pythonProcess!.kill();
    }
    super.dispose();
  }

  Future<void> _downloadUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || !_serviceReady) return;

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showError('Invalid URL');
      return;
    }

    final segments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 3) {
      _showError('Invalid JioSaavn URL');
      return;
    }

    String kind = segments[0];
    String token = segments.last;

    if (kind == 'featured') kind = 'playlist';

    if (!{'song', 'album', 'playlist', 'artist'}.contains(kind)) {
      _showError('Unsupported URL type: $kind');
      return;
    }

    setState(() {
      _isDownloading = true;
      _currentProgress = null;
    });

    try {
      await pythonDownloader.download(
        kind: kind,
        token: token,
        outputDir: _outputDir,
        quality: _quality,
        overwrite: _overwrite,
        lyrics: _lyrics,
        cover: _cover,
        workers: _workers,
        noExplicit: _noExplicit,
        afterYear: _afterYear,
        beforeYear: _beforeYear,
      );
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      _showError('Download failed: $e');
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || !_serviceReady) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final results = await pythonDownloader.search(query, limit: 20);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
      });
      _showError('Search failed: $e');
    }
  }

  Future<void> _downloadResult(JsSearchResult result) async {
    setState(() {
      _isDownloading = true;
      _currentProgress = null;
    });

    try {
      final token = result.url.split('/').last;
      await pythonDownloader.download(
        kind: result.kind,
        token: token,
        outputDir: _outputDir,
        quality: _quality,
        overwrite: _overwrite,
        lyrics: _lyrics,
        cover: _cover,
        workers: _workers,
        noExplicit: _noExplicit,
        afterYear: _afterYear,
        beforeYear: _beforeYear,
      );
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      _showError('Download failed: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String _progressAmount(double pct) {
    return '${pct.toStringAsFixed(0)}%';
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'downloading':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      case 'stopped':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('JioSaavn Downloader'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_currentProgress != null &&
              _currentProgress!.status == 'downloading')
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: () {
                pythonDownloader.stopDownload();
                setState(() {
                  _isDownloading = false;
                });
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildServiceStatusCard(),
            const SizedBox(height: 16),
            _buildDownloadUrlCard(),
            const SizedBox(height: 16),
            _buildSearchCard(),
            const SizedBox(height: 16),
            if (_currentProgress != null) ...[
              _buildProgressCard(),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildServiceStatusCard() {
    if (_serviceStarting) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Starting Python Service...',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Center(
                child: CircularProgressIndicator(),
              ),
            ],
          ),
        ),
      );
    }

    if (!_serviceReady) {
      return Card(
        color: Colors.red.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Service Error',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.red)),
              const SizedBox(height: 8),
              Text(_serviceError),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _initService,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Python Service Ready',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Output: $_outputDir  |  Quality: $_quality kbps  |  Workers: $_workers'),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: _cover,
                  onChanged: (v) => setState(() => _cover = v ?? false),
                ),
                const Text('Download Cover Art'),
                const SizedBox(width: 16),
                Checkbox(
                  value: _lyrics,
                  onChanged: (v) => setState(() => _lyrics = v ?? false),
                ),
                const Text('Fetch Lyrics'),
                const SizedBox(width: 16),
                Checkbox(
                  value: _overwrite,
                  onChanged: (v) => setState(() => _overwrite = v ?? false),
                ),
                const Text('Overwrite'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadUrlCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Download by URL',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'JioSaavn URL',
                hintText:
                    'https://www.jiosaavn.com/song/... or album/playlist link',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isDownloading || !_serviceReady ? null : _downloadUrl,
              icon: _isDownloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_isDownloading ? 'Downloading...' : 'Download'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Search JioSaavn',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search query',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isSearching || !_serviceReady ? null : _search,
                  child: Text(_isSearching ? 'Searching...' : 'Search'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isSearching)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
              ),
            if (_searchResults.isNotEmpty && !_isSearching) ...[
              const Text('Search Results',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ..._searchResults.map((result) => ListTile(
                    leading: result.image != null && result.image!.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              result.image!.replaceAll('150x150', '500x500'),
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.music_note, size: 48),
                            ),
                          )
                        : const Icon(Icons.music_note, size: 48),
                    title: Text(result.title),
                    subtitle: Text('${result.subtitle}  ·  ${result.kind}'),
                    trailing: ElevatedButton.icon(
                      onPressed: _isDownloading || !_serviceReady
                          ? null
                          : () => _downloadResult(result),
                      icon: const Icon(Icons.download),
                      label: const Text('Download'),
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final progress = _currentProgress!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Download Progress',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(progress.status).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    progress.status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(progress.status),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (progress.currentTrack.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      'https://via.placeholder.com/48x48',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.music_note, size: 48),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          progress.currentTrack,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (progress.message.isNotEmpty)
                          Text(
                            progress.message,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.currentProgress.clamp(0.0, 1.0),
              ),
              Text(
                '${_progressAmount(progress.currentProgress * 100)}  ·  ${progress.currentSpeed}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (progress.failures.isNotEmpty) ...[
              const Divider(),
              const Text('Failures',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.red)),
              const SizedBox(height: 8),
              ...progress.failures.take(5).map((f) => ListTile(
                    title: Text(f['label'] ?? 'Unknown'),
                    subtitle: Text(f['reason'] ?? 'Unknown error'),
                    trailing: const Icon(Icons.error, color: Colors.red),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  )),
            ],
            if (progress.status == 'completed') ...[
              const SizedBox(height: 8),
              Text(
                'Download complete: ${progress.downloaded} downloaded, '
                '${progress.skipped} skipped, ${progress.failed} failed.',
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.green),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
