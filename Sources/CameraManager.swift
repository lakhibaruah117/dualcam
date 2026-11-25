import AVFoundation
import CoreImage
import Photos
import UIKit

enum LensMode: String, CaseIterable, Identifiable {
    case dual = "Dual Lens"
    case single = "Single Lens"
    case frontBack = "Front/Back"
    var id: String { rawValue }
}

final class CameraManager: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    @Published var mode: LensMode = .dual
    @Published var swapped = false
    @Published var isRecording = false
    @Published var toast = ""
    @Published var elapsed = 0
    @Published var audioLevel: Float = 0      // 0...1
    @Published var zoom2x = false
    @Published var take = UserDefaults.standard.integer(forKey: "take") + 1

    /// [0] = big 9:16 preview, [1] = floating card
    let previewLayers = [AVCaptureVideoPreviewLayer(), AVCaptureVideoPreviewLayer()]
    let session = AVCaptureMultiCamSession()

    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let dataQueue = DispatchQueue(label: "dualcam.data")
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ci = CIContext()
    private var mainDevice: AVCaptureDevice?
    private var audioConnection: AVCaptureConnection?
    private var timer: Timer?
    private var meterTimer: Timer?

    // dataQueue only
    private var videoOutputs: [AVCaptureVideoDataOutput] = []
    private var latest: [Int: CVPixelBuffer] = [:]
    private var writers: [ClipWriter] = []
    private var recording = false

    /// What each shot saves, as (camera index, size).
    private func outputsSpec(_ m: LensMode) -> [(Int, CGSize)] {
        switch m {
        case .dual: return [(0, Cropper.vertical), (1, Cropper.horizontal)]
        case .single: return [(0, Cropper.vertical), (0, Cropper.horizontal)]
        case .frontBack: return [(0, Cropper.vertical), (0, Cropper.horizontal), (1, Cropper.vertical)]
        }
    }

    // MARK: Setup
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    DispatchQueue.main.async {
                        self.reconfigure()
                        self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                            self?.updateMeter()
                        }
                    }
                }
            }
        }
    }

    private func updateMeter() {
        guard let ch = audioConnection?.audioChannels.first else { return }
        let db = ch.averagePowerLevel                 // about -60...0 dB
        audioLevel = max(0, min(1, (db + 50) / 50))
    }

    func reconfigure() {
        let m = mode, sw = swapped
        zoom2x = false
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                self.show("Is iPhone pe multi-camera support nahi hai"); return
            }
            self.configure(mode: m, swapped: sw, level: 0)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func swap() { swapped.toggle(); reconfigure() }

    func toggleZoom() {
        zoom2x.toggle()
        let z: CGFloat = zoom2x ? 2 : 1
        sessionQueue.async {
            guard let d = self.mainDevice, (try? d.lockForConfiguration()) != nil else { return }
            d.ramp(toVideoZoomFactor: min(z, d.activeFormat.videoMaxZoomFactor), withRate: 8)
            d.unlockForConfiguration()
        }
    }

    private func devices(for m: LensMode, swapped: Bool) -> [AVCaptureDevice] {
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        var list: [AVCaptureDevice?]
        switch m {
        case .dual: list = [wide, AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)]
        case .single: list = [wide]
        case .frontBack: list = [wide, AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)]
        }
        if swapped && list.count == 2 { list.reverse() }
        return list.compactMap { $0 }
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

    private func setFormat(_ d: AVCaptureDevice, level: Int) {
        let c = candidates(d)
        guard !c.isEmpty else { return }
        let f = c[min(level, c.count - 1)]
        do {
            try d.lockForConfiguration()
            d.activeFormat = f
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            d.videoZoomFactor = 1
            d.unlockForConfiguration()
        } catch {}
    }

    private func configure(mode m: LensMode, swapped sw: Bool, level: Int) {
        let s = session
        s.beginConfiguration()
        for c in s.connections { s.removeConnection(c) }
        for o in s.outputs { s.removeOutput(o) }
        for i in s.inputs { s.removeInput(i) }
        var outs: [AVCaptureVideoDataOutput] = []
        var maxLevel = 0
        let devs = devices(for: m, swapped: sw)
        mainDevice = devs.first

        for (idx, dev) in devs.enumerated() {
            maxLevel = max(maxLevel, candidates(dev).count)
            setFormat(dev, level: level)
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
            layer.videoGravity = .resizeAspectFill
            let pc = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if s.canAddConnection(pc) {
                s.addConnection(pc)
                if pc.isVideoRotationAngleSupported(90) { pc.videoRotationAngle = 90 }
                if dev.position == .front, pc.isVideoMirroringSupported {
                    pc.automaticallyAdjustsVideoMirroring = false
                    pc.isVideoMirrored = true
                }
            }
        }

        audioConnection = nil
        if let mic = AVCaptureDevice.default(for: .audio),
           let ain = try? AVCaptureDeviceInput(device: mic), s.canAddInput(ain) {
            s.addInputWithNoConnections(ain)
            if let aport = ain.ports.first(where: { $0.mediaType == .audio }), s.canAddOutput(audioOutput) {
                s.addOutputWithNoConnections(audioOutput)
                audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                let ac = AVCaptureConnection(inputPorts: [aport], output: audioOutput)
                if s.canAddConnection(ac) { s.addConnection(ac); audioConnection = ac }
            }
        }
        s.commitConfiguration()

        if (s.hardwareCost > 1.0 || s.systemPressureCost > 1.0) && level < maxLevel - 1 {
            configure(mode: m, swapped: sw, level: level + 1)
            return
        }
        dataQueue.sync {
            self.videoOutputs = outs
            self.latest = [:]
        }
    }

    private func show(_ t: String) {
        DispatchQueue.main.async {
            self.toast = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if self.toast == t { self.toast = "" } }
        }
    }

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

    private func bumpTake() {
        UserDefaults.standard.set(take, forKey: "take")
        take += 1
    }

    // MARK: Video
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.elapsed += 1 }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let spec = outputsSpec(mode)
        dataQueue.async {
            self.writers = spec.compactMap { idx, size in
                idx < self.videoOutputs.count ? ClipWriter(cameraIndex: idx, size: size) : nil
            }
            self.recording = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        bumpTake()
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
            group.notify(queue: .main) { self.show("\(saved) videos saved ✅") }
        }
    }

    // MARK: Photo
    func takePhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let spec = outputsSpec(mode)
        bumpTake()
        dataQueue.async {
            var datas: [Data] = []
            for (idx, size) in spec {
                guard let pb = self.latest[idx] else { continue }
                let c = Cropper.crop(CIImage(cvPixelBuffer: pb), to: size)
                if let cg = self.ci.createCGImage(c, from: CGRect(origin: .zero, size: size)),
                   let d = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) {
                    datas.append(d)
                }
            }
            guard !datas.isEmpty else { self.show("Camera abhi ready nahi"); return }
            PHPhotoLibrary.shared().performChanges({
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }) { ok, _ in
                self.show(ok ? "\(datas.count) photos saved ✅" : "Photos save nahi hua")
            }
        }
    }
}
