// 生成 DeepSeek 用量面板应用图标（1024x1024 PNG）
// 用法: swift make_icon.swift <输出.png>
import AppKit

let S = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .calibratedRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("cannot create bitmap")
}
rep.size = NSSize(width: S, height: S)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 圆角方块背景 + 深蓝渐变
let rect = NSRect(x: 0, y: 0, width: S, height: S)
let bg = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.26, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.88, alpha: 1),
])!
gradient.draw(in: bg, angle: -55)

// 中央白色 ¥ 符号（几何绘制，粗线条圆头）
NSColor.white.setStroke()
let lw: CGFloat = 62
func line(_ from: NSPoint, _ to: NSPoint) {
    let p = NSBezierPath()
    p.lineWidth = lw
    p.lineCapStyle = .round
    p.move(to: from)
    p.line(to: to)
    p.stroke()
}
line(NSPoint(x: 322, y: 240), NSPoint(x: 512, y: 470))  // V 左斜
line(NSPoint(x: 702, y: 240), NSPoint(x: 512, y: 470))  // V 右斜
line(NSPoint(x: 512, y: 200), NSPoint(x: 512, y: 790))  // 竖线
line(NSPoint(x: 316, y: 620), NSPoint(x: 708, y: 620))  // 上横
line(NSPoint(x: 316, y: 712), NSPoint(x: 708, y: 712))  // 下横

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("cannot encode png")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon written: \(CommandLine.arguments[1])")
