import CoreGraphics
import Foundation

public enum PhotoDifferenceError: Error, Sendable { case invalidPair }

public enum DifferenceUnavailableReason: Sendable {
    case geometry, insufficientDetail, alignment
}

public struct PhotoDifference: Sendable {
    public let reference: CGImage
    public let comparison: CGImage
    /// Approximate rectangles in image-relative coordinates, with the origin at the top left.
    public let regions: [CGRect]
    public let unavailableReason: DifferenceUnavailableReason?

    public static func compare(_ first: PhotoAsset, source firstSource: any AssetSource,
                               _ second: PhotoAsset, source secondSource: any AssetSource) async throws -> PhotoDifference {
        guard first.id != second.id, first.id.source == firstSource.id, second.id.source == secondSource.id else {
            throw PhotoDifferenceError.invalidPair
        }
        try Task.checkCancellation()
        let left = try await preview(first, source: firstSource)
        let right = try await preview(second, source: secondSource)
        try firstSource.validateImage(for: first)
        try secondSource.validateImage(for: second)
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try analyze(left, right) }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        try firstSource.validateImage(for: first)
        try secondSource.validateImage(for: second)
        return result
    }

    private static func preview(_ asset: PhotoAsset, source: any AssetSource) async throws -> CGImage {
        try source.validateImage(for: asset)
        if let photos = source as? PhotoLibrarySource {
            let image = try await photos.thumbnail(for: asset, maxPixelSize: 512)
            return try bounded(image)
        }
        let input = try await source.imageInput(for: asset)
        return try autoreleasepool {
            let imageSource = try input.source()
            let metadata = try input.metadata(for: imageSource)
            return try PreparedImage.orientedImage(imageSource, longestSide: 512, override: metadata.orientationOverride)
        }
    }

    private static func bounded(_ image: CGImage) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > 512 else { return image }
        let width = max(1, image.width * 512 / longest), height = max(1, image.height * 512 / longest)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageReadError.unreadableImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageReadError.unreadableImage }
        return result
    }

    private static let size = 256
    private static let tileSize = 4

    private static func analyze(_ first: CGImage, _ second: CGImage) throws -> PhotoDifference {
        func unavailable(_ reason: DifferenceUnavailableReason) -> PhotoDifference {
            PhotoDifference(reference: first, comparison: second, regions: [], unavailableReason: reason)
        }
        try Task.checkCancellation()
        let firstAspect = Double(first.width) / Double(first.height)
        let secondAspect = Double(second.width) / Double(second.height)
        guard abs(firstAspect - secondAspect) / firstAspect <= 0.005 else { return unavailable(.geometry) }
        guard min(first.width, first.height, second.width, second.height) >= 64 else { return unavailable(.insufficientDetail) }
        let left = smooth(try pixels(first))
        var right = smooth(try pixels(second))
        for channel in 0..<3 {
            let a = quartiles(left, channel: channel), b = quartiles(right, channel: channel)
            let spread = b.high - b.low
            let gain: Float = spread > 0.02 ? (a.high - a.low) / spread : 1
            guard (0.6...1.7).contains(gain) else { return unavailable(.alignment) }
            let offset = a.median - gain * b.median
            for pixel in 0..<(size * size) {
                let index = pixel * 3 + channel
                right[index] = min(1, max(0, right[index] * gain + offset))
            }
        }
        let columns = size / tileSize, tileCount = columns * columns
        var cross = [Double](repeating: 0, count: tileCount)
        var leftEnergy = cross, rightEnergy = cross
        var residual = [Float](repeating: 0, count: tileCount)
        var changed = [Int](repeating: 0, count: tileCount)
        let leftGray = luminance(left), rightGray = luminance(right)
        var totalResidual: Float = 0
        for y in 1..<(size - 1) {
            try Task.checkCancellation()
            for x in 1..<(size - 1) {
                let pixel = y * size + x, tile = y / tileSize * columns + x / tileSize
                let aX = Double(leftGray[pixel + 1] - leftGray[pixel - 1])
                let aY = Double(leftGray[pixel + size] - leftGray[pixel - size])
                let bX = Double(rightGray[pixel + 1] - rightGray[pixel - 1])
                let bY = Double(rightGray[pixel + size] - rightGray[pixel - size])
                cross[tile] += aX * bX + aY * bY
                leftEnergy[tile] += aX * aX + aY * aY
                rightEnergy[tile] += bX * bX + bY * bY
                let index = pixel * 3
                let difference = max(abs(left[index] - right[index]), abs(left[index + 1] - right[index + 1]),
                                     abs(left[index + 2] - right[index + 2]))
                residual[tile] += difference
                totalResidual += difference
                if difference >= 0.08 { changed[tile] += 1 }
            }
        }
        var textured = 0, agreeing = 0
        for tile in 0..<tileCount where max(leftEnergy[tile], rightEnergy[tile]) >= 0.002 {
            textured += 1
            let denominator = sqrt(leftEnergy[tile] * rightEnergy[tile])
            if denominator > 0, cross[tile] / denominator >= 0.9 { agreeing += 1 }
        }
        guard textured >= 24 else { return unavailable(.insufficientDetail) }
        guard Double(agreeing) / Double(textured) >= 0.85,
              totalResidual / Float(size * size) <= 0.065 else { return unavailable(.alignment) }
        let tilePixels = tileSize * tileSize
        var mask = (0..<tileCount).map { changed[$0] >= max(3, tilePixels * 15 / 100) && residual[$0] / Float(tilePixels) >= 0.035 }
        guard mask.filter({ $0 }).count <= tileCount * 15 / 100 else { return unavailable(.alignment) }
        var regions: [CGRect] = []
        for start in mask.indices where mask[start] {
            try Task.checkCancellation()
            var members = [start], cursor = 0
            mask[start] = false
            var minX = start % columns, maxX = minX, minY = start / columns, maxY = minY
            while cursor < members.count {
                let tile = members[cursor], x = tile % columns, y = tile / columns
                cursor += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for nextY in max(0, y - 1)...min(columns - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(columns - 1, x + 1) {
                        let next = nextY * columns + nextX
                        if mask[next] { mask[next] = false; members.append(next) }
                    }
                }
            }
            guard members.count >= 2 else { continue }
            let rect = CGRect(x: Double(minX) / Double(columns), y: Double(minY) / Double(columns),
                width: Double(maxX - minX + 1) / Double(columns), height: Double(maxY - minY + 1) / Double(columns))
            guard rect.width * rect.height <= 0.2 else { return unavailable(.alignment) }
            regions.append(rect)
        }
        var merged: [CGRect] = []
        let gap = 2.0 / Double(columns)
        for region in regions {
            var region = region
            while let index = merged.firstIndex(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(region) }) {
                region = region.union(merged.remove(at: index))
            }
            guard region.width * region.height <= 0.2 else { return unavailable(.alignment) }
            merged.append(region)
        }
        guard merged.count <= 12 else { return unavailable(.alignment) }
        return PhotoDifference(reference: first, comparison: second, regions: merged, unavailableReason: nil)
    }

    private static func pixels(_ image: CGImage) throws -> [Float] {
        let rgba = try PreparedImage.render(image, width: size, height: size)
        var rgb = [Float](repeating: 0, count: size * size * 3)
        for pixel in 0..<(size * size) {
            let background = Float(255 - rgba[pixel * 4 + 3]) / 255
            for channel in 0..<3 { rgb[pixel * 3 + channel] = min(1, Float(rgba[pixel * 4 + channel]) / 255 + background) }
        }
        return rgb
    }

    private static func smooth(_ pixels: [Float]) -> [Float] {
        var horizontal = pixels, result = pixels
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    let index = (y * size + x) * 3 + channel
                    let left = (y * size + max(0, x - 1)) * 3 + channel
                    let right = (y * size + min(size - 1, x + 1)) * 3 + channel
                    horizontal[index] = (pixels[left] + pixels[index] + pixels[right]) / 3
                }
            }
        }
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    let index = (y * size + x) * 3 + channel
                    let above = (max(0, y - 1) * size + x) * 3 + channel
                    let below = (min(size - 1, y + 1) * size + x) * 3 + channel
                    result[index] = (horizontal[above] + horizontal[index] + horizontal[below]) / 3
                }
            }
        }
        return result
    }

    private static func quartiles(_ pixels: [Float], channel: Int) -> (low: Float, median: Float, high: Float) {
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in 0..<(size * size) { histogram[Int((pixels[pixel * 3 + channel] * 255).rounded())] += 1 }
        func quantile(_ fraction: Double) -> Float {
            let target = Int(Double(size * size) * fraction)
            var count = 0
            for index in histogram.indices {
                count += histogram[index]
                if count >= target { return Float(index) / 255 }
            }
            return 1
        }
        return (quantile(0.1), quantile(0.5), quantile(0.9))
    }

    private static func luminance(_ rgb: [Float]) -> [Float] {
        stride(from: 0, to: rgb.count, by: 3).map { index -> Float in
            let red = 0.299 * rgb[index], green = 0.587 * rgb[index + 1], blue = 0.114 * rgb[index + 2]
            return red + green + blue
        }
    }
}
