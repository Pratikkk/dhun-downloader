/// Basic MP4 metadata tag writer.
///
/// Port of the Python `tagger` method using `mutagen.mp4`. Dart has no
/// direct mutagen equivalent, so this writes the most common iTunes-style
/// MP4 atoms directly. It supports title, album, artist, year, genre, track
/// number, explicit rating, lyrics, and cover art.
///
/// Note: this is a best-effort implementation. For full-featured tag editing
/// across all platforms, consider using platform channels to native metadata
/// APIs (AVFoundation on iOS, MediaMetadataRetriever on Android).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'utils.dart';

/// MP4 cover art format.
enum Mp4CoverFormat { jpeg, png }

/// Detect cover art format from the first bytes.
Mp4CoverFormat? detectCoverFormat(List<int> bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return Mp4CoverFormat.jpeg;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return Mp4CoverFormat.png;
  }
  return null;
}

/// Write an MP4 atom header: `[size(4, big-endian)][type(4)]`.
Uint8List atomHeader(String type, int dataSize) {
  final size = 8 + dataSize;
  final bytes = ByteData(size);
  bytes.setInt32(0, size, Endian.big);
  bytes.setUint8(4, type.codeUnitAt(0));
  bytes.setUint8(5, type.codeUnitAt(1));
  bytes.setUint8(6, type.codeUnitAt(2));
  bytes.setUint8(7, type.codeUnitAt(3));
  return bytes.buffer.asUint8List();
}

/// Build a metadata data atom payload:
/// `[version(1)][flags(3)][language(4, "und")][data]`.
Uint8List metadataPayload(List<int> data) {
  final payload = ByteData(8 + data.length);
  payload.setUint8(0, 0); // version
  payload.setUint8(1, 0); // flags
  payload.setUint8(2, 0);
  payload.setUint8(3, 0);
  // Language code "und" (undefined).
  payload.setUint8(4, 0x55); // 'u'
  payload.setUint8(5, 0x6E); // 'n'
  payload.setUint8(6, 0x64); // 'd'
  payload.setUint8(7, 0x00);
  for (var i = 0; i < data.length; i++) {
    payload.setUint8(8 + i, data[i]);
  }
  return payload.buffer.asUint8List();
}

/// Build an MP4 data atom for a metadata item:
/// `[atom header][version(1)][flags(3)][language(4)][data]`.
Uint8List dataAtom(String type, List<int> data) {
  final payload = metadataPayload(data);
  return Uint8List.fromList([...atomHeader(type, payload.length), ...payload]);
}

/// Build a track number atom `trkn`: `[(track, total)]`.
/// Data format: [track(2 bytes BE)][total(2 bytes BE)].
Uint8List trknAtom(int track, int total) {
  final data = ByteData(8);
  data.setInt16(0, track, Endian.big);
  data.setInt16(2, total, Endian.big);
  return dataAtom('trkn', data.buffer.asUint8List());
}

/// Build a disk number atom `disk`: `[(disc, totalDiscs)]`.
Uint8List diskAtom(int disc, int totalDiscs) {
  final data = ByteData(8);
  data.setInt16(0, disc, Endian.big);
  data.setInt16(2, totalDiscs, Endian.big);
  return dataAtom('disk', data.buffer.asUint8List());
}

/// Build an explicit rating atom `rtng`: rating 4=explicit, 2=clean.
Uint8List rtngAtom(int rating) {
  return dataAtom('rtng', Uint8List.fromList([rating]));
}

/// Build a compilation flag atom `cpil`: `[1]`.
Uint8List cpilAtom() {
  return dataAtom('cpil', Uint8List.fromList([1]));
}

/// Build a cover art atom `covr`.
Uint8List covrAtom(List<int> imageBytes, Mp4CoverFormat format) {
  return dataAtom('covr', Uint8List.fromList(imageBytes));
}

/// Build a free-form string metadata atom (e.g., ©nam, ©alb, ©ART, ©day, ©gen).
Uint8List stringAtom(String type, String value) {
  final data = utf8.encode(value);
  return dataAtom(type, data);
}

/// Build a custom iTunes metadata atom `----:com.apple.iTunes:NAME`.
/// Format: `[version(1)][flags(3)][language(4)][name(0-terminated)][data]`.
Uint8List itunesAtom(String name, List<int> data) {
  final nameBytes = utf8.encode(name);
  final payload = ByteData(8 + nameBytes.length + 1 + data.length);
  payload.setUint8(0, 0); // version
  payload.setUint8(1, 0);
  payload.setUint8(2, 0);
  payload.setUint8(3, 0);
  payload.setUint8(4, 0x55); // 'u'
  payload.setUint8(5, 0x6E); // 'n'
  payload.setUint8(6, 0x64); // 'd'
  payload.setUint8(7, 0x00);
  var offset = 8;
  for (var i = 0; i < nameBytes.length; i++) {
    payload.setUint8(offset + i, nameBytes[i]);
  }
  offset += nameBytes.length;
  payload.setUint8(offset++, 0); // null terminator
  for (var i = 0; i < data.length; i++) {
    payload.setUint8(offset + i, data[i]);
  }
  return Uint8List.fromList([...atomHeader('----', payload.lengthInBytes), ...payload.buffer.asUint8List()]);
}

/// MP4 atom reader helpers.
class Mp4Atom {
  final String type;

  /// Find the first atom of a given type in a list, or null if not found.
  static Mp4Atom? findByType(List<Mp4Atom> atoms, String type) {
    for (final a in atoms) {
      if (a.type == type) return a;
    }
    return null;
  }
  final int offset;
  final int size;
  final int dataOffset;
  final int dataSize;

  Mp4Atom({
    required this.type,
    required this.offset,
    required this.size,
    required this.dataOffset,
    required this.dataSize,
  });

  /// Read all top-level atoms from a byte buffer.
  static List<Mp4Atom> readTopLevel(Uint8List bytes) {
    final atoms = <Mp4Atom>[];
    var offset = 0;
    while (offset + 8 <= bytes.length) {
      final size = _readInt32BE(bytes, offset);
      if (size < 8) break;
      final type = _readType(bytes, offset + 4);
      atoms.add(Mp4Atom(
        type: type,
        offset: offset,
        size: size,
        dataOffset: offset + 8,
        dataSize: size - 8,
      ));
      offset += size;
      if (size == 0) break;
    }
    return atoms;
  }

  /// Find a child atom of a given type within this atom's data range.
  Mp4Atom? findChild(Uint8List bytes, String childType) {
    var offset = dataOffset;
    final end = offset + dataSize;
    while (offset + 8 <= end) {
      final size = _readInt32BE(bytes, offset);
      if (size < 8) break;
      final type = _readType(bytes, offset + 4);
      if (type == childType) {
        return Mp4Atom(
          type: type,
          offset: offset,
          size: size,
          dataOffset: offset + 8,
          dataSize: size - 8,
        );
      }
      offset += size;
      if (size == 0) break;
    }
    return null;
  }

  /// Read all child atoms of a given type within this atom's data range.
  List<Mp4Atom> findAllChildren(Uint8List bytes, String childType) {
    final result = <Mp4Atom>[];
    var offset = dataOffset;
    final end = offset + dataSize;
    while (offset + 8 <= end) {
      final size = _readInt32BE(bytes, offset);
      if (size < 8) break;
      final type = _readType(bytes, offset + 4);
      if (type == childType) {
        result.add(Mp4Atom(
          type: type,
          offset: offset,
          size: size,
          dataOffset: offset + 8,
          dataSize: size - 8,
        ));
      }
      offset += size;
      if (size == 0) break;
    }
    return result;
  }

  static int _readInt32BE(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        ((bytes[offset + 1] & 0xFF) << 16) |
        ((bytes[offset + 2] & 0xFF) << 8) |
        (bytes[offset + 3] & 0xFF);
  }

  static String _readType(Uint8List bytes, int offset) {
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }
}

/// Result of tagging a file.
class TagResult {
  final bool success;
  final String? error;
  TagResult({required this.success, this.error});
}

/// Tag an MP4 file with metadata from a JioSaavn song.
///
/// Mirrors the Python `tagger` method. Writes title, album, artist, year,
/// genre, track number, explicit rating, lyrics, cover art, and custom
/// iTunes fields (JioSaavn ID, composer, lyricist, singers, etc.).
Future<TagResult> tagMp4({
  required String filePath,
  required Map<String, dynamic> song,
  String albumArtist = '',
  int trackPos = 1,
  int totalTracks = 1,
  List<int>? artwork,
  String? songId,
}) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) {
      return TagResult(success: false, error: 'File not found: $filePath');
    }
    final bytes = await file.readAsBytes();

    final topLevel = Mp4Atom.readTopLevel(bytes);
    final moov = Mp4Atom.findByType(topLevel, 'moov');
    if (moov == null) {
      return TagResult(success: false, error: 'No moov atom found (not a valid MP4)');
    }

    final moovBytes = Uint8List.fromList(bytes.sublist(moov.dataOffset, moov.dataOffset + moov.dataSize));
    final moovAtoms = Mp4Atom.readTopLevel(moovBytes);
    final udta = Mp4Atom.findByType(moovAtoms, 'udta');
    if (udta == null) {
      return TagResult(success: false, error: 'No udta atom found');
    }

    final udtaBytes = Uint8List.fromList(bytes.sublist(udta.dataOffset, udta.dataOffset + udta.dataSize));
    final udtaAtoms = Mp4Atom.readTopLevel(udtaBytes);
    final meta = Mp4Atom.findByType(udtaAtoms, 'meta');
    if (meta == null) {
      return TagResult(success: false, error: 'No meta atom found');
    }

    final metaBytes = Uint8List.fromList(bytes.sublist(meta.dataOffset, meta.dataOffset + meta.dataSize));
    final metaAtoms = Mp4Atom.readTopLevel(metaBytes);
    final ilst = Mp4Atom.findByType(metaAtoms, 'ilst');
    if (ilst == null) {
      return TagResult(success: false, error: 'No ilst atom found');
    }

    // Build all metadata atoms.
    final newMetadataAtoms = <Uint8List>[];

    // Title
    final title = cleanText(song['song'] ?? song['title'] ?? '');
    if (title.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('\xa9nam', title));
    }

    // Album / Release Title
    final album = cleanText(song['album'] ?? '');
    if (album.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('\xa9alb', album));
    }

    // Artist
    final artists =
        cleanText(albumArtist.isNotEmpty ? albumArtist : song['primary_artists'] ?? '');
    if (artists.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('\xa9ART', artists));
    }

    // Album Artist
    final albumArtistValue =
        cleanText(song['album_artist'] ?? song['primary_artists'] ?? '');
    if (albumArtistValue.isNotEmpty && albumArtistValue != artists) {
      newMetadataAtoms.add(itunesAtom('Album Artist', utf8.encode(albumArtistValue)));
    }

    // Year / Release Date
    final release = normalizeDate(song['release_date'] ?? song['year']);
    if (release != null && release.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('\xa9day', release));
    }

    // Genre / Subgenre
    final genre = trackGenres(Map<String, dynamic>.from(song));
    if (genre.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('\xa9gen', genre.join('; ')));
    }

    // Track number
    newMetadataAtoms.add(trknAtom(trackPos, totalTracks));

    // Disc number
    final discNumber = song['disc_number'] ?? song['disc'];
    final totalDiscs = song['total_discs'];
    if (discNumber != null && discNumber != '' && discNumber != 0) {
      final discNum = discNumber is int ? discNumber : int.tryParse(discNumber.toString()) ?? 1;
      final total = totalDiscs != null && totalDiscs != '' && totalDiscs != 0
          ? (totalDiscs is int ? totalDiscs : int.tryParse(totalDiscs.toString()) ?? 1)
          : 1;
      newMetadataAtoms.add(diskAtom(discNum, total));
    }

    // Explicit rating
    final explicit = isTrue(song['explicit_content']);
    newMetadataAtoms.add(rtngAtom(explicit ? 4 : 2));

    // JioSaavn ID
    final id = cleanText(song['id'] ?? songId ?? '');
    if (id.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('JioSaavn ID', utf8.encode(id)));
    }

    // Composers / Songwriters
    final composers =
        metadataList(Map<String, dynamic>.from(song), ['music', 'composer', 'composers', 'music_by']);
    if (composers.isNotEmpty) {
      final composerStr = composers.join(', ');
      newMetadataAtoms.add(stringAtom('\xa9wrt', composerStr));
      newMetadataAtoms.add(itunesAtom('COMPOSER', utf8.encode(composerStr)));
      newMetadataAtoms.add(itunesAtom('Songwriter', utf8.encode(composerStr)));
    }

    // Lyricists
    final lyricists =
        metadataList(Map<String, dynamic>.from(song), ['lyricist', 'lyricists', 'lyrics_by']);
    if (lyricists.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('LYRICIST', utf8.encode(lyricists.join(', '))));
    }

    // Singers
    final singers =
        metadataList(Map<String, dynamic>.from(song), ['singers', 'singer']);
    if (singers.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('Singers', utf8.encode(singers.join(', '))));
    }

    // Featured artists
    final featured =
        metadataList(Map<String, dynamic>.from(song), ['featured_artists']);
    if (featured.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('Featured artists', utf8.encode(featured.join(', '))));
    }

    // Starring
    final starring =
        metadataList(Map<String, dynamic>.from(song), ['starring']);
    if (starring.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('Starring', utf8.encode(starring.join(', '))));
    }

    // Record label / Publisher
    final labelValues =
        metadataList(Map<String, dynamic>.from(song), ['label', 'label_name', 'record_label', 'publisher']);
    if (labelValues.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('Record label', utf8.encode(labelValues.join(', '))));
      newMetadataAtoms.add(itunesAtom('Publisher', utf8.encode(labelValues.join(', '))));
    }

    // Copyright
    final copyright = cleanText(song['copyright_text'] ?? '');
    if (copyright.isNotEmpty) {
      newMetadataAtoms.add(stringAtom('cprt', copyright));
    }

    // Language
    final languageValues =
        metadataList(Map<String, dynamic>.from(song), ['language']);
    if (languageValues.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('Language', utf8.encode(languageValues.join(', '))));
    }

    // ISRC
    final isrc = cleanText(song['isrc'] ?? '');
    if (isrc.isNotEmpty) {
      newMetadataAtoms.add(itunesAtom('ISRC', utf8.encode(isrc)));
    }

    // Duration (in seconds)
    final duration = song['duration'];
    if (duration != null && duration != 0) {
      final dur = duration is int ? duration : int.tryParse(duration.toString()) ?? 0;
      if (dur > 0) {
        newMetadataAtoms.add(itunesAtom('Duration', utf8.encode(dur.toString())));
      }
    }

    // Compilation flag
    final compilation = song['compilation'] ?? song['is_compilation'];
    if (isTrue(compilation)) {
      newMetadataAtoms.add(cpilAtom());
    }

    // Lyrics
    final hasLyrics = isTrue(song['has_lyrics']) && song['id'] != null;
    if (hasLyrics) {
      final lyricsText = song['lyrics_text'] as String?;
      final lrcText = song['lrc_text'] as String?;
      final embeddedLyrics = lyricsText ??
          (lrcText != null ? lrcText.replaceAll(RegExp(r'\[[^\]]+\]\s*'), '').trim() : null);
      if (embeddedLyrics != null && embeddedLyrics.isNotEmpty) {
        newMetadataAtoms.add(stringAtom('\xa9lyr', embeddedLyrics));
      }
    }

    // Cover art
    if (artwork != null && artwork.isNotEmpty) {
      final format = detectCoverFormat(artwork);
      if (format != null) {
        newMetadataAtoms.add(covrAtom(artwork, format));
      }
    }

    // If nothing to write, done.
    if (newMetadataAtoms.isEmpty) {
      return TagResult(success: true);
    }

    // Build new ilst atom content.
    // Read existing ilst atoms, keep non-data atoms, replace data atoms with our new ones.
    final ilstBytes = Uint8List.fromList(bytes.sublist(ilst.dataOffset, ilst.dataOffset + ilst.dataSize));
    final ilstAtoms = Mp4Atom.readTopLevel(ilstBytes);

    final newIlstContent = <Uint8List>[];
    for (final child in ilstAtoms) {
      // Skip existing data atoms; we'll replace them all.
      final type = child.type;
      if (type == '\xa9nam' || type == '\xa9alb' || type == '\xa9ART' || type == '\xa9day' ||
          type == '\xa9gen' || type == 'trkn' || type == 'rtng' || type == '----' ||
          type == '\xa9wrt' || type == '\xa9lyr' || type == 'covr' || type == 'disk' ||
          type == 'cpil') {
        continue; // replaced by new atoms
      }
      newIlstContent.add(
        ilstBytes.sublist(child.offset - ilst.dataOffset, child.offset - ilst.dataOffset + child.size),
      );
    }
    newIlstContent.addAll(newMetadataAtoms);

    // Build new ilst atom.
    var newIlstSize = 8;
    for (final a in newIlstContent) {
      newIlstSize += a.length;
    }
    final newIlstBytes = Uint8List.fromList([
      ...atomHeader('ilst', newIlstSize - 8),
      ...newIlstContent.expand((a) => a),
    ]);

    // Reconstruct meta atom: replace old ilst with new one.
    final newMetaContent = <Uint8List>[];
    var ilstReplaced = false;
    for (final child in metaAtoms) {
      if (child.type == 'ilst') {
        newMetaContent.add(newIlstBytes);
        ilstReplaced = true;
      } else {
        newMetaContent.add(
          metaBytes.sublist(child.offset - meta.dataOffset, child.offset - meta.dataOffset + child.size),
        );
      }
    }
    if (!ilstReplaced) {
      newMetaContent.add(newIlstBytes);
    }

    var newMetaSize = 8;
    for (final a in newMetaContent) {
      newMetaSize += a.length;
    }
    final newMetaBytes = Uint8List.fromList([
      ...atomHeader('meta', newMetaSize - 8),
      ...newMetaContent.expand((a) => a),
    ]);

    // Reconstruct udta atom: replace old meta with new one.
    final newUdtaContent = <Uint8List>[];
    var metaReplaced = false;
    for (final child in udtaAtoms) {
      if (child.type == 'meta') {
        newUdtaContent.add(newMetaBytes);
        metaReplaced = true;
      } else {
        newUdtaContent.add(
          udtaBytes.sublist(child.offset - udta.dataOffset, child.offset - udta.dataOffset + child.size),
        );
      }
    }
    if (!metaReplaced) {
      newUdtaContent.add(newMetaBytes);
    }

    var newUdtaSize = 8;
    for (final a in newUdtaContent) {
      newUdtaSize += a.length;
    }
    final newUdtaBytes = Uint8List.fromList([
      ...atomHeader('udta', newUdtaSize - 8),
      ...newUdtaContent.expand((a) => a),
    ]);

    // Reconstruct moov atom: replace old udta with new one.
    final newMoovContent = <Uint8List>[];
    var udtaReplaced = false;
    for (final child in moovAtoms) {
      if (child.type == 'udta') {
        newMoovContent.add(newUdtaBytes);
        udtaReplaced = true;
      } else {
        newMoovContent.add(
          moovBytes.sublist(child.offset - moov.dataOffset, child.offset - moov.dataOffset + child.size),
        );
      }
    }
    if (!udtaReplaced) {
      newMoovContent.add(newUdtaBytes);
    }

    var newMoovSize = 8;
    for (final a in newMoovContent) {
      newMoovSize += a.length;
    }
    final newMoovBytes = Uint8List.fromList([
      ...atomHeader('moov', newMoovSize - 8),
      ...newMoovContent.expand((a) => a),
    ]);

    // Reconstruct the full file: replace old moov with new moov.
    final newFileBytes = <int>[];
    var moovWritten = false;
    for (final atom in topLevel) {
      if (atom.type == 'moov') {
        newFileBytes.addAll(newMoovBytes);
        moovWritten = true;
      } else {
        newFileBytes.addAll(bytes.sublist(atom.offset, atom.offset + atom.size));
      }
    }
    if (!moovWritten) {
      newFileBytes.addAll(newMoovBytes);
    }

    // Append any data after moov (e.g., mdat, free).
    final moovAtom = Mp4Atom.findByType(topLevel, 'moov');
    if (moovAtom != null) {
      final afterMoov = moovAtom.offset + moovAtom.size;
      if (afterMoov < bytes.length) {
        newFileBytes.addAll(bytes.sublist(afterMoov));
      }
    }

    await file.writeAsBytes(Uint8List.fromList(newFileBytes));
    return TagResult(success: true);
  } catch (exc) {
    return TagResult(success: false, error: exc.toString());
  }
}

/// Read the JioSaavn ID custom atom from an MP4 file, if present.
Future<String?> readJioSaavnId(String filePath) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final topLevel = Mp4Atom.readTopLevel(bytes);
    final moov = Mp4Atom.findByType(topLevel, 'moov');
    if (moov == null) return null;
    final moovBytes = Uint8List.fromList(bytes.sublist(moov.dataOffset, moov.dataOffset + moov.dataSize));
    final moovAtoms = Mp4Atom.readTopLevel(moovBytes);
    final udta = Mp4Atom.findByType(moovAtoms, 'udta');
    if (udta == null) return null;
    final udtaBytes = Uint8List.fromList(bytes.sublist(udta.dataOffset, udta.dataOffset + udta.dataSize));
    final udtaAtoms = Mp4Atom.readTopLevel(udtaBytes);
    final meta = Mp4Atom.findByType(udtaAtoms, 'meta');
    if (meta == null) return null;
    final metaBytes = Uint8List.fromList(bytes.sublist(meta.dataOffset, meta.dataOffset + meta.dataSize));
    final metaAtoms = Mp4Atom.readTopLevel(metaBytes);
    final ilst = Mp4Atom.findByType(metaAtoms, 'ilst');
    if (ilst == null) return null;
    final ilstBytes = Uint8List.fromList(bytes.sublist(ilst.dataOffset, ilst.dataOffset + ilst.dataSize));
    final ilstAtoms = Mp4Atom.readTopLevel(ilstBytes);
    for (final child in ilstAtoms) {
      if (child.type == '----') {
        final childBytes = ilstBytes.sublist(child.offset - ilst.dataOffset, child.offset - ilst.dataOffset + child.size);
        if (childBytes.length > 12) {
          final nameStart = 8;
          var nameEnd = nameStart;
          while (nameEnd < childBytes.length && childBytes[nameEnd] != 0) nameEnd++;
          final name = utf8.decode(childBytes.sublist(nameStart, nameEnd));
          if (name == 'JioSaavn ID') {
            final dataStart = nameEnd + 1;
            if (dataStart < childBytes.length) {
              return utf8.decode(childBytes.sublist(dataStart)).trim();
            }
          }
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Write a sidecar JSON file next to the audio file containing ALL available
/// metadata, including fields that cannot be stored in MP4 atoms
/// (e.g. BPM, Musical Key, Mood/Tags, ISWC, UPC/EAN, Producer).
///
/// Returns the path to the written JSON file, or null on failure.
Future<String?> writeSidecarJson({
  required String audioFilePath,
  required Map<String, dynamic> song,
  String albumArtist = '',
  int trackPos = 1,
  int totalTracks = 1,
  String? songId,
  List<int>? artworkBytes,
}) async {
  try {
    final audioFile = File(audioFilePath);
    if (!await audioFile.exists()) return null;

    final sidecarPath = audioFilePath.replaceFirst(RegExp(r'\.m4a$'), '.json');
    final sidecarFile = File(sidecarPath);

    final explicit = isTrue(song['explicit_content']);
    final hasLyrics = isTrue(song['has_lyrics']) && song['id'] != null;
    final duration = song['duration'];
    final dur = duration is int ? duration : int.tryParse(duration.toString()) ?? 0;
    final discNumber = song['disc_number'] ?? song['disc'];
    final discNum = discNumber != null && discNumber != '' && discNumber != 0
        ? (discNumber is int ? discNumber : int.tryParse(discNumber.toString()) ?? 1)
        : null;

    final coverUrl = song['image'] as String?;
    final highResCover = coverUrl != null ? coverUrl.replaceAll('150x150', '500x500') : null;

    final metadata = {
      // Core identification
      'title': cleanText(song['song'] ?? song['title'] ?? ''),
      'artist': cleanText(albumArtist.isNotEmpty ? albumArtist : song['primary_artists'] ?? ''),
      'featured_artist': metadataList(Map<String, dynamic>.from(song), ['featured_artists']).join(', '),
      'album_release_title': cleanText(song['album'] ?? ''),
      'album_artist': cleanText(song['album_artist'] ?? song['primary_artists'] ?? ''),
      'track_number': trackPos,
      'disc_number': discNum,
      'release_year_date': normalizeDate(song['release_date'] ?? song['year']),
      'genre_subgenre': trackGenres(Map<String, dynamic>.from(song)),
      'composer_songwriter': metadataList(Map<String, dynamic>.from(song), ['music', 'composer', 'composers', 'music_by']).join(', '),
      'lyricist': metadataList(Map<String, dynamic>.from(song), ['lyricist', 'lyricists', 'lyrics_by']).join(', '),
      'producer': null, // Not available from JioSaavn API
      'record_label': metadataList(Map<String, dynamic>.from(song), ['label', 'label_name', 'record_label', 'publisher']).join(', '),
      'language': metadataList(Map<String, dynamic>.from(song), ['language']).join(', '),
      'explicit_content': explicit ? 'Yes' : 'No',
      'bpm_tempo': null, // Not available from JioSaavn API
      'musical_key': null, // Not available from JioSaavn API
      'mood_tags': null, // Not available from JioSaavn API
      'isrc': cleanText(song['isrc'] ?? ''),
      'iswc': null, // Not available from JioSaavn API
      'upc_ean': null, // Not available from JioSaavn API
      'copyright_publisher': cleanText(song['copyright_text'] ?? ''),
      'duration_seconds': dur > 0 ? dur : null,

      // Identifiers
      'jiosaavn_id': cleanText(song['id'] ?? songId ?? ''),
      'encrypted_media_url': song['encrypted_media_url'],
      'encrypted_drm_media_url': song['encrypted_drm_media_url'],
      'media_preview_url': song['media_preview_url'],
      'perma_url': song['perma_url'],
      'album_url': song['album_url'],

      // Media info
      'cover_url_high_res': highResCover,
      'cover_embedded': artworkBytes != null && artworkBytes.isNotEmpty,
      'has_lyrics': hasLyrics,

      // Raw API data (for reference)
      'raw_api_data': song,
    };

    await sidecarFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      encoding: utf8,
    );

    return sidecarPath;
  } catch (exc) {
    return null;
  }
}
