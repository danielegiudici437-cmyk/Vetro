import SwiftUI
import AVFoundation

struct LiveView: View {
    @ObservedObject var tracer: Tracer
    @ObservedObject var store: Store
    var onSaved: () -> Void
    @State private var showCam = false
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPad { pad } else { phone }
            controls.padding(.bottom, 84)
        }
    }

    private var canvas: some View {
        Group {
            if let img = tracer.image {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // iPhone verticale: sopra la fotocamera, sotto il foglio bianco
    private var phone: some View {
        VStack(spacing: 0) {
            CameraPreview(session: tracer.session, ready: tracer.ready)
                .frame(maxHeight: .infinity).clipped()
            ZStack { Color.white; canvas.padding(.bottom, 80) }
                .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    // iPad orizzontale: tutto nero, tratto bianco, icona in alto a sinistra
    private var pad: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            canvas
            VStack(alignment: .leading, spacing: 10) {
                Button { showCam.toggle() } label: {
                    Image(systemName: "camera.fill").font(.title2).padding(14).glass(Circle())
                }
                if showCam {
                    CameraPreview(session: tracer.session, ready: tracer.ready)
                        .frame(width: 200, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var controls: some View {
        switch tracer.mode {
        case .idle:
            pill("Inizia", "play.fill") { tracer.start() }
        case .calibrating:
            Text("Calibrazione… tieni fermo")
                .font(.callout).padding(.horizontal, 18).padding(.vertical, 12).glass(Capsule())
        case .running:
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(fmt(ctx.date.timeIntervalSince(tracer.startDate))).monospacedDigit()
                }
                .padding(.horizontal, 18).padding(.vertical, 12).glass(Capsule())
                pill("Salva", "checkmark") { save() }
                Button { tracer.cancel() } label: {
                    Image(systemName: "xmark").padding(14).glass(Circle())
                }
            }
        }
    }

    private func pill(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.headline)
                .padding(.horizontal, 20).padding(.vertical, 12).glass(Capsule())
        }
    }

    private func save() {
        let d = Date().timeIntervalSince(tracer.startDate)
        if let img = tracer.finish() { store.add(img, duration: d); onSaved() }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let ready: Bool
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.pl.session = session
        v.pl.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: PreviewView, context: Context) {
        let a = camAngle()
        if let c = v.pl.connection, c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
