/// Download screen for the JioSaavn downloader integration.
///
/// Provides a Flutter UI to search JioSaavn, browse results, and download
/// songs/albums/playlists with progress tracking.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
  Directory? _outputDir;

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
      badCertificateCallback: true, // Allow self-signed certs for compatibility on port 443
    );
    final api = JiosaavnApi(
      client: client,
      timeoutSeconds: config.timeout,
      cache: config.cache,
      cacheTtl: config.cacheTtl,
      prefetchRate: config.prefetchRate,
      prefetchBurst: config.prefetchBurst,
    );

    // Resolve output directory: use saved path from config, or fall back to
    // app documents directory.
    Directory outputDir;
    final savedOutput = config.output;
    if (savedOutput.isNotEmpty) {
      final savedDir = Directory(savedOutput);
      if (await savedDir.exists()) {
        outputDir = savedDir;
      } else {
        outputDir = await getApplicationDocumentsDirectory();
      }
    } else {
      outputDir = await getApplicationDocumentsDirectory();
    }
    _outputDir = outputDir;

    if (!mounted) return;
    setState(() {
      _downloader = JiosaavnDownloader(
        api: api,
        config: config,
        outputDir: outputDir,
      )
        ..onProgress = _onProgress
        ..onTrackFinished = _onTrackFinished
        ..onAllFinished = _onAllFinished;
    });
  }

  /// Let the user pick a folder where downloaded songs will be saved.
  Future<void> _chooseOutputFolder() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Download Folder',
    );
    if (picked == null || picked.isEmpty) return; // user cancelled

    final newDir = Directory(picked);
    if (!await newDir.exists()) {
      try {
        await newDir.create(recursive: true);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot create folder: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    // Save the chosen folder to config so it persists across restarts.
    final config = await JiosaavnDownloader.loadConfig();
    await JiosaavnDownloader.saveConfig(config.copyWith(output: picked));

    // Recreate the downloader with the new output directory.
    if (!mounted) return;
    setState(() {
      _outputDir = newDir;
      _downloader = JiosaavnDownloader(
        api: _downloader!.api,
        config: config.copyWith(output: picked),
        outputDir: newDir,
      )
        ..onProgress = _onProgress
        ..onTrackFinished = _onTrackFinished
        ..onAllFinished = _onAllFinished;
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Download folder set to: $picked'),
        duration: const Duration(seconds: 3),
      ),
    );
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
            // Output folder selection card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Download Location',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            _outputDir?.path ?? 'Not set',
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: Colors.grey,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _isDownloading ? null : _chooseOutputFolder,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Choose Folder'),
                        ),
                      ],
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
                          p.status != DownloadStatus.failed &&
                          p.status != DownloadStatus.skipped).map((progress) =>
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (progress.coverUrl != null &&
                                  progress.coverUrl!.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    progress.coverUrl!
                                        .replaceAll('150x150', '500x500'),
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.music_note, size: 48),
                                  ),
                                )
                              else
                                const SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(Icons.music_note, size: 48),
                                ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${progress.position}. ${progress.title}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (progress.statusText.isNotEmpty)
                                          Text(
                                            progress.statusText,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.blueGrey,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (progress.status == DownloadStatus.completed)
                                      Row(
                                        children: [
                                          Icon(
                                            progress.metadataEmbedded
                                                ? Icons.check_circle
                                                : Icons.error,
                                            size: 16,
                                            color: progress.metadataEmbedded
                                                ? Colors.green
                                                : Colors.red,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            progress.metadataEmbedded
                                                ? 'Metadata embedded'
                                                : 'Metadata not embedded: ${progress.metadataError ?? 'unknown error'}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    const SizedBox(height: 4),
                                    LinearProgressIndicator(
                                      value: progress.percentage.clamp(0.0, 1.0),
                                    ),
                                    Text(
                                      '${_progressAmount(progress)}  ·  ${progress.speed}',
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
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
