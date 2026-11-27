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

/// Check if bytes start with an ftyp atom (MP4 container).
bool _isMp4Container(List<int> bytes) {
  if (bytes.length < 8) return false;
  final type = String.fromCharCodes(bytes.sublist(4, 8));
  return type == 'ftyp';
}

/// Build a full MP4 atom: header + version(1) + flags(3) + data.
Uint8List _fullAtom(String type, int version, int flags, List<int> data) {
  final payload = ByteData(8 + data.length);
  payload.setUint8(0, version);
  payload.setUint8(1, (flags >> 16) & 0xFF);
  payload.setUint8(2, (flags >> 8) & 0xFF);
  payload.setUint8(3, flags & 0xFF);
  for (var i = 0; i < data.length; i++) {
    payload.setUint8(8 + i, data[i]);
  }
  return Uint8List.fromList([...atomHeader(type, payload.lengthInBytes), ...payload.buffer.asUint8List()]);
}

/// Build an ftyp atom.
Uint8List _buildFtyp() {
  final brands = <int>[];
  brands.addAll(utf8.encode('isom')); // major_brand
  brands.addAll([0, 0, 0, 0]); // minor_version
  for (final b in ['isom', 'iso2', 'mp41', 'mp42']) {
    brands.addAll(utf8.encode(b)); // compatible_brands
  }
  return Uint8List.fromList([...atomHeader('ftyp', brands.length), ...brands]);
}

/// Build an mvhd (movie header) atom.
Uint8List _buildMvhd(int timescale, int duration) {
  final data = ByteData(4 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4);
  var offset = 0;
  data.setInt32(offset, 0, Endian.big); offset += 4; // creation_time
  data.setInt32(offset, 0, Endian.big); offset += 4; // modification_time
  data.setInt32(offset, timescale, Endian.big); offset += 4; // timescale
  data.setInt32(offset, duration, Endian.big); offset += 4; // duration
  data.setInt32(offset, 0x00010000, Endian.big); offset += 4; // rate = 1.0
  data.setInt16(offset, 0x0100, Endian.big); offset += 2; // volume = 1.0
  data.setInt16(offset, 0, Endian.big); offset += 2; // reserved
  data.setInt32(offset, 0, Endian.big); offset += 4; // reserved
  data.setInt32(offset, 0, Endian.big); offset += 4; // reserved
  // matrix (9 int32)
  data.setInt32(offset, 0x00010000, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0x00010000, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0x40000000, Endian.big); offset += 4;
  // pre_defined (6 uint32 = 0)
  for (var i = 0; i < 6; i++) { data.setInt32(offset, 0, Endian.big); offset += 4; }
  return _fullAtom('mvhd', 0, 0, Uint8List.fromList(data.buffer.asUint8List().sublist(0, offset)));
}

/// Build a tkhd (track header) atom.
Uint8List _buildTkhd(int trackId, int duration) {
  final data = ByteData(4 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4);
  var offset = 0;
  data.setInt32(offset, 0, Endian.big); offset += 4; // creation_time
  data.setInt32(offset, 0, Endian.big); offset += 4; // modification_time
  data.setInt32(offset, trackId, Endian.big); offset += 4; // track_ID
  data.setInt32(offset, 0, Endian.big); offset += 4; // reserved
  data.setInt32(offset, duration, Endian.big); offset += 4; // duration
  data.setInt32(offset, 0, Endian.big); offset += 4; // reserved
  data.setInt16(offset, 0, Endian.big); offset += 2; // layer
  data.setInt16(offset, 0, Endian.big); offset += 2; // alternate_group
  data.setInt16(offset, 0x0100, Endian.big); offset += 2; // volume = 1.0
  data.setInt16(offset, 0, Endian.big); offset += 2; // reserved
  // matrix (9 int32)
  data.setInt32(offset, 0x00010000, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0x00010000, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0, Endian.big); offset += 4;
  data.setInt32(offset, 0x40000000, Endian.big); offset += 4;
  data.setInt16(offset, 0, Endian.big); offset += 2; // width = 0
  data.setInt16(offset, 0, Endian.big); offset += 2;
  data.setInt16(offset, 0, Endian.big); offset += 2; // height = 0
  data.setInt16(offset, 0, Endian.big); offset += 2;
  return _fullAtom('tkhd', 0, 0x00000007, Uint8List.fromList(data.buffer.asUint8List().sublist(0, offset)));
}

/// Build an mdhd (media header) atom.
Uint8List _buildMdhd(int timescale, int duration) {
  final data = ByteData(4 + 4 + 4 + 4 + 2 + 2 + 2);
  var offset = 0;
  data.setInt32(offset, 0, Endian.big); offset += 4; // creation_time
  data.setInt32(offset, 0, Endian.big); offset += 4; // modification_time
  data.setInt32(offset, timescale, Endian.big); offset += 4; // timescale
  data.setInt32(offset, duration, Endian.big); offset += 4; // duration
  data.setInt16(offset, 0x556E, Endian.big); offset += 2; // language = 'und' (packed)
  data.setInt16(offset, 0, Endian.big); offset += 2; // quality = 0
  return _fullAtom('mdhd', 0, 0, Uint8List.fromList(data.buffer.asUint8List().sublist(0, offset)));
}

/// Build an hdlr (handler reference) atom.
Uint8List _buildHdlr(String componentType, String componentSubtype, String name) {
  final nameBytes = utf8.encode(name);
  final data = ByteData(4 + 4 + 4 + 4 + 4 + nameBytes.length + 1);
  var offset = 0;
  data.setInt32(offset, 0, Endian.big); offset += 4; // component_type
  data.setInt32(offset, 0, Endian.big); offset += 4; // component_subtype
  data.setInt32(offset, 0, Endian.big); offset += 4; // component_manufacturer
  data.setInt32(offset, 0, Endian.big); offset += 4; // component_flags
  data.setInt32(offset, 0, Endian.big); offset += 4; // component_flags_mask
  for (var i = 0; i < nameBytes.length; i++) {
    data.setUint8(offset + i, nameBytes[i]);
  }
  offset += nameBytes.length;
  data.setUint8(offset++, 0); // null terminator
  return _fullAtom('hdlr', 0, 0, Uint8List.fromList(data.buffer.asUint8List().sublist(0, offset)));
}

/// Build a dref (data reference) atom inside dinf.
Uint8List _buildDref() {
  // Single url entry with self-reference flag
  final entry = <int>[];
  entry.addAll([0, 0, 0, 1]); // entry_size, entry_type='url '
  entry.addAll(utf8.encode('url '));
  entry.addAll([0x00, 0x00, 0x00, 0x01]); // flags = self-reference
  final data = ByteData(4 + entry.length);
  data.setInt32(0, entry.length, Endian.big); // entry_count = 1
  for (var i = 0; i < entry.length; i++) {
    data.setUint8(4 + i, entry[i]);
  }
  return _fullAtom('dref', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Build a dinf (data information) atom.
Uint8List _buildDinf() {
  final dref = _buildDref();
  // dinf contains dref
  return Uint8List.fromList([...atomHeader('dinf', dref.length), ...dref]);
}

/// Build an stsd (sample description) atom for AAC.
Uint8List _buildStsd(int sampleRate, int channels) {
  // mp4a entry
  final mp4aData = <int>[];
  mp4aData.addAll([0, 0, 0, 0]); // reserved (6 bytes) - first 4
  mp4aData.addAll([0, 0]); // reserved (2 bytes)
  mp4aData.addAll([1, 0]); // data_reference_index
  mp4aData.addAll([0, 0]); // version
  mp4aData.addAll([0, 0]); // revision
  mp4aData.addAll([0, 0, 0, 0]); // vendor
  mp4aData.addAll([channels, 0]); // channel_count
  mp4aData.addAll([16, 0]); // bits_per_sample = 16
  mp4aData.addAll([0, 0]); // reserved
  mp4aData.addAll([sampleRate >> 8, sampleRate & 0xFF]); // sample_rate (fixed point 16.16, but we store as integer>>8)
  
  // esds (Elementary Stream Descriptor)
  final esds = <int>[];
  // ES descriptor
  esds.addAll([0x03, 0x11 + 17]); // tag=0x03, length
  esds.addAll([0x00, 0x01]); // ES_ID
  esds.addAll([0x00, 0x00]); // stream_priority, flags
  // DecoderConfig descriptor
  esds.addAll([0x04, 0x0F + 2]); // tag=0x04, length
  esds.addAll([0x40]); // object_type_indication (AAC LC = 0x40)
  esds.addAll([0xEC]); // stream_type=5 (audio), upstream=0, reserved
  esds.addAll([0x00, 0x00, 0x00]); // buffer_size_db
  esds.addAll([0x00, 0x1F, 0x40, 0x00]); // max_bitrate, avg_bitrate (approx)
  // DecoderSpecificInfo
  esds.addAll([0x05, 0x02]); // tag=0x05, length=2
  // AAC specific config: sampling frequency index + channel configuration
  int samplingIndex;
  switch (sampleRate) {
    case 96000: samplingIndex = 0; break;
    case 88200: samplingIndex = 1; break;
    case 64000: samplingIndex = 2; break;
    case 48000: samplingIndex = 3; break;
    case 44100: samplingIndex = 4; break;
    case 32000: samplingIndex = 5; break;
    case 24000: samplingIndex = 6; break;
    case 22050: samplingIndex = 7; break;
    case 16000: samplingIndex = 8; break;
    case 12000: samplingIndex = 9; break;
    case 11025: samplingIndex = 10; break;
    case 8000: samplingIndex = 11; break;
    default: samplingIndex = 4; break; // 44100
  }
  int configByte = (samplingIndex << 3) | (channels >> 1);
  esds.addAll([configByte, (channels << 7) & 0xFF]);

  final stsdData = <int>[];
  stsdData.addAll(utf8.encode('mp4a')); // format
  stsdData.addAll(mp4aData);
  stsdData.addAll(esds);

  final data = ByteData(4 + stsdData.length);
  data.setInt32(0, 1, Endian.big); // entry_count = 1
  for (var i = 0; i < stsdData.length; i++) {
    data.setUint8(4 + i, stsdData[i]);
  }
  return _fullAtom('stsd', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Build stts (time-to-sample) atom.
Uint8List _buildStts(int sampleCount, int sampleDuration) {
  final data = ByteData(4 + 8);
  data.setInt32(0, 1, Endian.big); // entry_count
  data.setInt32(4, sampleCount, Endian.big); // sample_count
  data.setInt32(8, sampleDuration, Endian.big); // sample_duration
  return _fullAtom('stts', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Build stsc (sample-to-chunk) atom.
Uint8List _buildStsc() {
  final data = ByteData(4 + 12);
  data.setInt32(0, 1, Endian.big); // entry_count
  data.setInt32(4, 1, Endian.big); // first_chunk
  data.setInt32(8, 1, Endian.big); // samples_per_chunk
  data.setInt32(12, 1, Endian.big); // sample_description_id
  return _fullAtom('stsc', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Build stsz (sample size) atom.
Uint8List _buildStsz(int sampleSize) {
  final data = ByteData(4 + 4 + 4);
  data.setInt32(0, sampleSize, Endian.big); // sample_size (0 = variable)
  data.setInt32(4, 1, Endian.big); // sample_count
  data.setInt32(8, sampleSize, Endian.big); // first entry
  return _fullAtom('stsz', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Build stco (chunk offset) atom.
Uint8List _buildStco(int offset) {
  final data = ByteData(4 + 4);
  data.setInt32(0, 1, Endian.big); // entry_count
  data.setInt32(4, offset, Endian.big); // chunk_offset
  return _fullAtom('stco', 0, 0, Uint8List.fromList(data.buffer.asUint8List()));
}

/// Write an MP4 atom header: `[size(4, big-endian)][type(4)]`.
Uint8List _buildTrak(int trackId, int duration, int timescale, int sampleRate,
    int channels, int mdatOffset, int aacSize) {
  final tkhd = _buildTkhd(trackId, duration);
  
  final stsd = _buildStsd(sampleRate, channels);
  final stts = _buildStts(1, duration); // 1 sample, duration in media timescale units
  final stsc = _buildStsc();
  final stsz = _buildStsz(aacSize);
  final stco = _buildStco(mdatOffset);
  
  // Build stbl: stsd + stts + stsc + stsz + stco
  final stblParts = <Uint8List>[stsd, stts, stsc, stsz, stco];
  var stblSize = 8;
  for (final p in stblParts) stblSize += p.length;
  final stbl = Uint8List.fromList([...atomHeader('stbl', stblSize - 8), ...stblParts.expand((a) => a)]);
  
  final mdhd = _buildMdhd(timescale, duration);
  final hdlr = _buildHdlr('soun', 'mp4a', 'SoundHandler');
  final dinf = _buildDinf();
  
  // Build mdia: mdhd + hdlr + minf + dinf
  final minfParts = <Uint8List>[dinf, stbl];
  var minfSize = 8;
  for (final p in minfParts) minfSize += p.length;
  final minf = Uint8List.fromList([...atomHeader('minf', minfSize - 8), ...minfParts.expand((a) => a)]);
  
  final mdiaParts = <Uint8List>[mdhd, hdlr, minf];
  var mdiaSize = 8;
  for (final p in mdiaParts) mdiaSize += p.length;
  final mdia = Uint8List.fromList([...atomHeader('mdia', mdiaSize - 8), ...mdiaParts.expand((a) => a)]);
  
  // Build trak: tkhd + mdia
  final trakParts = <Uint8List>[tkhd, mdia];
  var trakSize = 8;
  for (final p in trakParts) trakSize += p.length;
  return Uint8List.fromList([...atomHeader('trak', trakSize - 8), ...trakParts.expand((a) => a)]);
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
  return Uint8List.fromList([...atomHeader(type, payload.lengthInBytes), ...payload.buffer.asUint8List()]);
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

    // Extract audio data from the file
    List<int> audioData;
    if (_isMp4Container(bytes)) {
      // File is MP4 container - extract mdat audio data
      final topLevel = Mp4Atom.readTopLevel(bytes);
      final mdat = Mp4Atom.findByType(topLevel, 'mdat');
      if (mdat == null) {
        return TagResult(success: false, error: 'No mdat atom found (no audio data)');
      }
      audioData = Uint8List.fromList(bytes.sublist(mdat.dataOffset, mdat.dataOffset + mdat.dataSize));
    } else {
      // Raw AAC audio
      audioData = bytes;
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
    if (discNumber != null && discNumber != '' && discNumber != 0) {
      final discNum = discNumber is int ? discNumber : int.tryParse(discNumber.toString()) ?? 1;
      newMetadataAtoms.add(diskAtom(discNum, 1));
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

    // Calculate duration in milliseconds for MP4
    final durationMs = song['duration'] != null
        ? ((song['duration'] is int ? song['duration'] : int.tryParse(song['duration'].toString()) ?? 0) * 1000)
        : 0;

    // Build complete MP4: ftyp + moov + mdat
    final ftyp = _buildFtyp();

    // Build ilst with metadata
    var ilstSize = 8;
    for (final a in newMetadataAtoms) {
      ilstSize += a.length;
    }
    final ilst = Uint8List.fromList([
      ...atomHeader('ilst', ilstSize - 8),
      ...newMetadataAtoms.expand((a) => a),
    ]);

    // Build meta
    final metaData = <int>[];
    metaData.addAll([0, 0, 0, 0]); // version + flags
    metaData.addAll(utf8.encode('und')); // handler_type
    metaData.addAll(ilst);
    final metaSize = 8 + metaData.length;
    final meta = Uint8List.fromList([
      ...atomHeader('meta', metaSize - 8),
      ...metaData,
    ]);

    // Build udta
    final udtaSize = 8 + meta.length;
    final udta = Uint8List.fromList([
      ...atomHeader('udta', udtaSize - 8),
      ...meta,
    ]);

    // Build mvhd
    final mvhd = _buildMvhd(1000, durationMs);

    // Build trak
    final trak = _buildTrak(1, durationMs, 1000, 44100, 2, ftyp.length + 8 /* moov size will be calculated below */, audioData.length);
    // Note: mdat offset in trak.stco needs to be after moov. We'll fix this below.

    // Build moov: mvhd + trak + udta
    final moovParts = <Uint8List>[mvhd, trak, udta];
    var moovSize = 8;
    for (final p in moovParts) moovSize += p.length;
    final moov = Uint8List.fromList([
      ...atomHeader('moov', moovSize - 8),
      ...moovParts.expand((a) => a),
    ]);

    // The mdat offset = ftyp + moov
    final mdatOffset = ftyp.length + moov.length;

    // Rebuild trak with correct mdat offset
    final trakFixed = _buildTrak(1, durationMs, 1000, 44100, 2, mdatOffset, audioData.length);
    final moovPartsFixed = <Uint8List>[mvhd, trakFixed, udta];
    var moovSizeFixed = 8;
    for (final p in moovPartsFixed) moovSizeFixed += p.length;
    final moovFixed = Uint8List.fromList([
      ...atomHeader('moov', moovSizeFixed - 8),
      ...moovPartsFixed.expand((a) => a),
    ]);

    // Build mdat
    final mdat = Uint8List.fromList([
      ...atomHeader('mdat', audioData.length),
      ...audioData,
    ]);

    // Write complete MP4: ftyp + moov + mdat
    final result = Uint8List.fromList([...ftyp, ...moovFixed, ...mdat]);
    await file.writeAsBytes(result);

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
