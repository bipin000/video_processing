import Foundation
import AVFoundation
import UIKit

typealias CXEMovieMakerCompletion = (URL) -> Void

public class ImagesToVideoUtils: NSObject {
  
  static let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
  static let tempPath = paths[0] + "/exportvideo.mp4"
  static let fileURL = URL(fileURLWithPath: tempPath)
  
  var assetWriter:AVAssetWriter!
  var writeInput:AVAssetWriterInput!
  var bufferAdapter:AVAssetWriterInputPixelBufferAdaptor!
  var videoSettings:[String : Any]!
  var frameRate:CMTime!
  
  var completionBlock: CXEMovieMakerCompletion?
  
  public class func videoSettings(width:Int, height:Int) -> [String: Any]{
    if(Int(width) % 16 != 0) {
      print("warning: video settings width must be divisible by 16")
    }
    let videoSettings:[String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg, //AVVideoCodecH264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height]
    return videoSettings
  }
  
  public init(videoSettings: [String: Any], frameRate: CMTime) {
    super.init()
    
    if(FileManager.default.fileExists(atPath: ImagesToVideoUtils.tempPath)){
      guard (try? FileManager.default.removeItem(atPath: ImagesToVideoUtils.tempPath)) != nil else {
        print("remove path failed")
        return
      }
    }
    
    self.assetWriter = try! AVAssetWriter(url: ImagesToVideoUtils.fileURL, fileType: AVFileType.mov)
    
    self.videoSettings = videoSettings
    self.writeInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
    assert(self.assetWriter.canAdd(self.writeInput), "add failed")
    
    self.assetWriter.add(self.writeInput)
    let bufferAttributes:[String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)]
    self.bufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.writeInput, sourcePixelBufferAttributes: bufferAttributes)
    self.frameRate = frameRate
  }
  
  func createMovieFromSource(frames: [CGImage], withCompletion: @escaping CXEMovieMakerCompletion) {
    self.completionBlock = withCompletion
    
    self.assetWriter.startWriting()
    self.assetWriter.startSession(atSourceTime: kCMTimeZero)
    
    var i = 0
    let mediaInputQueue = DispatchQueue(label: "mediaInputQueue")
    writeInput.requestMediaDataWhenReady(on: mediaInputQueue) {
      while(i < frames.count) {
        if self.writeInput.isReadyForMoreMediaData {
          if let sampleBuffer = self.newPixelBufferFrom(cgImage: frames[i]) {
            if i == 0 {
              self.bufferAdapter.append(sampleBuffer, withPresentationTime: kCMTimeZero)
            } else {
              let value = i - 1
              let lastTime = CMTimeMake(Int64(value), self.frameRate.timescale)
              let presentTime = CMTimeAdd(lastTime, self.frameRate)
              self.bufferAdapter.append(sampleBuffer, withPresentationTime: presentTime)
            }
          }
          i += 1
        } else {
          print("not ready")
        }
        print(i)
      }
      self.writeInput.markAsFinished()
      self.assetWriter.finishWriting {
        
        DispatchQueue.main.sync {
          self.completionBlock!(ImagesToVideoUtils.fileURL)
        }
      }
    }
  }
  
  func newPixelBufferFrom(cgImage:CGImage) -> CVPixelBuffer?{
    let options:[String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
    var pxbuffer:CVPixelBuffer?
    let frameWidth = videoSettings[AVVideoWidthKey] as! Int
    let frameHeight = videoSettings[AVVideoHeightKey] as! Int
    let status = CVPixelBufferCreate(kCFAllocatorDefault, frameWidth, frameHeight, kCVPixelFormatType_32ARGB, options as CFDictionary?, &pxbuffer)
    assert(status == kCVReturnSuccess && pxbuffer != nil, "newPixelBuffer failed")
    
    CVPixelBufferLockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0))
    let pxdata = CVPixelBufferGetBaseAddress(pxbuffer!)
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: pxdata, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pxbuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    assert(context != nil, "context is nil")
    
    context!.concatenate(CGAffineTransform.identity)
    context!.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    CVPixelBufferUnlockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0))
    return pxbuffer
  }
  
  static func orientationFromTransform(_ transform: CGAffineTransform) -> (orientation: UIImageOrientation, isPortrait: Bool) {
    var assetOrientation = UIImageOrientation.up
    var isPortrait = false
    if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
      assetOrientation = .right
      isPortrait = true
    } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
      assetOrientation = .left
      isPortrait = true
    } else if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
      assetOrientation = .up
    } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
      assetOrientation = .down
    }
    return (assetOrientation, isPortrait)
  }
  
  static func videoCompositionInstruction(_ track: AVCompositionTrack, asset: AVAsset) -> AVMutableVideoCompositionLayerInstruction {
    let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    let assetTrack = asset.tracks(withMediaType: AVMediaType.video)[0]
    let transform = assetTrack.preferredTransform
    let assetInfo = orientationFromTransform(transform)
    
    var scaleToFitRatio = UIScreen.main.bounds.width / assetTrack.naturalSize.width
    if assetInfo.isPortrait {
      scaleToFitRatio = UIScreen.main.bounds.width / assetTrack.naturalSize.height
      let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
      instruction.setTransform(assetTrack.preferredTransform.concatenating(scaleFactor), at: kCMTimeZero)
    } else {
      let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
      var concat = assetTrack.preferredTransform.concatenating(scaleFactor)
        .concatenating(CGAffineTransform(translationX: 0, y: UIScreen.main.bounds.width / 2))
      if assetInfo.orientation == .down {
        let fixUpsideDown = CGAffineTransform(rotationAngle: CGFloat(Double.pi))
        let windowBounds = UIScreen.main.bounds
        let yFix = assetTrack.naturalSize.height + windowBounds.height
        let centerFix = CGAffineTransform(translationX: assetTrack.naturalSize.width, y: yFix)
        concat = fixUpsideDown.concatenating(centerFix).concatenating(scaleFactor)
      }
      instruction.setTransform(concat, at: kCMTimeZero)
    }
    return instruction
  }
}
