import AVFoundation
import CoreImage
import Photos
import UIKit

enum LensMode: String, CaseIterable, Identifiable {
    case dualBack = "Wide + Ultra"
    case frontBack = "Back + Front"
    case wideOnly = "Wide"
    var id: String { rawValue }
}

final class CameraManager: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    @Published var mode: LensMode = .dualBack
    @Published var isRecording = false
    @Published var status = "Starting camera…"
    @Published var elapsed = 0
    /// Portrait preview aspect (width / height) of the camera frames.
    @Published var sourceAspect: CGFloat = 3.0 / 4.0

    let previewLayers = [AVCaptureVideoPreviewLayer(), AVCaptureVideoPreviewLayer()]
    let session = AVCaptureMultiCamSession()

    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let dataQueue = DispatchQueue(label: "dualcam.data")
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ci = CIContext()

    // Touched only on dataQueue
    private var videoOutputs: [AVCaptureVideoDataOutput] = []
    private var latest: [Int: CVPixelBuffer] = [:]
    private var writers: [ClipWriter] = []
    private var recording = false
    private var timer: Timer?


    // MARK: Setup
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    DispatchQueue.main.async { self.reconfigure() }
                }
            }
        }
    }

    func reconfigure() {
        let m = mode
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                self.setStatus("Is iPhone pe multi-camera support nahi hai")
                return
            }
            self.configure(mode: m, level: 0)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func devices(for m: LensMode) -> [AVCaptureDevice] {
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        switch m {
        case .dualBack:
            return [wide, AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)].compactMap { $0 }
        case .frontBack:
            return [wide, AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)].compactMap { $0 }
        case .wideOnly:
            return [wide].compactMap { $0 }
        }
    }

    /// Multicam formats, best first: 4:3 before 16:9, then larger first.
    private func candidates(_ d: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        let fmts = d.formats.filter { f in
            f.isMultiCamSupported && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        func is43(_ f: AVCaptureDevice.Format) -> Bool {
            let dm = dims(f); return abs(Double(dm.width) / Double(dm.height) - 4.0 / 3.0) < 0.02
        }
        let usable = fmts.filter { dims($0).width <= 2112 && dims($0).width >= 1280 }
        let sorted = usable.sorted { a, b in
            if is43(a) != is43(b) { return is43(a) }
            return dims(a).width > dims(b).width
        }
        var seen = Set<String>(); var out: [AVCaptureDevice.Format] = []
        for f in sorted {
            let k = "\(dims(f).width)x\(dims(f).height)"
            if !seen.contains(k) { seen.insert(k); out.append(f) }
        }
        return out.isEmpty ? fmts : out
    }

    private func setFormat(_ d: AVCaptureDevice, level: Int) -> CMVideoDimensions? {
        let c = candidates(d)
        guard !c.isEmpty else { return nil }
        let f = c[min(level, c.count - 1)]
        do {
            try d.lockForConfiguration()
            d.activeFormat = f
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            d.unlockForConfiguration()
        } catch {}
        return CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    }

    private func configure(mode m: LensMode, level: Int) {
        let s = session
        s.beginConfiguration()
        for c in s.connections { s.removeConnection(c) }
        for o in s.outputs { s.removeOutput(o) }
        for i in s.inputs { s.removeInput(i) }
        var outs: [AVCaptureVideoDataOutput] = []
        var dimsUsed: CMVideoDimensions?
        var maxLevel = 0

        for (idx, dev) in devices(for: m).enumerated() {
            maxLevel = max(maxLevel, candidates(dev).count)
            if let dm = setFormat(dev, level: level), idx == 0 { dimsUsed = dm }
            guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { continue }
            s.addInputWithNoConnections(input)
            guard let port = input.ports(for: .video, sourceDeviceType: dev.deviceType,
                                         sourceDevicePosition: dev.position).first else { continue }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            guard s.canAddOutput(out) else { continue }
            s.addOutputWithNoConnections(out)
            out.setSampleBufferDelegate(self, queue: dataQueue)
            let conn = AVCaptureConnection(inputPorts: [port], output: out)
            guard s.canAddConnection(conn) else { continue }
            s.addConnection(conn)
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if dev.position == .front, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
            outs.append(out)

            let layer = previewLayers[idx]
            layer.setSessionWithNoConnection(s)
            layer.videoGravity = .resizeAspect
            let pc = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if s.canAddConnection(pc) {
                s.addConnection(pc)
                if pc.isVideoRotationAngleSupported(90) { pc.videoRotationAngle = 90 }
            }
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let ain = try? AVCaptureDeviceInput(device: mic), s.canAddInput(ain) {
            s.addInputWithNoConnections(ain)
            if let aport = ain.ports.first(where: { $0.mediaType == .audio }), s.canAddOutput(audioOutput) {
                s.addOutputWithNoConnections(audioOutput)
                audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                let ac = AVCaptureConnection(inputPorts: [aport], output: audioOutput)
                if s.canAddConnection(ac) { s.addConnection(ac) }
            }
        }
        s.commitConfiguration()

        if (s.hardwareCost > 1.0 || s.systemPressureCost > 1.0) && level < maxLevel - 1 {
            configure(mode: m, level: level + 1)
            return
        }
        dataQueue.sync {
            self.videoOutputs = outs
            self.latest = [:]
        }
        let res = dimsUsed.map { "\($0.width)x\($0.height)" } ?? "?"
        if let dm = dimsUsed {
            let a = CGFloat(dm.height) / CGFloat(dm.width)
            DispatchQueue.main.async { self.sourceAspect = a }
        }
        setStatus("\(outs.count) camera ready • \(res)")
    }

    private func setStatus(_ t: String) { DispatchQueue.main.async { self.status = t } }

    // MARK: Frames
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            if recording { for w in writers { w.appendAudio(sb) } }
            return
        }
        guard let idx = videoOutputs.firstIndex(where: { $0 === output }),
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        latest[idx] = pb
        guard recording else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        for w in writers where w.cameraIndex == idx { w.appendVideo(pb, at: t, ci: ci) }
    }

    // MARK: Video
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.elapsed += 1 }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dataQueue.async {
            var ws: [ClipWriter] = []
            for idx in 0..<self.videoOutputs.count {
                if let v = ClipWriter(cameraIndex: idx, size: Cropper.vertical) { ws.append(v) }
                if let h = ClipWriter(cameraIndex: idx, size: Cropper.horizontal) { ws.append(h) }
            }
            self.writers = ws
            self.recording = true
            self.setStatus("Recording \(ws.count) clips (vertical + horizontal)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dataQueue.async {
            self.recording = false
            let ws = self.writers
            self.writers = []
            let group = DispatchGroup()
            var saved = 0
            let lock = NSLock()
            for w in ws {
                group.enter()
                w.finish { url in
                    guard let url else { group.leave(); return }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                    }) { ok, _ in
                        if ok { lock.lock(); saved += 1; lock.unlock() }
                        try? FileManager.default.removeItem(at: url)
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { self.status = "\(saved) videos saved to Photos ✅" }
        }
    }

    // MARK: Photo
    func takePhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dataQueue.async {
            var datas: [Data] = []
            for idx in self.latest.keys.sorted() {
                guard let pb = self.latest[idx] else { continue }
                let img = CIImage(cvPixelBuffer: pb)
                for size in [Cropper.vertical, Cropper.horizontal] {
                    let c = Cropper.crop(img, to: size)
                    if let cg = self.ci.createCGImage(c, from: CGRect(origin: .zero, size: size)),
                       let d = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) {
                        datas.append(d)
                    }
                }
            }
            guard !datas.isEmpty else { self.setStatus("Camera abhi ready nahi"); return }
            PHPhotoLibrary.shared().performChanges({
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }) { ok, _ in
                self.setStatus(ok ? "\(datas.count) photos saved to Photos ✅" : "Photos save nahi hua")
            }
        }
    }
}
