import SwiftUI
import AVFoundation

let accent = Color(red: 0.30, green: 0.82, blue: 0.86)

final class LayerView: UIView {
    var pl: AVCaptureVideoPreviewLayer? {
        didSet { oldValue?.removeFromSuperlayer(); if let pl { layer.addSublayer(pl) } }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pl?.frame = bounds
        CATransaction.commit()
    }
}

struct PreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView(); v.backgroundColor = .black; v.clipsToBounds = true; v.pl = previewLayer; return v
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}
}

struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

struct TopPill: View {
    @ObservedObject var cam: CameraManager
    var body: some View {
        VStack(spacing: 4) {
            Text("DualCam / \(cam.mode.rawValue) / Take \(String(format: "%03d", cam.take))")
                .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85))
            Text(String(format: "%d:%02d", cam.elapsed / 60, cam.elapsed % 60))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(cam.isRecording ? .red : accent)
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.1.fill").font(.system(size: 9)).foregroundColor(.white.opacity(0.8))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(cam.audioLevel > 0.85 ? Color.red : Color.green)
                            .frame(width: g.size.width * CGFloat(cam.audioLevel))
                    }
                }
                .frame(width: 90, height: 5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var videoMode = true
    @State private var cardOffset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = min(geo.size.height - 70, W * 16 / 9)
            let previewW = H * 9 / 16
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // MAIN 9:16 PREVIEW
                    ZStack {
                        PreviewView(previewLayer: cam.previewLayers[0])
                        ThirdsGrid()
                        if cam.mode == .single {
                            Rectangle().stroke(accent, lineWidth: 1.5)
                                .frame(width: previewW, height: previewW * 9 / 16)
                                .overlay(alignment: .topLeading) {
                                    Text("16:9").font(.caption2.bold()).foregroundColor(accent).padding(5)
                                }
                                .allowsHitTesting(false)
                        }
                        floatingCard(previewW: previewW, H: H)

                        VStack {
                            TopPill(cam: cam).padding(.top, 10)
                            if !cam.toast.isEmpty {
                                Text(cam.toast).font(.footnote.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.black.opacity(0.6)).clipShape(Capsule())
                            }
                            Spacer()
                            bottomControls
                        }
                    }
                    .frame(width: previewW, height: H)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                    modePills.padding(.top, 14)
                }
                .frame(width: W)
            }
        }
        .onAppear { cam.start() }
        .onChange(of: cam.mode) { _, _ in cardOffset = .zero; dragStart = .zero; cam.reconfigure() }
        .statusBarHidden(true)
    }

    @ViewBuilder
    private func floatingCard(previewW: CGFloat, H: CGFloat) -> some View {
        if cam.mode != .single {
            let isDual = cam.mode == .dual
            let cw = isDual ? previewW * 0.58 : previewW * 0.30
            let ch = isDual ? cw * 9 / 16 : cw * 16 / 9
            PreviewView(previewLayer: cam.previewLayers[1])
                .frame(width: cw, height: ch)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isDual ? Color.white.opacity(0.9) : accent, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    Text(isDual ? "16:9" : "9:16").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        .padding(4).background(Color.black.opacity(0.5)).clipShape(Capsule()).padding(6)
                }
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .position(x: isDual ? previewW / 2 : previewW - cw / 2 - 14,
                          y: H * 0.62)
                .offset(cardOffset)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            cardOffset = CGSize(width: dragStart.width + v.translation.width,
                                                height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = cardOffset }
                )
                .onTapGesture { if !cam.isRecording { cam.swap() } }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            Button { cam.toggleZoom() } label: {
                Text(cam.zoom2x ? "2x" : "1x").font(.system(size: 12, weight: .bold))
                    .foregroundColor(cam.zoom2x ? accent : .white)
                    .frame(width: 34, height: 34).background(Color.black.opacity(0.55)).clipShape(Circle())
            }
            HStack {
                Button { if !cam.isRecording { videoMode.toggle() } } label: {
                    Image(systemName: videoMode ? "video.fill" : "camera.fill")
                        .font(.system(size: 17)).foregroundColor(.white)
                        .frame(width: 46, height: 46).background(Color.black.opacity(0.55)).clipShape(Circle())
                }
                .opacity(cam.isRecording ? 0.3 : 1)
                Spacer()
                Button {
                    if videoMode { cam.isRecording ? cam.stopRecording() : cam.startRecording() }
                    else { cam.takePhoto() }
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3.5).frame(width: 74, height: 74)
                        if videoMode {
                            RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 30)
                                .fill(Color.red)
                                .frame(width: cam.isRecording ? 30 : 60, height: cam.isRecording ? 30 : 60)
                                .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
                        } else {
                            Circle().fill(Color.white).frame(width: 60, height: 60)
                        }
                    }
                }
                Spacer()
                Button { cam.swap() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 46, height: 46).background(Color.black.opacity(0.55)).clipShape(Circle())
                }
                .opacity(cam.mode == .single || cam.isRecording ? 0 : 1)
                .disabled(cam.mode == .single || cam.isRecording)
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 18)
    }

    private var modePills: some View {
        HStack(spacing: 4) {
            ForEach(LensMode.allCases) { m in
                Button { if !cam.isRecording { cam.mode = m } } label: {
                    Text(m.rawValue).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(cam.mode == m ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(cam.mode == m ? accent : Color.clear)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }
}
