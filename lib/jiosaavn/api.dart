/// JioSaavn API client.
///
/// Ported from the Python `Jiosaavn` class: `api()`, `metadata()`, `search()`,
/// `getCdnURL()`, `artist_albums()`, and related methods.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'models.dart';
import 'utils.dart';

/// The main JioSaavn API client.
class JiosaavnApi {
  final JiosaavnClient client;
  final int timeoutSeconds;
  final bool cache;
  final int cacheTtl;
  final RateLimiter prefetchLimiter;

  // In-memory caches.
  final Map<String, dynamic> _metadataCache = {};
  final Map<String, dynamic> _cdnUrlCache = {};
  final Map<String, dynamic> _coverCache = {};
  final Map<String, List<String?>> _lyricsCache = {};

  JiosaavnApi({
    required this.client,
    this.timeoutSeconds = 30,
    this.cache = false,
    this.cacheTtl = 86400,
    double prefetchRate = 5.0,
    int prefetchBurst = 3,
  }) : prefetchLimiter = RateLimiter(rate: prefetchRate, burst: prefetchBurst);

  /// Call the JioSaavn web API with the given `__call` and parameters.
  Future<Map<String, dynamic>> api(String call, {Map<String, dynamic>? params}) async {
    final queryParams = <String, dynamic>{
      '__call': call,
      '_format': 'json',
      '_marker': '0',
      'ctx': 'web6dot0',
      ...?params,
    };
    final uri = Uri.parse(apiUrl).replace(queryParameters: queryParams.map((k, v) => MapEntry(k, v.toString())));
    final response = await client.get(uri, timeout: Duration(seconds: timeoutSeconds));

    // Parse JSON, handling callback-wrapped responses.
    final text = response.body.trim();
    dynamic data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      // Extract first complete JSON object (handles wrapped responses).
      final start = text.indexOf('{');
      if (start < 0) throw DownloadError('No JSON object in response');
      int depth = 0;
      bool inString = false;
      bool escape = false;
      int end = -1;
      for (var i = start; i < text.length; i++) {
        final ch = text[i];
        if (escape) {
          escape = false;
          continue;
        }
        if (ch == '\\') {
          escape = true;
          continue;
        }
        if (ch == '"' && !escape) {
          inString = !inString;
          continue;
        }
        if (!inString) {
          if (ch == '{') depth++;
          else if (ch == '}') {
            depth--;
            if (depth == 0) {
              end = i;
              break;
            }
          }
        }
      }
      if (end < 0) throw DownloadError('No complete JSON object in response');
      data = jsonDecode(text.substring(start, end + 1));
    }

    if (data == null || data is! Map || (data as Map).isEmpty) {
      throw DownloadError('JioSaavn returned no data for this item.');
    }
    final dataMap = Map<String, dynamic>.from(data as Map);
    if (dataMap.containsKey('error') && dataMap['error'] != null) {
      throw DownloadError('JioSaavn: ${dataMap['error']}');
    }
    return dataMap;
  }

  /// Fetch metadata for a song, album, or playlist.
  Future<Map<String, dynamic>> metadata(String kind, String token, {int? page}) async {
    final cacheKey = '$kind|$token|${page ?? 0}';
    if (_metadataCache.containsKey(cacheKey)) {
      return Map<String, dynamic>.from(_metadataCache[cacheKey] as Map);
    }

    final params = <String, dynamic>{
      'token': token,
      'type': kind,
      'n': collectionPageSize,
    };
    if (page != null) params['p'] = page;

    final data = await api('webapi.get', params: params);
    _metadataCache[cacheKey] = data;
    return data;
  }

  /// Search for songs, albums, and playlists.
  ///
  /// Returns supported public results (song/album/playlist only).
  Future<List<SearchResult>> search(String query, {int limit = 10}) async {
    query = query.trim();
    if (query.isEmpty) throw DownloadError('Search query cannot be blank.');
    if (limit < 1 || limit > 50) {
      throw DownloadError('Search result limit must be between 1 and 50.');
    }

    final data = await api('search.getResults', params: {
      'q': query,
      'p': 1,
      'n': limit,
    });
    final resultsRaw = data['results'];
    if (resultsRaw == null || resultsRaw is! List) {
      throw DownloadError('JioSaavn returned an unsupported search response.');
    }

    final supported = <SearchResult>[];
    for (final result in resultsRaw) {
      if (result is! Map) continue;
      final resultMap = Map<String, dynamic>.from(result);
      final rawUrl = resultMap['perma_url'] ?? resultMap['url'];
      if (rawUrl == null || rawUrl.toString().trim().isEmpty) continue;
      var urlStr = rawUrl.toString().trim();
      if (urlStr.startsWith('/')) {
        urlStr = 'https://www.jiosaavn.com$urlStr';
      }
      try {
        final normalized = normalizedUrl(urlStr);
        final (kind, _) = parseUrl(normalized);
        if (kind != 'song' && kind != 'album' && kind != 'playlist') continue;
        final title = cleanText(resultMap['title'] ?? resultMap['song'] ?? resultMap['album'] ?? 'Untitled');
        final subtitle = cleanText(resultMap['subtitle'] ?? resultMap['primary_artists'] ?? resultMap['singers'] ?? '');
        supported.add(SearchResult(
          kind: kind,
          url: normalized,
          title: title,
          subtitle: subtitle,
        ));
        if (supported.length >= limit) break;
      } on DownloadError {
        continue;
      }
    }
    return supported;
  }

  /// Get a CDN URL for a track's encrypted media URL, with optional quality fallback.
  ///
  /// Returns the resolved direct audio URL.
  Future<String> getCdnUrl(String encUrl, {List<String>? fallbackQualities}) async {
    final qualities = <String>{};
    final ordered = <String>[];
    void addQuality(String q) {
      if (!qualities.contains(q)) {
        qualities.add(q);
        ordered.add(q);
      }
    }
    addQuality(client.timeoutSeconds > 0 ? '320' : '320'); // placeholder, replaced below
    // Use the configured quality from downloader instead; here we default to 320.
    addQuality('320');
    if (fallbackQualities != null) {
      for (final q in fallbackQualities) addQuality(q);
    }

    final cacheKey = '$encUrl|${ordered.join(',')}';
    if (_cdnUrlCache.containsKey(cacheKey)) {
      final cached = _cdnUrlCache[cacheKey] as Map;
      return cached['url'] as String;
    }

    String? lastError;
    for (final quality in ordered) {
      try {
        final data = await api('song.generateAuthToken', params: {
          'url': encUrl,
          'bitrate': quality,
          'api_version': '4',
        });
        var authUrl = data['auth_url'];
        if (authUrl == null || authUrl.toString().isEmpty) {
          throw DownloadError('No audio URL is available for this track.');
        }
        final urlStr = authUrl.toString();
        if (!urlStr.startsWith('http')) {
          throw DownloadError('No audio URL is available for this track.');
        }

        // The web endpoint sometimes returns its web stream instead of AAC.
        // Known host patterns: web.* -> aac.*
        final uri = Uri.parse(urlStr);
        var host = uri.host;
        if (host.startsWith('web.')) {
          host = 'aac.${host.substring(4)}';
        } else if (host.contains('web')) {
          host = host.replaceFirst('web', 'aac');
        }
        final resolved = uri.replace(host: host).toString();

        _cdnUrlCache[cacheKey] = {'url': resolved, 'quality': quality};
        if (quality != '320') {
          // Fallback warning would go here via callback
        }
        return resolved;
      } on DownloadError catch (exc) {
        lastError = exc.message;
        final msg = exc.message.toLowerCase();
        if (msg.contains('unavailable') || msg.contains('not available')) {
          continue;
        }
        rethrow;
      }
    }
    throw DownloadError(
        'No audio URL available at any quality (tried: ${ordered.join(', ')}). Last error: $lastError');
  }

  /// Fetch all albums for an artist.
  Future<Map<String, dynamic>> artistAlbums(String artistId, {int page = 1, int limit = collectionPageSize}) async {
    try {
      return await api('artist.getAlbums', params: {
        'artist_id': artistId,
        'p': page,
        'n': limit,
      });
    } on DownloadError {
      // Fallback: search for songs by artist_id/name, extract unique album URLs.
      final searchLimit = (limit * 5).clamp(0, 100);
      final data = await api('search.getResults', params: {
        'q': artistId,
        'p': page,
        'n': searchLimit,
        '_marker': '0',
        'ctx': 'web6dot0',
      });
      final results = data['results'] as List?;
      final albumsSeen = <String>{};
      final albums = <Map<String, dynamic>>[];
      if (results != null) {
        for (final result in results) {
          if (result is! Map) continue;
          final resultMap = Map<String, dynamic>.from(result);
          final albumUrl = resultMap['album_url'];
          final albumTitle = resultMap['album'];
          final albumId = resultMap['albumid'];
          if (albumUrl == null || albumTitle == null) continue;
          final normalizedTitle = _normalizeAlbumTitle(albumTitle.toString());
          if (normalizedTitle.isEmpty || albumsSeen.contains(normalizedTitle)) continue;
          albumsSeen.add(normalizedTitle);
          albums.add({
            'id': albumId,
            'title': albumTitle,
            'perma_url': albumUrl,
            'image': resultMap['image'],
            'year': resultMap['year'],
            'primary_artists': resultMap['primary_artists'],
          });
          if (albums.length >= limit) break;
        }
      }
      return {'albums': albums, 'artist_name': artistId};
    }
  }

  /// Normalize album title for deduplication (remove edition suffixes).
  String _normalizeAlbumTitle(String title) {
    var normalized = title;
    normalized = normalized.replaceAll(
      RegExp(r'\s*[\(\[].*?(edition|deluxe|remaster|remastered|anniversary|expanded|bonus|reissue|special|collector|limited|demo|acoustic|live|instrumental|version|remix).*?[\)\]]', caseSensitive: false),
      '',
    );
    normalized = normalized.replaceAll(
      RegExp(r'\s*:\s*(edition|deluxe|remaster|remastered|anniversary|expanded|bonus|reissue|special|collector|limited|demo|acoustic|live|instrumental|version|remix).*$', caseSensitive: false),
      '',
    );
    normalized = normalized.replaceAll(
      RegExp(r'\s+\b(edition|deluxe|remaster|remastered|anniversary|expanded|bonus|reissue|special|collector|limited|demo|acoustic|live|instrumental|version|remix):\s*.*$', caseSensitive: false),
      '',
    );
    normalized = normalized.replaceAll(RegExp(r'\s*[\(\[](\d{4})[\)\]]'), '');
    return normalized.trim();
  }

  /// Fetch lyrics for a track and convert to `(lrcText, plainText)`.
  Future<List<String?>> fetchLyrics(String lyricsId) async {
    // Check cache first.
    if (_lyricsCache.containsKey(lyricsId)) {
      return List<String?>.from(_lyricsCache[lyricsId]!);
    }

    // Rate limit the API request.
    if (!await acquirePrefetch(prefetchLimiter)) {
      _lyricsCache[lyricsId] = [null, null];
      return [null, null];
    }

    try {
      final data = await api('lyrics.getLyrics', params: {
        'lyrics_id': lyricsId,
        'api_version': '4',
      });
      final (lrcText, plainText) = lyricsToLrc(data);
      String? finalPlain = plainText;
      if (finalPlain == null && lrcText == null && data.containsKey('lyrics')) {
        final lyricsVal = data['lyrics'];
        if (lyricsVal is String) {
          finalPlain = cleanText(lyricsVal.replaceAll(RegExp(r'<br\s*/?>'), '\n')).trim();
          if (finalPlain.isEmpty) finalPlain = null;
        }
      }
      _lyricsCache[lyricsId] = [lrcText, finalPlain];
      return [lrcText, finalPlain];
    } catch (exc) {
      _lyricsCache[lyricsId] = [null, null];
      return [null, null];
    }
  }

  /// Fetch cover art bytes for a track.
  Future<List<int>?> fetchCover(String coverUrl) async {
    if (_coverCache.containsKey(coverUrl)) {
      return List<int>.from(_coverCache[coverUrl] as List);
    }

    if (!await acquirePrefetch(prefetchLimiter)) return null;

    try {
      final response = await client.get(Uri.parse(coverUrl), timeout: Duration(seconds: timeoutSeconds));
      final bytes = response.bodyBytes;
      if (!(_isJpeg(bytes) || _isPng(bytes))) return null;
      _coverCache[coverUrl] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  bool _isJpeg(List<int> bytes) => bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
  bool _isPng(List<int> bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;

  void close() {
    client.close();
  }
}
