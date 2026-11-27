/// Data models for the JioSaavn downloader port.
///
/// These mirror the Python `jiosaavn_core.py` metadata structures but are
/// expressed as immutable Dart classes for use in a Flutter app.

/// Unescape HTML entities (e.g. `&amp;` -> `&`).
class Song {
  final String id;
  final String title;
  final String primaryArtists;
  final String album;
  final String year;
  final String? image;
  final String? encryptedMediaUrl;
  final bool hasLyrics;
  final int duration; // seconds
  final bool explicitContent;
  final String? releaseDate;
  final List<String> genres;
  final String? permaUrl;
  final String? language;
  final String? isrc;
  final Map<String, dynamic>? moreInfo;

  Song({
    required this.id,
    required this.title,
    required this.primaryArtists,
    required this.album,
    required this.year,
    this.image,
    this.encryptedMediaUrl,
    this.hasLyrics = false,
    this.duration = 0,
    this.explicitContent = false,
    this.releaseDate,
    this.genres = const [],
    this.permaUrl,
    this.language,
    this.isrc,
    this.moreInfo,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    final moreInfo = json['more_info'];
    return Song(
      id: (json['id'] ?? '').toString(),
      title: (json['song'] ?? json['title'] ?? 'Untitled').toString(),
      primaryArtists: (json['primary_artists'] ?? 'Unknown Artist').toString(),
      album: (json['album'] ?? 'Unknown Album').toString(),
      year: (json['year'] ?? '').toString(),
      image: json['image'] as String?,
      encryptedMediaUrl: json['encrypted_media_url'] as String?,
      hasLyrics: _isTrue(json['has_lyrics']),
      duration: _toInt(json['duration']) ?? 0,
      explicitContent: _isTrue(json['explicit_content']),
      releaseDate: json['release_date'] as String?,
      genres: _extractGenres(json),
      permaUrl: json['perma_url'] as String?,
      language: json['language'] as String?,
      isrc: json['isrc'] as String?,
      moreInfo: moreInfo is Map ? Map<String, dynamic>.from(moreInfo) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'song': title,
      'primary_artists': primaryArtists,
      'album': album,
      'year': year,
      'image': image,
      'encrypted_media_url': encryptedMediaUrl,
      'has_lyrics': hasLyrics,
      'duration': duration,
      'explicit_content': explicitContent,
      'release_date': releaseDate,
      'genres': genres,
      'perma_url': permaUrl,
      'language': language,
      'isrc': isrc,
      'more_info': moreInfo,
    };
  }

  static bool _isTrue(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    return {'1', 'true', 'yes'}.contains(value.toString().toLowerCase());
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  static List<String> _extractGenres(Map<String, dynamic> json) {
    final genres = <String>{};
    void add(dynamic value) {
      if (value == null) return;
      if (value is List) {
        for (final v in value) add(v);
        return;
      }
      if (value is Map) {
        for (final key in ['text', 'title', 'name', 'genre', 'music', 'value']) {
          if (value.containsKey(key)) add(value[key]);
        }
        return;
      }
      final text = value.toString().trim();
      if (text.isNotEmpty) {
        for (final part in text.split(RegExp(r'[;,/|]'))) {
          final p = part.trim();
          if (p.isNotEmpty) genres.add(p);
        }
      }
    }
    for (final key in ['genre', 'genres', 'music', 'music_genre', 'primary_genre', 'language']) {
      add(json[key]);
    }
    final more = json['more_info'];
    if (more is Map) {
      for (final key in ['genre', 'genres', 'music', 'music_genre', 'language']) {
        add(more[key]);
      }
    }
    return genres.toList();
  }
}

/// A collection (album or playlist) with its tracks.
class CollectionResult {
  final String kind; // 'album' or 'playlist'
  final String id;
  final String name;
  final List<Song> songs;
  final String? image;
  final String? year;
  final int? reportedTotal;

  CollectionResult({
    required this.kind,
    required this.id,
    required this.name,
    required this.songs,
    this.image,
    this.year,
    this.reportedTotal,
  });

  factory CollectionResult.fromJson(String kind, Map<String, dynamic> json) {
    final songsRaw = json['songs'];
    final songs = <Song>[];
    if (songsRaw is List) {
      for (final item in songsRaw) {
        if (item is Map) {
          songs.add(Song.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return CollectionResult(
      kind: kind,
      id: (json['id'] ?? '').toString(),
      name: (json['title'] ?? json['listname'] ?? 'Untitled').toString(),
      songs: songs,
      image: json['image'] as String?,
      year: json['year'] as String?,
      reportedTotal: _toInt(json['list_count']),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }
}

/// A search result item returned by the JioSaavn search API.
class SearchResult {
  final String kind; // 'song', 'album', or 'playlist'
  final String url;
  final String title;
  final String subtitle;
  final String? image; // cover art URL

  SearchResult({
    required this.kind,
    required this.url,
    required this.title,
    required this.subtitle,
    this.image,
  });
}

/// Progress of an individual download.
class DownloadProgress {
  final int position;
  final int total;
  final String title;
  final String artists;
  final String? coverUrl; // cover art URL for this track
  final String statusText; // e.g. "Fetching metadata…", "Downloading…", "Embedding cover…"
  final String metadataStatus; // e.g. "✓ Metadata embedded", "✗ Metadata not embedded"
  final bool metadataEmbedded; // whether MP4 metadata was successfully embedded
  final String? metadataError; // error message if embedding failed
  final int bytesReceived;
  final int? totalBytes;
  final double percentage; // 0.0 to 1.0
  final String speed; // e.g. "3.1MB/s"
  final DownloadStatus status;

  DownloadProgress({
    required this.position,
    required this.total,
    required this.title,
    required this.artists,
    this.coverUrl,
    this.statusText = '',
    this.metadataStatus = '',
    this.metadataEmbedded = false,
    this.metadataError,
    this.bytesReceived = 0,
    this.totalBytes,
    this.percentage = 0.0,
    this.speed = '0.0MB/s',
    required this.status,
  });
}

enum DownloadStatus {
  queued,
  downloading,
  completed,
  skipped,
  failed,
}

/// Result of a download operation.
class DownloadResult {
  final bool success;
  final String? filePath;
  final String? error;
  final String title;

  DownloadResult({
    required this.success,
    this.filePath,
    this.error,
    required this.title,
  });
}

/// Download configuration (mirrors the Python config but stored in shared_prefs).
class DownloadConfig {
  final String output;
  final String quality; // '12', '48', '96', '160', '320'
  final int timeout; // seconds
  final bool overwrite;
  final bool lyrics;
  final bool cover;
  final int workers;
  final String? genre;
  final String? template;
  final int? maxSpeed; // bytes/sec, null = unlimited
  final bool saveCoverFile;
  final bool saveLyricsFile;
  final bool noExplicit;
  final int? afterYear;
  final int? beforeYear;
  final bool cache;
  final int cacheTtl; // seconds
  final double prefetchRate;
  final int prefetchBurst;

  const DownloadConfig({
    this.output = 'Downloads',
    this.quality = '320',
    this.timeout = 30,
    this.overwrite = false,
    this.lyrics = true,
    this.cover = true,
    this.saveCoverFile = false,
    this.saveLyricsFile = false,
    this.workers = 4,
    this.genre,
    this.template,
    this.maxSpeed,
    this.noExplicit = false,
    this.afterYear,
    this.beforeYear,
    this.cache = false,
    this.cacheTtl = 86400,
    this.prefetchRate = 5.0,
    this.prefetchBurst = 3,
  });

  DownloadConfig copyWith({
    String? output,
    String? quality,
    int? timeout,
    bool? overwrite,
    bool? lyrics,
    bool? cover,
    bool? saveCoverFile,
    bool? saveLyricsFile,
    int? workers,
    String? genre,
    String? template,
    int? maxSpeed,
    bool? noExplicit,
    int? afterYear,
    int? beforeYear,
    bool? cache,
    int? cacheTtl,
    double? prefetchRate,
    int? prefetchBurst,
  }) {
    return DownloadConfig(
      output: output ?? this.output,
      quality: quality ?? this.quality,
      timeout: timeout ?? this.timeout,
      overwrite: overwrite ?? this.overwrite,
      lyrics: lyrics ?? this.lyrics,
      cover: cover ?? this.cover,
      saveCoverFile: saveCoverFile ?? this.saveCoverFile,
      saveLyricsFile: saveLyricsFile ?? this.saveLyricsFile,
      workers: workers ?? this.workers,
      genre: genre ?? this.genre,
      template: template ?? this.template,
      maxSpeed: maxSpeed ?? this.maxSpeed,
      noExplicit: noExplicit ?? this.noExplicit,
      afterYear: afterYear ?? this.afterYear,
      beforeYear: beforeYear ?? this.beforeYear,
      cache: cache ?? this.cache,
      cacheTtl: cacheTtl ?? this.cacheTtl,
      prefetchRate: prefetchRate ?? this.prefetchRate,
      prefetchBurst: prefetchBurst ?? this.prefetchBurst,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'output': output,
      'quality': quality,
      'timeout': timeout,
      'overwrite': overwrite,
      'lyrics': lyrics,
      'cover': cover,
      'save_cover_file': saveCoverFile,
      'save_lyrics_file': saveLyricsFile,
      'workers': workers,
      'genre': genre,
      'template': template,
      'max_speed': maxSpeed,
      'no_explicit': noExplicit,
      'after_year': afterYear,
      'before_year': beforeYear,
      'cache': cache,
      'cache_ttl': cacheTtl,
      'prefetch_rate': prefetchRate,
      'prefetch_burst': prefetchBurst,
    };
  }

  factory DownloadConfig.fromJson(Map<String, dynamic> json) {
    return DownloadConfig(
      output: json['output'] as String? ?? 'Downloads',
      quality: json['quality'] as String? ?? '320',
      timeout: (json['timeout'] as num?)?.toInt() ?? 30,
      overwrite: json['overwrite'] as bool? ?? false,
      lyrics: json['lyrics'] as bool? ?? true,
      cover: json['cover'] as bool? ?? true,
      saveCoverFile: json['save_cover_file'] as bool? ?? false,
      saveLyricsFile: json['save_lyrics_file'] as bool? ?? false,
      workers: (json['workers'] as num?)?.toInt() ?? 4,
      genre: json['genre'] as String?,
      template: json['template'] as String?,
      maxSpeed: (json['max_speed'] as num?)?.toInt(),
      noExplicit: json['no_explicit'] as bool? ?? false,
      afterYear: (json['after_year'] as num?)?.toInt(),
      beforeYear: (json['before_year'] as num?)?.toInt(),
      cache: json['cache'] as bool? ?? false,
      cacheTtl: (json['cache_ttl'] as num?)?.toInt() ?? 86400,
      prefetchRate: (json['prefetch_rate'] as num?)?.toDouble() ?? 5.0,
      prefetchBurst: (json['prefetch_burst'] as num?)?.toInt() ?? 3,
    );
  }
}

/// A failed download record.
class Failure {
  final String label;
  final String reason;
  final String? url;

  Failure({
    required this.label,
    required this.reason,
    this.url,
  });
}
