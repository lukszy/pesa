import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Scales the artwork inside the master so its opaque bounds fill `fraction` of
// the square canvas. The master PNG carries generous transparent padding, which
// makes the icon look small in Finder/Spotlight; macOS expects the app shape to
// fill most of the 1024 grid.
//
// usage: normalize-app-icon <src.png> <dst.png> <fraction 0-1>
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: normalize-app-icon src dst fraction\n".data(using: .utf8)!)
    exit(2)
}
let srcPath = args[1]
let dstPath = args[2]
let fraction = CGFloat(Double(args[3]) ?? 0.73)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

let w = image.width
let h = image.height
let bytesPerRow = w * 4
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue

var px = [UInt8](repeating: 0, count: bytesPerRow * h)
px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: space, bitmapInfo: info)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// Opaque bounds, ignoring the near-transparent anti-aliased fringe. alpha > 16
// keeps the drop shadow, which is part of how the icon reads.
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where Int(px[(y * w + x) * 4 + 3]) > 16 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write("no opaque content\n".data(using: .utf8)!)
    exit(1)
}

let cx = CGFloat(minX + maxX + 1) / 2
let cy = CGFloat(minY + maxY + 1) / 2
let scale = fraction * CGFloat(w) / CGFloat(max(maxX - minX + 1, maxY - minY + 1))
let dw = CGFloat(w) * scale
let dh = CGFloat(h) * scale
let dx = CGFloat(w) / 2 - cx * scale
let dyTop = CGFloat(h) / 2 - cy * scale

var out = [UInt8](repeating: 0, count: bytesPerRow * h)
out.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: space, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    // Rect is in the context's bottom-left space; `dyTop` is a top-down offset.
    ctx.draw(image, in: CGRect(x: dx, y: CGFloat(h) - dyTop - dh, width: dw, height: dh))
}

let provider = CGDataProvider(data: Data(out) as CFData)!
let outImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!

guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dstPath) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
