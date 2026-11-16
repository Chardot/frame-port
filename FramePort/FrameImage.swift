import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns decoded frames into images: full size for export, window size for the paused frame.
enum FrameImage {
    /// Standard-range Rec. 709. Asked of the decoder so that HDR sources arrive tone-mapped.
    static let standardRangeColor: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// The upright, square-pixel version of a decoded frame. `image` is `buffer` wrapped in a
    /// `CIImage` by the caller, who decides how its colours are to be read.
    static func upright(_ image: CIImage, from buffer: CVPixelBuffer, orientation: CGAffineTransform) -> CIImage {
        var image = image

        // Drop encoder padding outside the clean aperture.
        let clean = CVImageBufferGetCleanRect(buffer)
        if !clean.isEmpty, clean != image.extent {
            image = image.cropped(to: clean).movedToOrigin()
        }

        // Stretch anamorphic pixels to square ones.
        let display = CVImageBufferGetDisplaySize(buffer)
        let size = image.extent.size
        if display.width >= 1, display.height >= 1,
           abs(display.width - size.width) > 0.5 || abs(display.height - size.height) > 0.5 {
            image = image.transformed(by: CGAffineTransform(scaleX: display.width / size.width, y: display.height / size.height))
        }

        // Apply the track's rotation. Video transforms assume a top-left origin and Core Image
        // uses bottom-left, which flips the sign of the two off-diagonal terms.
        let t = orientation
        if t.a != 1 || t.b != 0 || t.c != 0 || t.d != 1 {
            image = image.transformed(by: CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d, tx: 0, ty: 0))
        }

        return image.movedToOrigin()
    }

    // MARK: - On screen

    /// Colour management is off: pixel values go through exactly as decoded.
    private static let plainContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])
    private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!

    /// An upright, full-size copy of a decoded frame, in memory of its own.
    ///
    /// The copy is taken at once because the buffer stays shared with the player, which goes
    /// on to change it: about a second after handing a frame over, it re-labels the frame's
    /// colour primaries. The pixel values are not converted, only labelled with the colour
    /// space the frame arrived in, so the system matches them to the display the same way it
    /// does for the playing video.
    static func snapshot(of buffer: CVPixelBuffer, orientation: CGAffineTransform) -> CGImage? {
        let image = upright(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]), from: buffer, orientation: orientation)
        return bitmap(of: image, width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()), colorSpace: colorSpace(of: buffer))
    }

    /// `image` resampled to exactly `pixelSize`, to be drawn 1:1 on the display's pixel grid.
    static func resampled(_ image: CGImage, to pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard width >= 1, height >= 1, image.width >= 1, image.height >= 1 else { return nil }
        if width == image.width, height == image.height { return image }

        let vertical = Double(height) / Double(image.height)
        let filter = CIFilter.lanczosScaleTransform()
        // Clamped, so the edge rows and columns aren't blended with transparency.
        filter.inputImage = CIImage(cgImage: image, options: [.colorSpace: NSNull()]).clampedToExtent()
        filter.scale = Float(vertical)
        filter.aspectRatio = Float((Double(width) / Double(image.width)) / vertical)
        guard let scaled = filter.outputImage else { return nil }
        return bitmap(of: scaled, width: width, height: height, colorSpace: image.colorSpace ?? rec709)
    }

    /// Renders into memory of our own, so that the result is an ordinary bitmap: something the
    /// window composites like the rest of its contents, with nothing of the video path in it.
    private static func bitmap(of image: CIImage, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard width >= 1, height >= 1 else { return nil }
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            plainContext.render(
                image, toBitmap: base, rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8, colorSpace: nil
            )
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The colour space a decoded buffer is tagged with. Video that is untagged, or tagged
    /// with something the decoder couldn't name, is read as Rec. 709, as the player does.
    private static func colorSpace(of buffer: CVPixelBuffer) -> CGColorSpace {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            // Unnamed values arrive as "ColorPrimaries#2" and the like.
            guard let value = CVBufferCopyAttachment(buffer, key, nil) as? String, !value.contains("#") else { return rec709 }
        }
        guard let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
              let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue(),
              space.model == .rgb else { return rec709 }
        return space
    }
}

extension CIImage {
    func movedToOrigin() -> CIImage {
        extent.origin == .zero ? self : transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

extension CGImage {
    /// Video frames are opaque; re-labelling the alpha byte as padding makes the image plain
    /// RGB instead of RGBA. The pixel data itself is shared, not copied.
    func droppingAlpha() -> CGImage {
        guard bitsPerComponent == 8, bitsPerPixel == 32, let dataProvider, let colorSpace else { return self }
        let opaque: CGImageAlphaInfo
        switch alphaInfo {
        case .premultipliedLast, .last: opaque = .noneSkipLast
        case .premultipliedFirst, .first: opaque = .noneSkipFirst
        default: return self
        }
        let info = CGBitmapInfo(rawValue: (bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | opaque.rawValue)
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: info,
            provider: dataProvider, decode: nil,
            shouldInterpolate: false, intent: renderingIntent
        ) ?? self
    }
}
