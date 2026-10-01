import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Turns a full-colour master icon into a menu bar *template*: black where the
// source is bright (the robot), transparent where the source is dark (its
// squircle background). macOS tints template images itself, so the icon follows
// the menu bar's light/dark and highlighted states.
//
// usage: make-menubar-icon <src.png> <dst.png> <luminance threshold 0-255>
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: make-menubar-icon src dst threshold\n".data(using: .utf8)!)
    exit(2)
}
let srcPath = args[1]
let dstPath = args[2]
let threshold = Double(args[3]) ?? 70.0

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

let w = image.width
let h = image.height
let bytesPerRow = w * 4
var inPixels = [UInt8](repeating: 0, count: bytesPerRow * h)
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
inPixels.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: space, bitmapInfo: info)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

var out = [UInt8](repeating: 0, count: bytesPerRow * h)
for i in stride(from: 0, to: inPixels.count, by: 4) {
    let lum = 0.2126 * Double(inPixels[i])
            + 0.7152 * Double(inPixels[i + 1])
            + 0.0722 * Double(inPixels[i + 2])
    if lum > threshold {
        out[i + 3] = 255   // black, fully opaque; rgb already 0
    }
}

// Crop to the glyph's bounding box (plus a little margin) and square it, so the
// icon fills the menu bar's 18pt instead of sitting inside the master's
// transparent padding — that padding is what made the first version look tiny.
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where out[(y * w + x) * 4 + 3] > 0 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write("nothing above the threshold\n".data(using: .utf8)!)
    exit(1)
}
var side = max(maxX - minX + 1, maxY - minY + 1) + 8
side = min(side, min(w, h))
var x0 = (minX + maxX) / 2 - side / 2
var y0 = (minY + maxY) / 2 - side / 2
x0 = max(0, min(x0, w - side))
y0 = max(0, min(y0, h - side))

let outBytesPerRow = side * 4
var cropped = [UInt8](repeating: 0, count: outBytesPerRow * side)
for y in 0..<side {
    let src = ((y0 + y) * w + x0) * 4
    let dst = y * outBytesPerRow
    for i in 0..<outBytesPerRow { cropped[dst + i] = out[src + i] }
}

let provider = CGDataProvider(data: Data(cropped) as CFData)!
let outImage = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outBytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!

guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dstPath) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
