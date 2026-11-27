/// Utility functions ported from `jiosaavn_core.py`.
///
/// These handle URL parsing/validation, text cleaning, filename sanitization,
/// template rendering, LRC lyrics conversion, and date normalization.

import 'dart:convert';

/// Unescape HTML entities (e.g. `&amp;` -> `&`).
String cleanText(dynamic value) {
  if (value == null) return '';
  final text = value.toString();
  // Basic HTML entity unescape for common entities.
  final map = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&nbsp;': ' ',
  };
  var result = text;
  map.forEach((k, v) => result = result.replaceAll(k, v));
  return result;
}

/// Normalize genre/category values from a raw metadata value.
Iterable<String> genreValues(dynamic value) sync* {
  if (value == null) return;
  if (value is List || value is Set) {
    for (final item in value) yield* genreValues(item);
    return;
  }
  if (value is Map) {
    for (final key in ['text', 'title', 'name', 'genre', 'music', 'value']) {
      if (value.containsKey(key)) yield* genreValues(value[key]);
    }
    return;
  }
  final text = cleanText(value);
  if (text.isEmpty) return;
  for (final part in text.split(RegExp(r'[;,/|]'))) {
    final p = part.trim();
    if (p.isNotEmpty) yield p;
  }
}

/// De-duplicated list of genres/categories from JioSaavn track metadata.
List<String> trackGenres(Map<String, dynamic> song) {
  final out = <String>[];
  final seen = <String>{};

  void add(dynamic value) {
    for (final genre in genreValues(value)) {
      final key = genre.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(genre);
    }
  }

  for (final key in ['genre', 'genres', 'music', 'music_genre', 'primary_genre', 'language']) {
    add(song[key]);
  }
  final more = song['more_info'];
  if (more is Map) {
    for (final key in ['genre', 'genres', 'music', 'music_genre', 'language']) {
      add(more[key]);
    }
  }
  return out;
}

/// Primary (first) genre string from track metadata.
String? trackGenre(Map<String, dynamic> song) {
  final genres = trackGenres(song);
  return genres.isNotEmpty ? genres.first : null;
}

/// Collect de-duplicated string values for the given metadata keys.
List<String> metadataList(Map<String, dynamic> song, List<String> keys) {
  final out = <String>[];
  final seen = <String>{};
  final sources = <Map<String, dynamic>>[song];
  final more = song['more_info'];
  if (more is Map) sources.add(Map<String, dynamic>.from(more));

  void add(dynamic value) {
    if (value == null) return;
    if (value is List || value is Set) {
      for (final item in value) add(item);
      return;
    }
    if (value is Map) {
      for (final key in ['text', 'title', 'name', 'value']) {
        if (value.containsKey(key)) add(value[key]);
      }
      return;
    }
    final text = cleanText(value).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) {
      final k = text.toLowerCase();
      if (!seen.contains(k)) {
        seen.add(k);
        out.add(text);
      }
    }
  }

  for (final source in sources) {
    for (final key in keys) {
      add(source[key]);
    }
  }
  return out;
}

/// Normalize a date-like value to YYYY, YYYY-MM, or YYYY-MM-DD.
String? normalizeDate(dynamic value) {
  if (value == null) return null;
  var text = cleanText(value).trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d{4}$').hasMatch(text)) return text;
  text = text.replaceAll('/', '-');
  final match = RegExp(r'^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$').firstMatch(text);
  if (match != null) {
    final year = match.group(1)!;
    final monthStr = match.group(2);
    final dayStr = match.group(3);
    if (monthStr != null && dayStr != null) {
      final month = int.tryParse(monthStr);
      final day = int.tryParse(dayStr);
      if (month != null && day != null && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return '${year}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }
    if (monthStr != null) {
      final month = int.tryParse(monthStr);
      if (month != null && month >= 1 && month <= 12) {
        return '${year}-${month.toString().padLeft(2, '0')}';
      }
    }
    return year;
  }
  return text;
}

/// Format seconds as an LRC timestamp `[mm:ss.xx]`.
String? formatLrcTimestamp(dynamic seconds) {
  try {
    var total = double.parse(seconds.toString());
    if (total < 0) total = 0.0;
    var minutes = (total ~/ 60);
    var secs = total - minutes * 60;
    var centi = ((secs - secs.truncate()) * 100).round();
    var whole = secs.truncate();
    if (centi >= 100) {
      whole += 1;
      centi -= 100;
      if (whole >= 60) {
        minutes += 1;
        whole -= 60;
      }
    }
    return '[${minutes.toString().padLeft(2, '0')}:${whole.toString().padLeft(2, '0')}.${centi.toString().padLeft(2, '0')}]';
  } on FormatException {
    return null;
  }
}

/// Convert a lyrics payload (plain or synced) to `(lrcText, plainText)`.
///
/// Mirrors the Python `_lyrics_to_lrc` helper.
(String?, String?) lyricsToLrc(dynamic payload) {
  if (payload == null) return (null, null);
  if (payload is String) {
    final text = cleanText(payload).trim();
    if (text.isEmpty) return (null, null);
    final plain = cleanText(payload.replaceAll(RegExp(r'<br\s*/?>'), '\n')).trim();
    return (null, plain.isEmpty ? null : plain);
  }

  String? plain;
  String? synced;

  if (payload is Map) {
    for (final key in ['lyrics', 'plain_lyrics', 'text']) {
      final val = payload[key];
      if (val is String && val.trim().isNotEmpty) {
        plain = cleanText(val.replaceAll(RegExp(r'<br\s*/?>'), '\n')).trim();
        if (plain.isNotEmpty) break;
      }
    }
    for (final key in ['synced_lyrics', 'lrc', 'syncedLyrics', 'subtitle']) {
      final val = payload[key];
      if (val is String && val.trim().isNotEmpty && val.contains('[') && val.contains(']')) {
        synced = cleanText(val).trim();
        break;
      }
    }
    if (synced == null) {
      for (final key in ['lyrics', 'lines', 'data', 'synced_lyrics']) {
        final val = payload[key];
        if (val is List) {
          final lines = <String>[];
          for (final item in val) {
            if (item is! Map) continue;
            final ts = item['time'] ?? item['start'] ?? item['startTime'] ?? item['timestamp'];
            if (ts == null) continue;
            double tsf;
            try {
              tsf = double.parse(ts.toString());
            } on FormatException {
              continue;
            }
            // Heuristic: convert milliseconds to seconds.
            if (tsf >= 1000 && tsf == tsf.truncate()) {
              tsf = tsf / 1000.0;
            } else if (tsf > 10000) {
              tsf = tsf / 1000.0;
            }
            final stamp = formatLrcTimestamp(tsf);
            if (stamp == null) continue;
            final line = (item['line'] ?? item['text'] ?? item['lyrics'] ?? '').toString();
            final cleanLine = cleanText(line.replaceAll(RegExp(r'<br\s*/?>'), ' ')).trim();
            lines.add('$stamp $cleanLine'.trimRight());
          }
          if (lines.isNotEmpty) {
            synced = lines.join('\n');
            if (plain == null) {
              final plainLines = <String>[];
              for (final it in val) {
                if (it is! Map) continue;
                final line = (it['line'] ?? it['text'] ?? it['lyrics'] ?? '').toString();
                plainLines.add(cleanText(line.replaceAll(RegExp(r'<br\s*/?>'), ' ')).trim());
              }
              plain = plainLines.join('\n').trim();
              if (plain.isEmpty) plain = null;
            }
            break;
          }
        }
      }
    }
    if (synced == null && plain == null) {
      for (final key in ['data', 'result']) {
        if (payload.containsKey(key)) {
          final sub = payload[key];
          final (lrc, txt) = lyricsToLrc(sub);
          if (lrc != null || txt != null) return (lrc, txt);
        }
      }
    }
  }
  return (synced, plain);
}

/// Truncate a UTF-8 string to fit within `maxBytes`.
String truncateUtf8(String value, int maxBytes) {
  final encoded = utf8.encode(value);
  if (encoded.length <= maxBytes) return value;
  return utf8.decode(encoded.sublist(0, maxBytes));
}

/// Sanitize a filename component for portable filesystems.
///
/// Mirrors the Python `safe_name` using `sanitize_filename`-like rules.
String safeName(String value, {String fallback = 'Unknown', int maxBytes = 255}) {
  var result = cleanText(value);
  // Replace characters illegal on most filesystems.
  result = result.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  // Strip leading/trailing dots and spaces (portable, bounded).
  result = result.trim();
  result = result.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (maxBytes < 1) return fallback;
  final bytes = utf8.encode(result);
  if (bytes.length > maxBytes) {
    const suffix = '…';
    final suffixBytes = utf8.encode(suffix).length;
    if (maxBytes < suffixBytes) return fallback;
    final prefix = truncateUtf8(result, (maxBytes - suffixBytes).clamp(0, maxBytes));
    result = (prefix.trim().replaceAll(RegExp(r'[. ]+$'), '') + suffix);
    if (result.isEmpty) result = suffix;
    result = truncateUtf8(result, maxBytes);
  }
  return result.isEmpty ? fallback : result;
}

/// Supported template placeholders.
const _templatePlaceholders = {
  'artist', 'album', 'title', 'track', 'year', 'genre', 'quality', 'playlist',
};

final _templatePattern = RegExp(r'\{(?<name>[a-zA-Z_][a-zA-Z0-9_]*)(?::(?<fmt>[^}]*))?\}');

/// Substitute `{placeholder}` fields in `template`.
///
/// Unknown placeholders or missing values throw [ArgumentError].
String renderTemplate(String template, Map<String, dynamic> values) {
  return template.replaceAllMapped(_templatePattern, (match) {
    final name = match.group(1)!;
    if (!_templatePlaceholders.contains(name)) {
      throw ArgumentError('Unknown template placeholder {$name}');
    }
    if (!values.containsKey(name) || values[name] == null) {
      throw ArgumentError('Template placeholder {$name} is not available for this track');
    }
    var value = values[name];
    final fmt = match.group(2);
    if (fmt != null && value is int) {
      // Apply format like {track:02d}.
      switch (fmt) {
        case '02d':
          return value.toString().padLeft(2, '0');
        case 'd':
          return value.toString();
        default:
          return value.toString();
      }
    }
    return value.toString();
  });
}

/// JioSaavn API base URL.
const apiUrl = 'https://www.jiosaavn.com/api.php';

/// Collection page size used by the API.
const collectionPageSize = 1000;

/// Default number of tracks downloaded at once.
const collectionWorkers = 4;

/// Maximum concurrent workers.
const maxWorkers = 16;

/// Hosts recognized as JioSaavn.
final siteHosts = {
  'jiosaavn.com', 'www.jiosaavn.com', 'm.jiosaavn.com',
  'saavn.com', 'www.saavn.com', 'm.saavn.com',
};

/// Short/share hosts.
final shortHosts = {'saavn.app.link', 'jiosaavn.app.link'};

/// First line of a failed-file marker.
const failedFileMarker = '# jiosaavn-dl failed tracks';

/// A download or metadata error that is actionable by the caller.
class DownloadError implements Exception {
  final String message;
  DownloadError(this.message);

  @override
  String toString() => 'DownloadError: $message';
}

/// Normalize and validate a JioSaavn URL.
String normalizedUrl(String url) {
  var u = cleanText(url).trim();
  if (!u.contains('://')) {
    u = 'https://$u';
  }
  final uri = Uri.tryParse(u);
  if (uri == null) {
    throw DownloadError('Use a JioSaavn song, album, or playlist URL.');
  }
  final host = uri.host.toLowerCase();
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !(siteHosts.contains(host) || shortHosts.contains(host))) {
    throw DownloadError('Use a JioSaavn song, album, or playlist URL.');
  }
  if (uri.userInfo.isNotEmpty || (uri.port != null && uri.port != 80 && uri.port != 443)) {
    throw DownloadError('The URL contains unsupported credentials or a port.');
  }
  return u;
}

/// Parse a supported JioSaavn URL into `(kind, token)`.
///
/// `kind` is one of `song`, `album`, `playlist`, `artist`.
(String, String) parseUrl(String url) {
  final u = normalizedUrl(url);
  final uri = Uri.parse(u);
  final segments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
  String kind;
  if (segments.length >= 3 &&
      {'song', 'album', 'playlist', 'featured', 'artist'}.contains(segments[0])) {
    kind = segments[0] == 'featured' ? 'playlist' : segments[0];
  } else if (segments.length >= 4 &&
      {'s', 'p'}.contains(segments[0]) &&
      {'song', 'album', 'playlist', 'featured', 'artist'}.contains(segments[1])) {
    kind = segments[1] == 'featured' ? 'playlist' : segments[1];
  } else {
    throw DownloadError(
        'Unsupported URL. Expected a song, album, playlist, or artist link.');
  }
  var token = segments.last;
  // Fully decode token to catch double-encoded characters.
  for (var i = 0; i < 10; i++) {
    final decoded = Uri.decodeComponent(token);
    if (decoded == token) break;
    token = decoded;
  }
  if (token.isEmpty ||
      token.contains(RegExp(r'[/\\?#\r\n\x00]')) ||
      token == '.' || token == '..') {
    throw DownloadError('The URL has an invalid item token.');
  }
  return (kind, token);
}

/// Return true for truthy string values ("1", "true", "yes").
bool isTrue(dynamic value) {
  if (value == null) return false;
  return {'1', 'true', 'yes'}.contains(value.toString().toLowerCase());
}
