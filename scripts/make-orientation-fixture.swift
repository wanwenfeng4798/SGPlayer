// Synthetic test media: red upper half, blue lower half. No third-party content.
// Usage on the test Mac: swift scripts/make-orientation-fixture.swift output.mp4
import Foundation
import AVFoundation
import CoreVideo
guard CommandLine.arguments.count == 2 else { fatalError("Specify the output MP4 path") }
let url=URL(fileURLWithPath:CommandLine.arguments[1])
try? FileManager.default.removeItem(at:url)
let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:128,AVVideoHeightKey:96])
let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:128,kCVPixelBufferHeightKey as String:96])
writer.add(input)
assert(writer.startWriting());writer.startSession(atSourceTime:.zero)
var buffer:CVPixelBuffer?
CVPixelBufferCreate(nil,128,96,kCVPixelFormatType_32BGRA,nil,&buffer)
CVPixelBufferLockBaseAddress(buffer!,[])
let pixels=CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to:UInt8.self)
let stride=CVPixelBufferGetBytesPerRow(buffer!)
for y in 0..<96 {for x in 0..<128 {let p=y*stride+x*4;pixels[p]=y<48 ? 0:255;pixels[p+1]=0;pixels[p+2]=y<48 ? 255:0;pixels[p+3]=255}}
CVPixelBufferUnlockBaseAddress(buffer!,[])
for i in 0..<1800 {
 while !input.isReadyForMoreMediaData {
  if writer.status == .failed {fatalError("\(String(describing:writer.error))")}
  Thread.sleep(forTimeInterval:0.001)
 }
 assert(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(i),timescale:30)))
}
input.markAsFinished()
let done=DispatchSemaphore(value:0)
writer.finishWriting{done.signal()};done.wait()
assert(writer.status == .completed,"\(String(describing:writer.error))")
print("PASS red-top blue-bottom 60-second orientation fixture")
