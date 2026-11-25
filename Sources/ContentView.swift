import SwiftUI
import AVFoundation

final class LayerView: UIView {
    var pl: AVCaptureVideoPreviewLayer? {
        didSet { oldValue?.removeFromSuperlayer(); if let pl { layer.addSublayer(pl) } }
    }
    override func layoutSubviews() { super.layoutSubviews(); pl?.frame = bounds }
}

struct PreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView(); v.backgroundColor = .black; v.pl = previewLayer; return v
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}
}

/// Shows where the 9:16 (vertical) and 16:9 (horizontal) shots sit inside the 3:4 frame.
struct FrameGuides: View {
    var lineWidth: CGFloat = 2
    var labels = true
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let vw = h * 9 / 16, hh = w * 9 / 16
            ZStack {
                Rectangle().stroke(Color.yellow, lineWidth: lineWidth)
                    .frame(width: vw, height: h).position(x: w / 2, y: h / 2)
                Rectangle().stroke(Color.cyan, lineWidth: lineWidth)
                    .frame(width: w, height: hh).position(x: w / 2, y: h / 2)
                if labels {
                    Text("9:16").font(.caption2.bold()).foregroundColor(.yellow)
                        .position(x: w / 2, y: 12)
                    Text("16:9").font(.caption2.bold()).foregroundColor(.cyan)
                        .position(x: 22, y: h / 2 - hh / 2 + 10)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var videoMode = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Picker("Lens", selection: $cam.mode) {
                    ForEach(LensMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).disabled(cam.isRecording)

                ZStack(alignment: .topTrailing) {
                    ZStack { PreviewView(previewLayer: cam.previewLayers[0]); FrameGuides() }
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    if cam.mode != .wideOnly {
                        ZStack { PreviewView(previewLayer: cam.previewLayers[1]); FrameGuides(lineWidth: 1, labels: false) }
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            .frame(width: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 2))
                            .padding(8)
                    }
                    if cam.isRecording {
                        Text(String(format: "● %02d:%02d", cam.elapsed / 60, cam.elapsed % 60))
                            .font(.headline.monospacedDigit()).foregroundColor(.red)
                            .padding(6).background(.black.opacity(0.6)).clipShape(Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }

                Text(cam.status).font(.footnote).foregroundColor(.white.opacity(0.8))

                Picker("", selection: $videoMode) {
                    Text("Photo").tag(false); Text("Video").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200).disabled(cam.isRecording)

                Button {
                    if videoMode { cam.isRecording ? cam.stopRecording() : cam.startRecording() }
                    else { cam.takePhoto() }
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 80, height: 80)
                        if videoMode && cam.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 32, height: 32)
                        } else {
                            Circle().fill(videoMode ? Color.red : Color.white).frame(width: 66, height: 66)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        .onAppear { cam.start() }
        .onChange(of: cam.mode) { _, _ in cam.reconfigure() }
    }
}
