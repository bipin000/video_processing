//
//  OverlayVideoWriter.swift
//  path_provider
//
//  Created by Felix Hofmann on 06.01.20.
//

import AVFoundation

class OverlayVideoProcessing {
    static func generateVideoWithOverlay(inputPath: String, outputFilePath: String, settings: [VideoProcessSettings], completion: @escaping (URL?) -> ()) {
        
        let bufferedProvider = generateImages(filePath: inputPath, fps: 30, speed: 1.0)
        let textFrameProvider = TextFrameProvider(settings: settings)
        let mixedFrameProvider = MixedFrameProvider(provider: [bufferedProvider!, textFrameProvider])
        generateVideoFromFrames(with: mixedFrameProvider, outputFilePath: outputFilePath, fps: 30, speed: 1.0, completion: completion)
    }
    
//    static func generateVideo(assetPaths: [String], outputFilename: String, outputFps: Int, outputSpeed: Double, completion: @escaping (URL?) -> ()) {
//        let isImg: (String) -> Bool = { $0.contains(".jpg") || $0.contains(".png") }
//        let providers = assetPaths
//            .filter({ !$0.isEmpty })
//            .map { path -> FrameProvider? in
//                return isImg(path.lowercased())
//                    ? FileFrameProvider(filesPath: path)
//                    : generateImages(filePath: path, fps: outputFps, speed: outputSpeed)
//            }
//            .filter { $0 != nil }
//            .map { $0! }
//        guard !providers.isEmpty else {
//            completion(nil)
//            return
//        }
//        let mixedFrameProvider = MixedFrameProvider(provider: providers)
//        generateVideoFromFrames(with: mixedFrameProvider, outputFilename: outputFilename, fps: outputFps, speed: outputSpeed, completion: completion)
//    }
    
    static private func generateVideoFromFrames(with frameProvider: FrameProvider, outputFilePath: String, fps: Int, speed: Double, completion: @escaping (URL?) -> ()) {
        let frameRate = CMTimeMake(1, Int32(Double(60*fps/60)))
        let generator = ImageToVideoGenerator(frameProvider: frameProvider, outputFilePath: outputFilePath, frameRate: frameRate, completionBlock: completion)
        generator.startGenerating()
    }
    
    static private func generateImages(filePath: String, fps: Int, speed: Double) -> BufferedFrameProvider? {
        let fileUrl = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: fileUrl, options: nil)
        let videoDuration = asset.duration
        
        guard let frameSize = asset.tracks(withMediaType: .video).first?.naturalSize else { return nil }
        var frameForTimes = [NSValue]()
        let totalTimeLength = Int(videoDuration.seconds * Double(videoDuration.timescale))
        let sampleCounts = Int(videoDuration.seconds * (Double(fps) / speed))
        let step = totalTimeLength / sampleCounts
        for i in 0 ..< sampleCounts {
            let cmTime = CMTimeMake(Int64(i * step), Int32(videoDuration.timescale))
            frameForTimes.append(NSValue(time: cmTime))
        }
        return BufferedFrameProvider(totalFrames: sampleCounts, frameSize: frameSize, asset: asset, frameTimestamps: frameForTimes)
    }
}

private class ImageToVideoGenerator {
    private var assetWriter:AVAssetWriter!
    private var writeInput:AVAssetWriterInput!
    private var bufferAdapter:AVAssetWriterInputPixelBufferAdaptor!
    private var frameRate: CMTime!
    private var frameProvider: FrameProvider!
    private var outputFilePath: String!
    private var completionBlock: ((URL) -> Void)?
    
    public init(frameProvider: FrameProvider, outputFilePath: String, frameRate: CMTime, completionBlock: ((URL?) -> Void)?) {
        self.outputFilePath = outputFilePath
        if(FileManager.default.fileExists(atPath: outputFilePath)) {
            guard (try? FileManager.default.removeItem(atPath: outputFilePath)) != nil else {
                completionBlock?(nil)
                return
            }
        }
        //TODO: Specify compression settings
        //      https://developer.apple.com/documentation/avfoundation/avassetwriterinput/video_settings_dictionaries
        let videoSettings:[String: Any] = [AVVideoCodecKey: AVVideoCodecH264,
                                           AVVideoWidthKey: Int(frameProvider.frameSize.width),
                                           AVVideoHeightKey: Int(frameProvider.frameSize.height)]
        let outputFileUrl = URL(fileURLWithPath: outputFilePath)
        assetWriter = try! AVAssetWriter(url: outputFileUrl, fileType: .mp4)
        writeInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        assert(assetWriter.canAdd(writeInput), "add failed")
        assetWriter.add(writeInput)
        let bufferAttributes:[String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)]
        bufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.writeInput, sourcePixelBufferAttributes: bufferAttributes)
        self.frameRate = frameRate
        self.frameProvider = frameProvider
        self.completionBlock = completionBlock
    }
    
    func startGenerating() {
        self.assetWriter.startWriting()
        self.assetWriter.startSession(atSourceTime: kCMTimeZero)
        var i = 0
        let mediaInputQueue = DispatchQueue(label: "mediaInputQueue")
        writeInput.requestMediaDataWhenReady(on: mediaInputQueue) {
            while self.frameProvider.hasFrames {
                if self.writeInput.isReadyForMoreMediaData {
                    guard let buffer = self.frameProvider.nextFrameBuffer else { continue }
                    print("Write Frame \(i)")
                    if i == 0 {
                        self.bufferAdapter.append(buffer, withPresentationTime: kCMTimeZero)
                    } else {
                        let value = i - 1
                        let lastTime = CMTimeMake(Int64(value), self.frameRate.timescale)
                        let presentTime = CMTimeAdd(lastTime, self.frameRate)
                        self.bufferAdapter.append(buffer, withPresentationTime: presentTime)
                    }
                    i += 1
                    if self.frameProvider.totalFrames > 0 {
// SwiftVideoProcessingPlugin.sendProgressForCurrentVideoProcess(progress: Double(self.frameProvider.frameIndex) / Double(self.frameProvider.totalFrames))
                    }
                }
            }
            self.writeInput.markAsFinished()
            self.assetWriter.finishWriting {
                DispatchQueue.main.sync {
                    let fileURL = URL(fileURLWithPath: self.outputFilePath)
                    self.completionBlock?(fileURL)
                }
            }
        }
    }
}

public class BufferGenerator {
    static func newPixelBufferFrom(cgImage: CGImage?) -> CVPixelBuffer? {
        guard let img = cgImage else { return nil }
        return newPixelBufferFrom(cgImages: [img], width: img.width, height: img.height)
    }
    
    static func newPixelBufferFrom(cgImages: [CGImage?], width: Int, height: Int) -> CVPixelBuffer? {
        guard !cgImages.isEmpty else { return nil }
        let options:[String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        var pxbuffer:CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, options as CFDictionary?, &pxbuffer)
        assert(status == kCVReturnSuccess && pxbuffer != nil, "newPixelBuffer failed")
        
        CVPixelBufferLockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let pxdata = CVPixelBufferGetBaseAddress(pxbuffer!)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(data: pxdata, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pxbuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        assert(context != nil, "context is nil")
        
        context!.concatenate(CGAffineTransform.identity)
        cgImages.forEach { cgImage in
            if let img = cgImage {
                context!.draw(img, in: rect)
            }
        }
        CVPixelBufferUnlockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0))
        return pxbuffer
    }
}

private protocol FrameProvider {
    var totalFrames: Int { get }
    var frameIndex: Int { get }
    var frameSize: CGSize { get }
    var hasFrames: Bool { get }
    var nextFrame: CGImage? { get }
    var nextFrameBuffer: CVPixelBuffer? { get }
}

private class BufferedFrameProvider: FrameProvider {
    let minBufferSize: Int = 5
    let maxBufferSize: Int = 20
    var hasMemoryPressure: Bool = false
    let asset: AVAsset
    var generator: AVAssetImageGenerator?
    var readFrames: Int = 0
    var frameTimestamps: [NSValue]
    var isGeneratorReading: Bool = false
    let frameSize: CGSize
    var totalFrames: Int //Can decrease depending on errornous read frames
    var frameIndex: Int = 0
    var frames = [CGImage]()
    var currentFrame: CGImage? = nil
    
    init(totalFrames: Int, frameSize: CGSize, asset: AVAsset, frameTimestamps: [NSValue]) {
        self.frameTimestamps = frameTimestamps
        self.totalFrames = totalFrames
        self.frameSize = frameSize
        self.asset = asset
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowMemoryWarning),
            name: .UIApplicationDidReceiveMemoryWarning,
            object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    var hasFrames: Bool {
        return frameIndex < totalFrames
    }
    
    var nextFrame: CGImage? {
        currentFrame = nil
        if !frames.isEmpty {
            DispatchQueue.main.sync {
                self.currentFrame = self.frames.removeFirst()
                self.frameIndex += 1
                print("Read frame with index \(self.frameIndex)/\(self.totalFrames)")
            }
            while currentFrame == nil {}
        }
        if (self.frames.count < self.minBufferSize || (self.frames.isEmpty && self.hasMemoryPressure)) && !self.isGeneratorReading {
            self.isGeneratorReading = true
            DispatchQueue.main.async {
                self.startReadingFrames()
                self.isGeneratorReading = true
                self.hasMemoryPressure = false
                print("Start frame extraction")
            }
        }
        return currentFrame
    }
    
    var nextFrameBuffer: CVPixelBuffer? {
        return BufferGenerator.newPixelBufferFrom(cgImage: nextFrame)
    }
    
    private func pushFrame(frame: CGImage) {
        DispatchQueue.main.sync {
            if (self.frames.count > self.maxBufferSize || hasMemoryPressure) && self.isGeneratorReading {
                self.stopReadingFrames()
            } else {
                self.frames.append(frame)
                self.readFrames += 1
            }
            print("Extracted next frame, buffered frames: ", self.frames.count)
        }
    }
    
    private func startReadingFrames() {
        let timestamps = Array(frameTimestamps[readFrames..<frameTimestamps.count])
        if !timestamps.isEmpty {
            self.generator = AVAssetImageGenerator(asset: asset)
            self.generator!.requestedTimeToleranceAfter = kCMTimeZero
            self.generator!.requestedTimeToleranceBefore = kCMTimeZero
            self.generator!.generateCGImagesAsynchronously(forTimes: timestamps, completionHandler: { requestedTime, image, actualTime, result, error in
                if let frame = image {
                    self.pushFrame(frame: frame)
                } else if let error = error {
                    self.totalFrames -= 1
                    print("Error reading frame: ", error.localizedDescription)
                }
            })
        }
    }
    
    private func stopReadingFrames() {
        if hasMemoryPressure {
            let framesToRemoveCount = min(self.frames.count, maxBufferSize)
            self.frames.removeLast(framesToRemoveCount)
            self.readFrames -= framesToRemoveCount
        }
        self.generator?.cancelAllCGImageGeneration()
        self.generator = nil
        self.isGeneratorReading = false
        print("Stop frame extraction")
    }
    
    @objc private func lowMemoryWarning(notification: NSNotification) {
        print("Memory pressure")
        hasMemoryPressure = true
        stopReadingFrames()
    }
}

private class FileFrameProvider: FrameProvider {
    let totalFrames: Int
    let filesPath: String
    var frameSize: CGSize = .zero
    var frameIndex: Int = 0
    var hasFrames: Bool = false
    
    init(filesPath: String) {
        self.filesPath = filesPath
        self.totalFrames = FileFrameProvider.filesAtPath(filesPath)
        if let frame = frameAtCurrentIndex {
            frameSize = CGSize(width: frame.width, height: frame.height)
            hasFrames = true
        }
    }
    
    var nextFrame: CGImage? {
        if let frame = frameAtCurrentIndex {
            frameIndex += 1
            return frame
        } else {
            hasFrames = false
            return nil
        }
    }
    
    var nextFrameBuffer: CVPixelBuffer? {
        return BufferGenerator.newPixelBufferFrom(cgImage: nextFrame)
    }
    
    private var frameAtCurrentIndex: CGImage? {
        let path = filesPath.contains("%@") ? String(format: filesPath, String(frameIndex)) : filesPath
        return UIImage(contentsOfFile: path)?.cgImage
    }
    
    static private func filesAtPath(_ path: String) -> Int {
        if path.contains("%@") {
            var i = 0
            while FileManager.default.fileExists(atPath: String(format: path, String(i))) {
                i += 1
            }
            return i
        } else {
            return 1
        }
    }
}

private class TextFrameProvider: FrameProvider {
    let totalFrames: Int
    var frameSize: CGSize = .zero
    var frameIndex: Int = 0
    var hasFrames: Bool = false
    
    private let textStrings: [String]
    private var currentString: String?
    private var currentFrame: CGImage?
    
    init(settings: [VideoProcessSettings]) {
        textStrings = settings.map({ $0.text! })
        self.totalFrames = textStrings.count
        if let frame = frameAtCurrentIndex {
            frameSize = CGSize(width: frame.width, height: frame.height)
            hasFrames = true
        }
    }
    
    var nextFrame: CGImage? {
        if let frame = frameAtCurrentIndex {
            frameIndex += 1
            return frame
        } else {
            hasFrames = false
            return nil
        }
    }
    
    var nextFrameBuffer: CVPixelBuffer? {
        return BufferGenerator.newPixelBufferFrom(cgImage: nextFrame)
    }
    
    private var frameAtCurrentIndex: CGImage? {
        if frameIndex >= textStrings.count {
            return nil
        }
        if currentString == textStrings[frameIndex] {
            return currentFrame
        }
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let font = UIFont.boldSystemFont(ofSize: 40)
        let text = NSAttributedString(string: textStrings[frameIndex], attributes: [NSAttributedStringKey.font: font])
        
        UIGraphicsBeginImageContext(frame.size)
        text.draw(in: frame)
        currentFrame = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        currentString = textStrings[frameIndex]
        UIGraphicsEndImageContext()
        return currentFrame
    }
}

private class MixedFrameProvider: FrameProvider {
    let frameProvider: [FrameProvider]
    let maxFrameProvider: FrameProvider?
    var frameForIndex: [(Int, CGImage?)]
    let frameSize: CGSize
    
    init(provider: [FrameProvider]) {
        frameProvider = provider
        frameForIndex = provider.map({ _ in return (-1, nil) })
        maxFrameProvider = provider.max(by: { $0.totalFrames < $1.totalFrames })
        let width = provider.max(by: { $0.frameSize.width < $1.frameSize.width })?.frameSize.width ?? 0
        let height = provider.max(by: { $0.frameSize.height < $1.frameSize.height })?.frameSize.height ?? 0
        frameSize = CGSize(width: width, height: height)
    }
    
    var totalFrames: Int {
        return maxFrameProvider?.totalFrames ?? 0
    }
    
    var frameIndex: Int {
        return maxFrameProvider?.frameIndex ?? 0
    }
    
    var hasFrames: Bool {
        return maxFrameProvider?.hasFrames ?? false
    }
    
    var nextFrame: CGImage? {
        fatalError("Not implemented for Mixed Frame Provider")
    }
    
    var nextFrameBuffer: CVPixelBuffer? {
        var frames = [CGImage]()
        let nextIndex = Double(frameIndex)
        for i in 0 ..< frameProvider.count {
            let provider = frameProvider[i]
            let index = Int(nextIndex * Double(provider.totalFrames)/Double(maxFrameProvider!.totalFrames))
            guard let frame = frameForIndex[i].0 == index ? frameForIndex[i].1 : provider.nextFrame else {
                return nil
            }
            frameForIndex[i] = (index, frame)
            frames.append(frame)
        }
        return BufferGenerator.newPixelBufferFrom(cgImages: frames,
                                                  width: Int(frameSize.width),
                                                  height: Int(frameSize.height))
    }
}
