/// Native MP4 metadata writer using platform channels.
///
/// On macOS, this uses AVFoundation (AVMutableMetadataItem, AVAssetExportSession)
/// to write proper iTunes-style MP4 metadata that media players can read.
///
/// On other platforms, this falls back to no-op (sidecar JSON is used instead).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Result of native metadata writing.
class NativeMetadataResult {
  final bool success;
  final String? error;

  NativeMetadataResult({required this.success, this.error});
}

/// Native MP4 metadata writer.
class NativeMetadataWriter {
  static const MethodChannel _channel = MethodChannel('dhun.native_metadata');

  /// Check if native metadata writing is supported on this platform.
  static Future<bool> get isSupported async {
    try {
      final result = await _channel.invokeMethod('isSupported');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Write metadata to an MP4 file using native APIs.
  ///
  /// [filePath] - Path to the .m4a file
  /// [song] - Song metadata map from JioSaavn API
  /// [albumArtist] - Album artist override
  /// [trackPos] - Track position number
  /// [totalTracks] - Total tracks in collection
  /// [artworkBytes] - Cover art image bytes (optional)
  /// [songId] - JioSaavn song ID
  static Future<NativeMetadataResult> writeMetadata({
    required String filePath,
    required Map<String, dynamic> song,
    String albumArtist = '',
    int trackPos = 1,
    int totalTracks = 1,
    List<int>? artworkBytes,
    String? songId,
  }) async {
    // Check if file exists
    if (!File(filePath).existsSync()) {
      return NativeMetadataResult(
        success: false,
        error: 'File not found: $filePath',
      );
    }

    // Check platform support
    final supported = await isSupported;
    if (!supported) {
      return NativeMetadataResult(
        success: false,
        error: 'Native metadata writing not supported on this platform',
      );
    }

    // Prepare arguments
    final args = <String, dynamic>{
      'filePath': filePath,
      'song': song,
      'albumArtist': albumArtist,
      'trackPos': trackPos,
      'totalTracks': totalTracks,
      'songId': songId ?? '',
    };

    // Include artwork as base64 if available
    if (artworkBytes != null && artworkBytes.isNotEmpty) {
      args['artworkBase64'] = base64Encode(artworkBytes);
    }

    try {
      final result = await _channel.invokeMethod('writeMetadata', args);
      if (result == true) {
        return NativeMetadataResult(success: true);
      } else {
        return NativeMetadataResult(
          success: false,
          error: result.toString(),
        );
      }
    } on PlatformException catch (e) {
      return NativeMetadataResult(
        success: false,
        error: e.message ?? 'Native metadata error',
      );
    } catch (e) {
      return NativeMetadataResult(
        success: false,
        error: e.toString(),
      );
    }
  }
}
