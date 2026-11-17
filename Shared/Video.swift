import AVFoundation

/// A video that has been opened and indexed.
///
/// The AVFoundation objects are never mutated after loading, which is what makes handing a
/// video from one thread to another safe.
struct Video: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let frames: FrameTable
    /// Size of a frame as it's displayed, i.e. after the track's rotation is applied.
    let displaySize: CGSize
    let orientation: CGAffineTransform
    let frameRate: Double
    let isHDR: Bool

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// The size of the picture in its own pixels, as it's shown (upright).
    var pictureSize: CGSize {
        CGSize(width: displaySize.width.rounded(), height: displaySize.height.rounded())
    }

    var summary: String {
        var parts = ["\(Int(displaySize.width.rounded())) × \(Int(displaySize.height.rounded()))"]
        if let frameRateText {
            parts.append(frameRateText)
        }
        return parts.joined(separator: " · ")
    }

    /// "60 fps", "29.97 fps" — nil for a video that doesn't declare a frame rate.
    var frameRateText: String? {
        guard frameRate > 0 else { return nil }
        let rounded = frameRate.rounded()
        let rate = abs(frameRate - rounded) < 0.01 ? String(Int(rounded)) : String(format: "%.2f", frameRate)
        return "\(rate) fps"
    }

    var exportSource: FrameExporter.Source {
        FrameExporter.Source(asset: asset, track: track, frames: frames, orientation: orientation, pixelSize: displaySize)
    }
}

extension Video {
    /// Reads a video file and indexes its frames.
    static func read(_ url: URL) async throws -> Video {
        let asset = AVURLAsset(url: url)
        guard let track = try await primaryVideoTrack(of: asset) else {
            throw VideoError.noVideoTrack
        }
        let (naturalSize, orientation, nominalFrameRate, characteristics) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics)
        let frames = try await FrameTable.load(track: track, of: asset)
        try Task.checkCancellation()

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(orientation)
        return Video(
            url: url,
            asset: asset,
            track: track,
            frames: frames,
            displaySize: CGSize(width: abs(displayRect.width), height: abs(displayRect.height)),
            orientation: orientation,
            frameRate: Double(nominalFrameRate),
            isHDR: characteristics.contains(.containsHDRVideo)
        )
    }

    /// The video track the player shows: the first enabled one. (Some files carry extra,
    /// disabled video tracks, such as alternate angles or depth data.)
    private static func primaryVideoTrack(of asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        for track in tracks where (try? await track.load(.isEnabled)) == true {
            return track
        }
        return tracks.first
    }
}
