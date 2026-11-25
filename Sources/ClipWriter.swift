import AVFoundation
import CoreImage

final class ClipWriter {
    let url: URL
    let cameraIndex: Int
    let size: CGSize
    private let writer: AVAssetWriter
    private let vIn: AVAssetWriterInput
    private let aIn: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private(set) var started = false
    private var startTime = CMTime.zero

    init?(cameraIndex: Int, size: CGSize) {
        self.cameraIndex = cameraIndex
        self.size = size
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer = w
        vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        vIn.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
        ])
        aIn.expectsMediaDataInRealTime = true
        if w.canAdd(vIn) { w.add(vIn) }
        if w.canAdd(aIn) { w.add(aIn) }
    }

    func appendVideo(_ pb: CVPixelBuffer, at t: CMTime, ci: CIContext) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: t)
            startTime = t
            started = true
        }
        guard writer.status == .writing, vIn.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        ci.render(Cropper.crop(CIImage(cvPixelBuffer: pb), to: size), to: out)
        adaptor.append(out, withPresentationTime: t)
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard started, writer.status == .writing, aIn.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sb) >= startTime else { return }
        aIn.append(sb)
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard started, writer.status == .writing else { done(nil); return }
        vIn.markAsFinished()
        aIn.markAsFinished()
        writer.finishWriting { [self] in done(writer.status == .completed ? url : nil) }
    }
}
