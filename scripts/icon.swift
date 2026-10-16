import AppKit

let root=CommandLine.arguments[1]
let sourcePath=CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "resources/AppIcon.png"
try FileManager.default.createDirectory(atPath:root,withIntermediateDirectories:true)
guard let sourceImage=NSImage(contentsOfFile:sourcePath) else {
 fatalError("Could not load source icon at \(sourcePath)")
}
let specs:[(name:String,pixels:Int,points:Int)]=[
 ("icon_16x16",16,16),
 ("icon_16x16@2x",32,16),
 ("icon_32x32",32,32),
 ("icon_32x32@2x",64,32),
 ("icon_128x128",128,128),
 ("icon_128x128@2x",256,128),
 ("icon_256x256",256,256),
 ("icon_256x256@2x",512,256),
 ("icon_512x512",512,512),
 ("icon_512x512@2x",1024,512),
]
for spec in specs {
 guard let rep=NSBitmapImageRep(
  bitmapDataPlanes:nil,
  pixelsWide:spec.pixels,
  pixelsHigh:spec.pixels,
  bitsPerSample:8,
  samplesPerPixel:4,
  hasAlpha:true,
  isPlanar:false,
  colorSpaceName:.deviceRGB,
  bytesPerRow:0,
  bitsPerPixel:0
 ) else {
  fatalError("Could not allocate bitmap for \(spec.name)")
 }
 rep.size=NSSize(width:spec.points,height:spec.points)
 NSGraphicsContext.saveGraphicsState()
 let ctx=NSGraphicsContext(bitmapImageRep:rep)
 NSGraphicsContext.current=ctx
 ctx?.imageInterpolation = .high
 sourceImage.draw(
  in:NSRect(x:0,y:0,width:spec.points,height:spec.points),
  from:.zero,
  operation:.copy,
  fraction:1.0
 )
 NSGraphicsContext.restoreGraphicsState()
 guard let png=rep.representation(using:.png,properties:[:]) else {
  fatalError("Could not encode PNG for \(spec.name)")
 }
 try png.write(to:URL(fileURLWithPath:root).appendingPathComponent(spec.name+".png"))
}
