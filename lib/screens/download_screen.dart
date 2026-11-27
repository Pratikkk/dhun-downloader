/// Download screen for the JioSaavn downloader integration.
///
/// Provides a Flutter UI to search JioSaavn, browse results, and download
/// songs/albums/playlists with progress tracking.

import 'package:flutter/material.dart';

import '../jiosaavn/api.dart';
import '../jiosaavn/client.dart';
import '../jiosaavn/downloader.dart';
import '../jiosaavn/models.dart';
import '../jiosaavn/utils.dart';

/// Screen for searching and downloading JioSaavn tracks.
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  JiosaavnDownloader? _downloader;
  bool _isDownloading = false;
  bool _isSearching = false;

  List<SearchResult> _searchResults = [];
  List<DownloadProgress> _progressList = [];
  List<Failure> _failures = [];

  int _downloaded = 0;
  int _skipped = 0;
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _initDownloader();
  }

  Future<void> _initDownloader() async {
    final config = await JiosaavnDownloader.loadConfig();
    final client = JiosaavnClient(
      timeoutSeconds: config.timeout,
      prefetchRate: config.prefetchRate,
      prefetchBurst: config.prefetchBurst,
    );
    final api = JiosaavnApi(
      client: client,
      timeoutSeconds: config.timeout,
      cache: config.cache,
      cacheTtl: config.cacheTtl,
      prefetchRate: config.prefetchRate,
      prefetchBurst: config.prefetchBurst,
    );
    if (!mounted) return;
    setState(() {
      _downloader = JiosaavnDownloader(
        api: api,
        config: config,
      )
        ..onProgress = _onProgress
        ..onTrackFinished = _onTrackFinished
        ..onAllFinished = _onAllFinished;
    });
  }

  void _onProgress(DownloadProgress progress) {
    if (!mounted) return;
    setState(() {
      final existing = _progressList.indexWhere((p) => p.position == progress.position);
      if (existing >= 0) {
        _progressList[existing] = progress;
      } else {
        _progressList.add(progress);
      }
    });
  }

  void _onTrackFinished(DownloadResult result) {
    if (!mounted) return;
    setState(() {
      if (result.success) _downloaded++;
      else _failed++;
    });
  }

  void _onAllFinished(int downloaded, int skipped, int failed) {
    if (!mounted) return;
    setState(() {
      _downloaded = downloaded;
      _skipped = skipped;
      _failed = failed;
      _isDownloading = false;
      _failures.addAll(_downloader?.failures ?? []);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Download complete: $_downloaded downloaded, $_skipped skipped, $_failed failed.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _downloadUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _downloader == null) return;

    setState(() {
      _isDownloading = true;
      _progressList.clear();
      _failures.clear();
    });

    try {
      final (kind, token) = _downloader!.resolveUrl(url);
      switch (kind) {
        case 'song':
          await _downloader!.processTrack(token);
          break;
        case 'album':
          await _downloader!.processCollection('album', token);
          break;
        case 'playlist':
          await _downloader!.processCollection('playlist', token);
          break;
        case 'artist':
          await _downloader!.processArtist(token);
          break;
        default:
          throw DownloadError('Unsupported URL kind: $kind');
      }
    } on DownloadError catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.message}'), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _downloader == null) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final results = await _downloader!.api.search(query, limit: 20);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } on DownloadError catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search error: ${e.message}'), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    _downloader?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('JioSaavn Downloader'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
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
                      onPressed: _isDownloading ? null : _downloadUrl,
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
            ),
            const SizedBox(height: 24),

            Card(
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
                          onPressed: _isSearching ? null : _search,
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
                            leading: const Icon(Icons.music_note),
                            title: Text(result.title),
                            subtitle: Text('${result.subtitle}  ·  ${result.kind}'),
                            trailing: ElevatedButton.icon(
                              onPressed: _isDownloading
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
            ),
            const SizedBox(height: 24),

            if (_progressList.isNotEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Download Progress',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      ..._progressList.where((p) =>
                          p.status != DownloadStatus.completed &&
                          p.status != DownloadStatus.failed &&
                          p.status != DownloadStatus.skipped).map((progress) =>
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('${progress.position}. ${progress.title}',
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: progress.percentage.clamp(0.0, 1.0),
                              ),
                              Text(
                                '${_progressAmount(progress)}  ·  ${progress.speed}',
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                              const SizedBox(height: 8),
                            ],
                          )),
                      if (_failures.isNotEmpty) ...[
                        const Divider(),
                        const Text('Failures',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.red)),
                        const SizedBox(height: 8),
                        ..._failures.take(5).map((f) => ListTile(
                          title: Text(f.label),
                          subtitle: Text(f.reason),
                          trailing: const Icon(Icons.error, color: Colors.red),
                        )),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _progressAmount(DownloadProgress progress) {
    if (progress.totalBytes != null && progress.totalBytes! > 0) {
      return '${(progress.bytesReceived / progress.totalBytes! * 100).round()}%';
    }
    return '${(progress.bytesReceived / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  Future<void> _downloadResult(SearchResult result) async {
    if (_downloader == null) return;
    final (kind, token) = parseUrl(result.url);
    setState(() {
      _isDownloading = true;
      _progressList.clear();
    });

    try {
      switch (kind) {
        case 'song':
          await _downloader!.processTrack(token);
          break;
        case 'album':
          await _downloader!.processCollection('album', token);
          break;
        case 'playlist':
          await _downloader!.processCollection('playlist', token);
          break;
        default:
          throw DownloadError('Unsupported URL kind: $kind');
      }
    } on DownloadError catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.message}'), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
