import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(red: 0.07, green: 0.17, blue: 0.15, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let mint = NSColor(red: 0.64, green: 0.95, blue: 0.78, alpha: 1)
func line(_ points: [NSPoint], width: CGFloat, alpha: CGFloat = 1) {
    mint.withAlphaComponent(alpha).setStroke()
    let path = NSBezierPath()
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: points[0]); for p in points.dropFirst() { path.line(to: p) }; path.stroke()
}
let top = NSPoint(x: 512, y: 776), left = NSPoint(x: 278, y: 646), right = NSPoint(x: 746, y: 646)
let center = NSPoint(x: 512, y: 512), bottom = NSPoint(x: 512, y: 248)
line([left, top, right, NSPoint(x: 746,y: 382), bottom, NSPoint(x: 278,y: 382), left], width: 15)
line([left, center, right], width: 12)
line([center,bottom], width: 12)
for a in 0...7 {
    for b in 0...7 {
        let x = 300 + CGFloat(a) * 25, y = 404 + CGFloat(b) * 26 - CGFloat(a) * 0.54 * 25
        mint.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 5, height: 5)).fill()
    }
}
for (x,y,sx,sy) in [(CGFloat(172),CGFloat(172),CGFloat(1),CGFloat(1)),(852,172,-1,1),(172,852,1,-1),(852,852,-1,-1)] {
    line([NSPoint(x:x+sx*65,y:y),NSPoint(x:x,y:y),NSPoint(x:x,y:y+sy*65)],width:16)
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
