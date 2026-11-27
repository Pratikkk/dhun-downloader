/// Download orchestration for the JioSaavn downloader.
///
/// Port of the Python `Jiosaavn` class's download logic:
/// `processTrack`, `process_collection`, `download_file`, `_fetch_track`,
/// `_fetch_cover`, `_prefetch_lyrics`, `_template_folder`, etc.

library jiosaavn.downloader;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'client.dart';
import 'models.dart';
import 'tags.dart';
import 'utils.dart';

/// Callback type for download progress updates.
typedef ProgressCallback = void Function(DownloadProgress progress);

/// Callback type for a single track completion.
typedef TrackCallback = void Function(DownloadResult result);

/// Main downloader class. Coordinates API calls, file downloads, and tagging.
class JiosaavnDownloader {
  final JiosaavnApi api;
  final DownloadConfig config;
  final Directory outputDir;

  // Counters.
  int downloaded = 0;
  int skipped = 0;
  int failed = 0;
  int planned = 0;

  final List<Failure> failures = [];

  // Progress callbacks.
  ProgressCallback? onProgress;
  TrackCallback? onTrackFinished;
  void Function(int downloaded, int skipped, int failed)? onAllFinished;

  // Active download tracking (for UI progress).
  final Map<int, String> _activeTitles = {};
  final Map<int, String> _activeAmount = {};

  // Per-directory index of tagged song IDs: directory path -> {trackId: filePath}
  final Map<String, Map<String, String>> _folderIds = {};

  // Cover and lyrics caches.
  final Map<String, List<int>> _coverCache = {};
  final Map<String, List<String?>> _lyricsCache = {};

  JiosaavnDownloader({
    required this.api,
    required this.config,
    Directory? outputDir,
  }) : outputDir = outputDir ?? Directory(config.output);

  /// Create a downloader with default config.
  factory JiosaavnDownloader.withDefaults() {
    final client = JiosaavnClient(
      timeoutSeconds: 30,
      prefetchRate: 5.0,
      prefetchBurst: 3,
    );
    final api = JiosaavnApi(
      client: client,
      timeoutSeconds: 30,
      cache: false,
      cacheTtl: 86400,
      prefetchRate: 5.0,
      prefetchBurst: 3,
    );
    return JiosaavnDownloader(api: api, config: const DownloadConfig());
  }

  /// Load configuration from shared preferences.
  static Future<DownloadConfig> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('jiosaavn_config');
      if (json != null) {
        return DownloadConfig.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    return const DownloadConfig();
  }

  /// Save configuration to shared preferences.
  static Future<void> saveConfig(DownloadConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jiosaavn_config', jsonEncode(config.toJson()));
    } catch (_) {}
  }

  /// Resolve a URL to (kind, token).
  (String, String) resolveUrl(String url) {
    return parseUrl(normalizedUrl(url));
  }

  /// Process a single song URL.
  Future<void> processTrack(
    String songId, {
    String? albumArtist,
    int songPos = 1,
    int totalTracks = 1,
    bool isPlaylist = false,
    Map<String, dynamic>? songData,
  }) async {
    Map<String, dynamic> song;
    if (songData != null &&
        songData.containsKey('song') &&
        songData.containsKey('encrypted_media_url')) {
      song = Map<String, dynamic>.from(songData);
    } else {
      final metadata = await api.metadata('song', songId);
      if (metadata.containsKey('song')) {
        song = Map<String, dynamic>.from(metadata['song'] as Map);
      } else {
        final candidates = metadata['songs'];
        if (candidates is! List) {
          throw DownloadError(
            'Track metadata is missing or has an unsupported format.',
          );
        }
        song = candidates.cast<Map>().firstWhere(
          (v) => v.containsKey('song'),
          orElse: () => throw DownloadError(
            'Track metadata is missing or has an unsupported format.',
          ),
        ) as Map<String, dynamic>;
      }
    }

    // Filter by explicit content.
    if (config.noExplicit && isTrue(song['explicit_content'])) {
      skipped++;
      final title = cleanText(song['song']);
      _status(
        'Skipped (explicit content): ${title.isNotEmpty ? title : songId}',
      );
      _notifyTrackFinished(
        songPos,
        totalTracks,
        title.isNotEmpty ? title : songId,
        (cleanText(song['primary_artists'])).isNotEmpty ? cleanText(song['primary_artists']) : 'Unknown Artist',
        'Skipped',
      );
      return;
    }

    // Filter by release year.
    final yearStr = cleanText(song['year']);
    if (yearStr.isNotEmpty) {
      final year = int.tryParse(yearStr);
      if (year != null) {
        if (config.afterYear != null && year < config.afterYear!) {
          skipped++;
          final title = cleanText(song['song']);
          _status(
            'Skipped (year $year before ${config.afterYear}): ${title.isNotEmpty ? title : songId}',
          );
          _notifyTrackFinished(
            songPos,
            totalTracks,
            title.isNotEmpty ? title : songId,
            (cleanText(song['primary_artists'])).isNotEmpty ? cleanText(song['primary_artists']) : 'Unknown Artist',
            'Skipped',
          );
          return;
        }
        if (config.beforeYear != null && year > config.beforeYear!) {
          skipped++;
          final title = cleanText(song['song']);
          _status(
            'Skipped (year $year after ${config.beforeYear}): ${title.isNotEmpty ? title : songId}',
          );
          _notifyTrackFinished(
            songPos,
            totalTracks,
            title.isNotEmpty ? title : songId,
            (cleanText(song['primary_artists'])).isNotEmpty ? cleanText(song['primary_artists']) : 'Unknown Artist',
            'Skipped',
          );
          return;
        }
      }
    }

    final title = cleanText(song['song']);
    final artists = cleanText(albumArtist?.isNotEmpty == true ? albumArtist : song['primary_artists']);
    final folder = _templateFolder(song, artists, isPlaylist, songPos);
    final directory = Directory(p.join(outputDir.path, folder));
    final prefix = '${songPos.toString().padLeft(2, '0')}. ';
    final suffix = '.m4a';
    final safeTitle = safeName(
      title,
      maxBytes: 255 - utf8.encode(prefix + suffix).length,
    );
    final destination = File(
      p.join(directory.path, '$prefix$safeTitle$suffix'),
    );

    _notifyTrackStarted(songPos, title);
    _status('[$songPos/$totalTracks] $title — $artists');

    final trackId = cleanText(song['id'] ?? songId);
    _status('  JioSaavn ID: $trackId', verbose: true);

    final existing = await _existingDestination(
      directory,
      destination,
      trackId,
      config.overwrite,
    );
    if (existing['found'] as bool) {
      skipped++;
      _status('  Skipped (song ID already exists; use overwrite to replace).');
      _notifyTrackFinished(songPos, totalTracks, title, artists, 'Skipped');
      return;
    }

    try {
      await _fetchTrack(
        song,
        songId,
        directory,
        destination,
        trackId,
        albumArtist,
        songPos,
        totalTracks,
      );
    } catch (e) {
      rethrow;
    }
    downloaded++;
    _status('  Saved: ${destination.path}');
    _notifyTrackFinished(
      songPos,
      totalTracks,
      title,
      artists,
      'Downloaded',
      filePath: destination.path,
    );
  }

  /// Process a collection (album or playlist).
  Future<void> processCollection(String kind, String token) async {
    if (kind != 'album' && kind != 'playlist') {
      throw DownloadError(
        'Unsupported collection kind: $kind. Expected "album" or "playlist".',
      );
    }

    final data = await api.metadata(kind, token);
    final songsRaw = data['songs'];
    if (songsRaw == null || songsRaw is! List || songsRaw.isEmpty) {
      throw DownloadError('This collection has no available tracks.');
    }

    final name = cleanText(data['title'] ?? data['listname']);
    final effectiveName = name.isNotEmpty ? name : 'Untitled';
    var reportedTotal = songsRaw.length;
    final rawTotal = data['list_count'];
    if (rawTotal is int && rawTotal >= 0) {
      reportedTotal = rawTotal;
    } else if (rawTotal is String) {
      final parsed = int.tryParse(rawTotal);
      if (parsed != null) reportedTotal = parsed;
    }

    final songs = <Map<String, dynamic>>[];
    for (final item in songsRaw) {
      if (item is Map) songs.add(Map<String, dynamic>.from(item));
    }

    // Handle playlist pagination.
    if (kind == 'playlist' && reportedTotal > songs.length) {
      final pageSize = songs.length;
      final maxPages = (reportedTotal + pageSize - 1) ~/ pageSize;
      final pageSignatures = <String>{_pageSignature(songs)};
      for (var page = 2; page <= maxPages; page++) {
        final pageData = await api.metadata(kind, token, page: page);
        final pageSongsRaw = pageData['songs'];
        if (pageSongsRaw == null ||
            pageSongsRaw is! List ||
            pageSongsRaw.isEmpty) {
          break;
        }
        final pageSongs = <Map<String, dynamic>>[];
        for (final item in pageSongsRaw) {
          if (item is Map) pageSongs.add(Map<String, dynamic>.from(item));
        }
        final sig = _pageSignature(pageSongs);
        if (pageSignatures.contains(sig)) break;
        pageSignatures.add(sig);
        songs.addAll(pageSongs);
        if (songs.length >= reportedTotal) break;
      }
    }

    _status('$kind: $effectiveName (${songs.length} tracks)');
    if (reportedTotal > songs.length) {
      _status(
        'Warning: JioSaavn returned ${songs.length} of $reportedTotal tracks.',
      );
    }

    // Incremental sync: filter existing tracks (playlists only).
    if (kind == 'playlist') {
      final originalCount = songs.length;
      final filtered = <Map<String, dynamic>>[];
      for (final song in songs) {
        final trackId = cleanText(song['id']);
        if (trackId.isEmpty) {
          filtered.add(song);
          continue;
        }
        final found = await _libraryHasTrack(trackId);
        if (!found) filtered.add(song);
      }
      if (filtered.length < originalCount) {
        _status(
          'Incremental sync: ${originalCount - filtered.length} tracks already exist, ${filtered.length} new tracks to download',
        );
      }
      if (filtered.isEmpty) {
        _status('No new tracks to download.');
        return;
      }
      songs.clear();
      songs.addAll(filtered);
    }

    // Download with concurrency.
    final workers = config.workers.clamp(1, maxWorkers);
    try {
      await _runWithConcurrency(workers, songs.length, (pos) {
        final song = songs[pos];
        return _downloadCollectionTrack(
          kind,
          data,
          effectiveName,
          pos + 1,
          songs.length,
          song,
        );
      });
    } finally {
      _finishProgress();
    }
  }

  /// Process an artist's albums.
  Future<void> processArtist(String artistId) async {
    var page = 1;
    final allAlbums = <Map<String, dynamic>>[];

    while (true) {
      final data = await api.artistAlbums(artistId, page: page);
      final albumsRaw = data['albums'];
      if (albumsRaw == null || albumsRaw is! List || albumsRaw.isEmpty) break;
      for (final item in albumsRaw) {
        if (item is Map) allAlbums.add(Map<String, dynamic>.from(item));
      }
      if (albumsRaw.length < collectionPageSize) break;
      page++;
    }

    if (allAlbums.isEmpty) {
      throw DownloadError('This artist has no available albums.');
    }

    final artistName = cleanText(
          allAlbums.first['artist_name'] ?? allAlbums.first['artist'],
        );
    final effectiveArtistName = artistName.isNotEmpty ? artistName : 'Unknown Artist';
    _status('Artist: $effectiveArtistName (${allAlbums.length} albums)');

    final workers = config.workers.clamp(1, maxWorkers);
    try {
      await _runWithConcurrency(workers, allAlbums.length, (pos) {
        final album = allAlbums[pos];
        final albumId =
            album['id'] ?? (album['perma_url'] as String?)?.split('/').last;
        if (albumId == null) return Future.value();
        return _downloadArtistAlbum(albumId.toString(), pos + 1);
      });
    } finally {
      _finishProgress();
    }
  }

  /// Run [task] for each index [0..count) with at most [concurrency] concurrent tasks.
  Future<void> _runWithConcurrency(
    int concurrency,
    int count,
    Future<void> Function(int index) task,
  ) async {
    if (count == 0) return;
    final semaphore = _Semaphore(concurrency);
    final futures = <Future<void>>[];
    for (var i = 0; i < count; i++) {
      final index = i;
      futures.add(semaphore.run(() => task(index)));
    }
    await Future.wait(futures);
  }

  // ================= Internal helpers =================

  Future<void> _downloadCollectionTrack(
    String kind,
    Map<String, dynamic> data,
    String name,
    int pos,
    int total,
    Map<String, dynamic> song,
  ) async {
    String? trackToken;
    try {
      final permaUrl = song['perma_url'];
      if (permaUrl is String && permaUrl.isNotEmpty) {
        try {
          final (k, t) = parseUrl(permaUrl);
          if (k == 'song') trackToken = t;
        } on DownloadError {
          // Fall through to ID.
        }
      }
      trackToken ??= song['id']?.toString();
      if (trackToken == null) {
        _recordFailure(
          'Track $pos of $name',
          DownloadError('Track is missing its URL.'),
        );
        return;
      }

      await processTrack(
        trackToken,
        albumArtist: kind == 'album'
            ? cleanText(data['primary_artists'])
            : null,
        songPos: pos,
        totalTracks: total,
        isPlaylist: kind == 'playlist',
        songData: song,
      );
    } catch (e) {
      final title = _activeTitles[pos] ?? '';
      _recordFailure(
        '${title.isEmpty ? 'Track $pos' : title} (track $pos of $name)',
        e,
      );
      if (_activeTitles.containsKey(pos)) {
        _notifyTrackFailed(pos, total, title, e);
      }
    }
  }

  Future<void> _downloadArtistAlbum(String albumId, int pos) async {
    try {
      await processCollection('album', albumId);
    } catch (e) {
      _recordFailure('Album $albumId', e);
    }
  }

  String _pageSignature(List<Map<String, dynamic>> items) {
    final ids = <String>[];
    for (final item in items) {
      final id = item['id'] ?? item['perma_url'];
      if (id != null) ids.add(id.toString());
    }
    return ids.join('|');
  }

  Future<bool> _libraryHasTrack(String trackId) async {
    if (trackId.isEmpty) return false;
    for (final index in _folderIds.values) {
      if (index.containsKey(trackId)) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> _existingDestination(
    Directory directory,
    File destination,
    String trackId,
    bool overwrite,
  ) async {
    await directory.create(recursive: true);
    final dirPath = directory.path;
    _folderIds.putIfAbsent(dirPath, () => {});
    final index = await _scanFolder(directory);
    _folderIds[dirPath] = index;

    if (await destination.exists()) {
      final existingId = await readJioSaavnId(destination.path);
      if (existingId == trackId) {
        return {'found': true, 'path': destination.path};
      }
      final stat = await destination.stat();
      if (stat.size > 0) {
        return {'found': true, 'path': destination.path};
      }
    }

    // Find non-conflicting name.
    var chosen = destination.path;
    var suffix = 2;
    final stem = destination.path.replaceAll('.m4a', '');
    while (await File(chosen).exists()) {
      chosen = '$stem [$trackId]$suffix.m4a';
      suffix++;
    }
    return {'found': false, 'path': chosen};
  }

  Future<Map<String, String>> _scanFolder(Directory directory) async {
    final index = <String, String>{};
    try {
      if (!await directory.exists()) return index;
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.m4a')) {
          final trackId = await readJioSaavnId(entity.path);
          if (trackId != null && trackId.isNotEmpty) {
            index[trackId] = entity.path;
          }
        }
      }
    } catch (_) {}
    return index;
  }

  void _recordFailure(String label, dynamic reason, [String? url]) {
    failed++;
    failures.add(Failure(label: label, reason: reason.toString(), url: url));
  }

  // ================= Progress tracking =================

  void _finishProgress() {
    if (onAllFinished != null) {
      onAllFinished!(downloaded, skipped, failed);
    }
  }

  void _notifyTrackStarted(int pos, String title) {
    _activeTitles[pos] = title;
    _notifyProgress(
      pos,
      title,
      'Starting...',
      0,
      null,
      0.0,
      '0.0MB/s',
      DownloadStatus.downloading,
    );
  }

  void _notifyTrackProgress(int pos, int done, int? total) {
    final percentage = total != null && total > 0 ? done / total : 0.0;
    final amount = total != null && total > 0
        ? '${(done * 100 ~/ total).clamp(0, 100)}%'
        : '${(done / 1024 / 1024).toStringAsFixed(1)}MB';
    _activeAmount[pos] = amount;
    _notifyProgress(
      pos,
      _activeTitles[pos] ?? '',
      amount,
      done,
      total,
      percentage,
      '',
      DownloadStatus.downloading,
    );
  }

  void _notifyTrackFinished(
    int pos,
    int total,
    String title,
    String artists,
    String outcome, {
    String? filePath,
  }) {
    _activeTitles.remove(pos);
    _activeAmount.remove(pos);
    final status = outcome == 'Downloaded'
        ? DownloadStatus.completed
        : outcome == 'Skipped'
        ? DownloadStatus.skipped
        : DownloadStatus.failed;
    _notifyProgress(pos, title, outcome, 0, total, 1.0, '', status);
    if (onTrackFinished != null) {
      onTrackFinished!(
        DownloadResult(
          success: outcome == 'Downloaded',
          filePath: filePath,
          error: outcome == 'Failed' ? outcome : null,
          title: title,
        ),
      );
    }
  }

  void _notifyTrackFailed(int pos, int total, String title, dynamic exc) {
    _activeTitles.remove(pos);
    _activeAmount.remove(pos);
    _notifyProgress(
      pos,
      title,
      'Failed: $exc',
      0,
      total,
      0.0,
      '',
      DownloadStatus.failed,
    );
  }

  void _notifyProgress(
    int pos,
    String title,
    String amount,
    int done,
    int? total,
    double percentage,
    String speed,
    DownloadStatus status,
  ) {
    if (onProgress == null) return;
    onProgress!(
      DownloadProgress(
        position: pos,
        total: total ?? 0,
        title: title,
        artists: '',
        bytesReceived: done,
        totalBytes: total,
        percentage: percentage,
        speed: speed,
        status: status,
      ),
    );
  }

  void _status(String message, {bool verbose = false}) {
    if (verbose && onProgress != null) {
      onProgress!(
        DownloadProgress(
          position: 0,
          total: 0,
          title: message,
          artists: '',
          status: DownloadStatus.downloading,
        ),
      );
    }
  }

  // ================= Template rendering =================

  String _templateFolder(
    Map<String, dynamic> song,
    String artists,
    bool isPlaylist,
    int songPos,
  ) {
    if (config.template == null || config.template!.isEmpty) {
      if (isPlaylist) {
        return safeName(cleanText(song['listname'] ?? song['title'] ?? 'Playlist'));
      }
      return safeName(
        '${cleanText(song['album'])} - $artists [${song['year']}]',
      );
    }
    final year = cleanText(song['year']);
    final genre =
        config.genre ??
        trackGenre(Map<String, dynamic>.from(song)) ??
        'Unknown';
    final playlist = safeName(isPlaylist.toString());
    final values = {
      'artist': artists,
      'album': cleanText(song['album']),
      'title': cleanText(song['song']),
      'track': songPos,
      'year': year,
      'genre': genre,
      'quality': config.quality,
      'playlist': playlist,
    };
    try {
      final rendered = renderTemplate(config.template!, values);
      final components = <String>[];
      for (final part in rendered.split('/')) {
        if (part.trim().isNotEmpty) {
          components.add(safeName(part.trim()));
        }
      }
      return components.isNotEmpty ? components.join('/') : 'Unknown';
    } on ArgumentError {
      return safeName(
        '${cleanText(song['album'])} - $artists',
      );
    }
  }

  // ================= Fetch and download a single track =================

  Future<http.StreamedResponse> _sendDownloadRequest(
    String url,
    int offset,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll({
      'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': '*/*',
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0) 'Accept-Encoding': 'identity',
    });
    try {
      return await api.client
          .send(request)
          .timeout(Duration(seconds: config.timeout));
    } on http.ClientException catch (e) {
      throw DownloadError('Download interrupted: $e');
    }
  }

  Future<void> _fetchTrack(
    Map<String, dynamic> song,
    String songId,
    Directory directory,
    File destination,
    String trackId,
    String? albumArtist,
    int songPos,
    int totalTracks,
  ) async {
    final encrypted = song['encrypted_media_url'];
    if (encrypted == null || encrypted.toString().isEmpty) {
      throw DownloadError(
        'Audio is unavailable for this track (it may be restricted in your region).',
      );
    }

    await directory.create(recursive: true);
    final audioUrl = await api.getCdnUrl(
      encrypted.toString(),
      quality: config.quality,
    );

    // Prefetch cover and lyrics in parallel with download.
    final coverFuture = _fetchCover(song, directory);
    final lyricsFuture = _prefetchLyrics(song);

    final partial = File('${destination.path}.${config.quality}.part');
    var offset = 0;
    if (await partial.exists()) {
      offset = await partial.length();
    }

    http.StreamedResponse response = await _sendDownloadRequest(audioUrl, offset);
    if (response.statusCode == 416 && offset > 0) {
      await partial.delete();
      offset = 0;
      response = await _sendDownloadRequest(audioUrl, 0);
    } else if (response.statusCode == 416) {
      throw DownloadError('The server rejected the download range.');
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/') || contentType.contains('json')) {
      throw DownloadError(
        'The server returned an error page instead of media.',
      );
    }

    final append = offset > 0 && response.statusCode == 206;
    var savedBefore = offset;
    var size = 0;
    int? totalSize;

    if (append) {
      final contentRange = response.headers['content-range'] ?? '';
      final rangeMatch = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
          .firstMatch(contentRange);
      if (rangeMatch == null) {
        await partial.delete();
        throw DownloadError('The server returned an invalid range response.');
      }
      final start = int.parse(rangeMatch.group(1)!);
      final end = int.parse(rangeMatch.group(2)!);
      if (start != offset || end < offset) {
        await partial.delete();
        throw DownloadError('The server returned an invalid range response.');
      }
      final totalStr = rangeMatch.group(3)!;
      if (totalStr != '*') {
        totalSize = int.parse(totalStr);
        if (end >= totalSize) {
          await partial.delete();
          throw DownloadError('The server returned an invalid range response.');
        }
      }
    }

    if (totalSize == null && !contentType.contains('gzip')) {
      final length = response.headers['content-length'];
      if (length != null) {
        final parsedLength = int.tryParse(length);
        if (parsedLength != null) {
          totalSize = savedBefore + parsedLength;
        }
      }
    }

    final mode = append ? FileMode.writeOnlyAppend : FileMode.writeOnly;
    final sink = partial.openWrite(mode: mode);
    var lastTime = DateTime.now();
    var bytesSinceThrottle = 0;

    try {
      await for (final chunk in response.stream) {
        if (chunk.isNotEmpty) {
          sink.add(chunk);
          size += chunk.length;
          _notifyTrackProgress(songPos, savedBefore + size, totalSize);

          final maxSpeed = config.maxSpeed;
          if (maxSpeed != null && maxSpeed > 0) {
            bytesSinceThrottle += chunk.length;
            final now = DateTime.now();
            final elapsed = now.difference(lastTime).inMilliseconds / 1000.0;
            if (elapsed > 0) {
              final currentRate = bytesSinceThrottle / elapsed;
              if (currentRate > maxSpeed) {
                final targetTime = bytesSinceThrottle / maxSpeed;
                final sleepTime = targetTime - elapsed;
                if (sleepTime > 0) {
                  await Future.delayed(
                    Duration(milliseconds: (sleepTime * 1000).round()),
                  );
                }
              }
            }
            lastTime = now;
            bytesSinceThrottle = 0;
          }
        }
      }
    } finally {
      await sink.close();
    }

    if (size == 0 && offset == 0) {
      await partial.delete();
      throw DownloadError('The server returned an empty file.');
    }

    final expected = response.headers['content-length'];
    if (expected != null && int.tryParse(expected) != null) {
      if (size != int.parse(expected)) {
        throw DownloadError('Download was incomplete. Please retry.');
      }
    }
    if (totalSize != null) {
      final partialLength = await partial.length();
      if (partialLength != totalSize) {
        throw DownloadError('Download was incomplete. Please retry.');
      }
    }

    final artwork = await coverFuture;
    final lyricsResult = await lyricsFuture;

    final songWithLyrics = Map<String, dynamic>.from(song);
    if (lyricsResult != null) {
      songWithLyrics['lyrics_text'] = lyricsResult[1];
      songWithLyrics['lrc_text'] = lyricsResult[0];
    }

    final tagResult = await tagMp4(
      filePath: partial.path,
      song: songWithLyrics,
      albumArtist: albumArtist ?? '',
      trackPos: songPos,
      totalTracks: totalTracks,
      artwork: artwork,
      songId: songId,
    );

    if (!tagResult.success) {
      _status('  Warning: tagging failed: ${tagResult.error}');
    }

    await partial.rename(destination.path);
    await _discardPartials(destination);

    _folderIds.putIfAbsent(directory.path, () => {})[trackId] =
        destination.path;

    _status('  Saved: ${destination.path}', verbose: true);
  }

  Future<List<int>?> _fetchCover(
    Map<String, dynamic> song,
    Directory directory,
  ) async {
    if (!config.cover || song['image'] == null) return null;
    var coverUrl = song['image'] as String;
    coverUrl = coverUrl.replaceAll('150x150', '500x500');

    if (_coverCache.containsKey(coverUrl)) {
      return List<int>.from(_coverCache[coverUrl]!);
    }

    if (!await api.prefetchLimiter.acquire(
      timeout: const Duration(seconds: 30),
    )) {
      _status('  Warning: cover fetch rate limited');
      return null;
    }

    try {
      final response = await api.client.get(
        Uri.parse(coverUrl),
        timeout: Duration(seconds: config.timeout),
      );
      final bytes = response.bodyBytes;
      if (!_isJpeg(bytes) && !_isPng(bytes)) {
        _status('  Warning: invalid cover image');
        return null;
      }
      _coverCache[coverUrl] = bytes;
      return bytes;
    } catch (exc) {
      _status('  Warning: cover unavailable: $exc');
      return null;
    }
  }

  Future<List<String?>?> _prefetchLyrics(Map<String, dynamic> song) async {
    if (!config.lyrics || !isTrue(song['has_lyrics']) || song['id'] == null) {
      return null;
    }
    final lyricsId = song['id'].toString();

    if (_lyricsCache.containsKey(lyricsId)) {
      return List<String?>.from(_lyricsCache[lyricsId]!);
    }

    if (!await api.prefetchLimiter.acquire(
      timeout: const Duration(seconds: 30),
    )) {
      _status('  Warning: lyrics fetch rate limited');
      _lyricsCache[lyricsId] = [null, null];
      return [null, null];
    }

    try {
      final result = await api.fetchLyrics(lyricsId);
      _lyricsCache[lyricsId] = result;
      return result;
    } catch (exc) {
      _lyricsCache[lyricsId] = [null, null];
      _status('  Warning: lyrics unavailable: $exc');
      return [null, null];
    }
  }

  Future<void> _discardPartials(File path) async {
    final prefix = '${p.basename(path.path)}.';
    final dir = Directory(p.dirname(path.path));
    try {
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        if (entity is File &&
            entity.path.endsWith('.part') &&
            entity.path.startsWith(prefix)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  bool _isJpeg(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF;
  bool _isPng(List<int> bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;

  void close() {
    api.close();
  }
}

/// Simple semaphore for limiting concurrency.
class _Semaphore {
  final int _max;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this._max);

  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_current < _max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final completer = _waiters.removeAt(0);
      completer.complete();
    } else {
      _current--;
    }
  }
}
