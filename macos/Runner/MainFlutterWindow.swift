import Cocoa
import FlutterMacOS
import AVFoundation
import UniformTypeIdentifiers

public class NativeMetadataPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dhun.native_metadata",
      binaryMessenger: registrar.messenger
    )
    let instance = NativeMetadataPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)

    case "writeMetadata":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        return
      }

      guard let filePath = args["filePath"] as? String,
            let song = args["song"] as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing required fields", details: nil))
        return
      }

      let albumArtist = args["albumArtist"] as? String ?? ""
      let trackPos = args["trackPos"] as? Int ?? 1
      let totalTracks = args["totalTracks"] as? Int ?? 1
      let songId = args["songId"] as? String ?? ""
      let artworkBase64 = args["artworkBase64"] as? String

      do {
        try writeMetadata(
          filePath: filePath,
          song: song,
          albumArtist: albumArtist,
          trackPos: trackPos,
          totalTracks: totalTracks,
          songId: songId,
          artworkBase64: artworkBase64
        )
        result(true)
      } catch {
        result(FlutterError(code: "METADATA_ERROR", message: error.localizedDescription, details: nil))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func writeMetadata(
    filePath: String,
    song: [String: Any],
    albumArtist: String,
    trackPos: Int,
    totalTracks: Int,
    songId: String,
    artworkBase64: String?
  ) throws {
    let fileURL = URL(fileURLWithPath: filePath)

    // Load the asset
    let asset = AVAsset(url: fileURL)

    var metadataItems: [AVMutableMetadataItem] = []

    // Helper to add metadata item using raw string identifier
    func addItem(identifier: String, value: String) {
      if value.isEmpty { return }
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: identifier)
      item.value = value as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Helper to add data metadata item (for artwork)
    func addDataItem(identifier: String, data: Data, dataType: String) {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: identifier)
      item.value = data as NSData
      item.dataType = dataType
      metadataItems.append(item)
    }

    // Title
    if let title = song["song"] as? String, !title.isEmpty {
      addItem(identifier: "title", value: title)
    } else if let title = song["title"] as? String, !title.isEmpty {
      addItem(identifier: "title", value: title)
    }

    // Album
    if let album = song["album"] as? String, !album.isEmpty {
      addItem(identifier: "album", value: album)
    }

    // Artist
    let effectiveArtist = (!albumArtist.isEmpty) ? albumArtist : (song["primary_artists"] as? String ?? "")
    if !effectiveArtist.isEmpty {
      addItem(identifier: "artist", value: effectiveArtist)
    }

    // Album Artist
    if let albumArtistVal = song["album_artist"] as? String, !albumArtistVal.isEmpty, albumArtistVal != effectiveArtist {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "albumArtist")
      item.value = albumArtistVal as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Year / Release Date
    let releaseDate = song["release_date"] as? String ?? song["year"] as? String ?? ""
    if !releaseDate.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "releaseDate")
      item.value = releaseDate as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Genre
    if let genres = song["genre"] as? [String], !genres.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "genre")
      item.value = genres.joined(separator: "; ") as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    } else if let genre = song["genre"] as? String, !genre.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "genre")
      item.value = genre as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Track Number
    let itemTrack = AVMutableMetadataItem()
    itemTrack.identifier = AVMetadataIdentifier(rawValue: "trackNumber")
    itemTrack.value = String(format: "%02d", trackPos) as NSString
    itemTrack.extendedLanguageTag = "und"
    metadataItems.append(itemTrack)

    // Total Tracks
    let itemTotalTracks = AVMutableMetadataItem()
    itemTotalTracks.identifier = AVMetadataIdentifier(rawValue: "totalTrackCount")
    itemTotalTracks.value = String(totalTracks) as NSString
    itemTotalTracks.extendedLanguageTag = "und"
    metadataItems.append(itemTotalTracks)

    // Disc Number
    if let discNumber = song["disc_number"] as? Int, discNumber > 0 {
      let itemDisc = AVMutableMetadataItem()
      itemDisc.identifier = AVMetadataIdentifier(rawValue: "discNumber")
      itemDisc.value = String(discNumber) as NSString
      itemDisc.extendedLanguageTag = "und"
      metadataItems.append(itemDisc)
    }

    // Explicit Content
    let explicitContent = song["explicit_content"] as? Bool ?? false
    let itemExplicit = AVMutableMetadataItem()
    itemExplicit.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:content rating")
    itemExplicit.value = (explicitContent ? 4 : 2) as NSNumber
    metadataItems.append(itemExplicit)

    // JioSaavn ID
    if let id = song["id"] as? String, !id.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:JioSaavn ID")
      item.value = id as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    } else if !songId.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:JioSaavn ID")
      item.value = songId as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Composers / Songwriters
    if let composers = song["composer"] as? [String], !composers.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:composer")
      item.value = composers.joined(separator: ", ") as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Lyricists
    if let lyricists = song["lyricist"] as? [String], !lyricists.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:lyricist")
      item.value = lyricists.joined(separator: ", ") as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Singers
    if let singers = song["singers"] as? [String], !singers.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:singers")
      item.value = singers.joined(separator: ", ") as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Featured Artists
    if let featured = song["featured_artists"] as? [String], !featured.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:featured artists")
      item.value = featured.joined(separator: ", ") as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Record Label
    if let label = song["label"] as? String, !label.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:record label")
      item.value = label as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Language
    if let language = song["language"] as? String, !language.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "language")
      item.value = language as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // ISRC
    if let isrc = song["isrc"] as? String, !isrc.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:ISRC")
      item.value = isrc as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Duration
    if let duration = song["duration"] as? Int, duration > 0 {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:duration")
      item.value = String(duration) as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Copyright
    if let copyright = song["copyright_text"] as? String, !copyright.isEmpty {
      let item = AVMutableMetadataItem()
      item.identifier = AVMetadataIdentifier(rawValue: "com.apple.iTunes:copyright")
      item.value = copyright as NSString
      item.extendedLanguageTag = "und"
      metadataItems.append(item)
    }

    // Cover Art
    if let artworkBase64 = artworkBase64, !artworkBase64.isEmpty,
       let artworkData = Data(base64Encoded: artworkBase64) {
      addDataItem(identifier: "artwork", data: artworkData, dataType: UTType.jpeg.identifier)
    }

    // Apply metadata using AVAssetExportSession
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw NSError(domain: "NativeMetadataPlugin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
    }

    exportSession.outputFileType = .m4a
    exportSession.outputURL = fileURL
    exportSession.metadata = metadataItems
    exportSession.shouldOptimizeForNetworkUse = false

    // Export synchronously
    let semaphore = DispatchSemaphore(value: 0)
    var exportError: Error?

    exportSession.exportAsynchronously {
      if let error = exportSession.error {
        exportError = error
      }
      semaphore.signal()
    }

    semaphore.wait()

    if let error = exportError {
      throw error
    }
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    NativeMetadataPlugin.register(with: flutterViewController.registrar(forPlugin: "NativeMetadataPlugin"))

    super.awakeFromNib()
  }
}
