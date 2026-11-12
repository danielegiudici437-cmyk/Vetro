import AVFoundation
import UIKit

enum Mode { case idle, calibrating, running }

func camAngle() -> CGFloat { UIDevice.current.userInterfaceIdiom == .phone ? 90 : 0 }

final class Tracer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // ---- Parametri da regolare se il disegno è troppo sporco o troppo debole ----
    static let threshold: Float = 22      // differenza minima di luminosità (0-255)
    static let confirmFrames: UInt8 = 10  // frame consecutivi per confermare un tratto
    static let calibFrames = 20           // frame usati per memorizzare il vetro "pulito"

    let session = AVCaptureSession()
    @Published var mode: Mode = .idle
    @Published var image: CGImage?
    @Published var ready = false
    private(set) var startDate = Date()

    private let queue = DispatchQueue(label: "tracer.queue")
    private let invert = UIDevice.current.userInterfaceIdiom == .pad  // iPad: bianco su nero
    private var device: AVCaptureDevice?
    private var configured = false
    private var qMode: Mode = .idle
    private var needsReset = true
    private var w = 0, h = 0, calib = 0, frameN = 0
    private var sum: [Float] = [], ref: [Float] = []
    private var mask: [UInt8] = [], streak: [UInt8] = []

    func run(_ on: Bool) {
        if on {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { return }
                self.queue.async {
                    self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        } else if mode == .idle {
            queue.async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        let angle = camAngle()
        if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
        session.commitConfiguration()
        device = dev
        configured = true
        DispatchQueue.main.async { self.ready = true }
    }

    // Blocca esposizione/fuoco mentre disegni, così la luce non cambia da sola
    private func lock(_ on: Bool) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        let ex: AVCaptureDevice.ExposureMode = on ? .locked : .continuousAutoExposure
        let wb: AVCaptureDevice.WhiteBalanceMode = on ? .locked : .continuousAutoWhiteBalance
        let fo: AVCaptureDevice.FocusMode = on ? .locked : .continuousAutoFocus
        if d.isExposureModeSupported(ex) { d.exposureMode = ex }
        if d.isWhiteBalanceModeSupported(wb) { d.whiteBalanceMode = wb }
        if d.isFocusModeSupported(fo) { d.focusMode = fo }
        d.unlockForConfiguration()
    }

    func start() {
        startDate = Date()
        lock(true)
        queue.async { self.needsReset = true; self.qMode = .calibrating }
        image = nil
        mode = .calibrating
    }

    func finish() -> UIImage? {
        var out: UIImage?
        queue.sync {
            qMode = .idle
            if mask.contains(1), let cg = Self.makeImage(mask, w, h, invert: false) {
                let size = CGSize(width: w * 3, height: h * 3)
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1; f.opaque = true
                out = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                    ctx.cgContext.interpolationQuality = .high
                    UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
                }
            }
        }
        lock(false)
        image = nil
        mode = .idle
        return out
    }

    func cancel() { _ = finish() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard qMode != .idle, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let nw = CVPixelBufferGetWidthOfPlane(pb, 0) / 2
        let nh = CVPixelBufferGetHeightOfPlane(pb, 0) / 2
        let p = base.assumingMemoryBound(to: UInt8.self)

        // Luminosità dimezzata (media 2x2)
        var cur = [Float](repeating: 0, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw {
                let i = 2 * y * stride + 2 * x
                cur[y * nw + x] = Float(Int(p[i]) + Int(p[i + 1]) + Int(p[i + stride]) + Int(p[i + stride + 1])) / 4
            }
        }

        if needsReset || nw != w || nh != h {
            w = nw; h = nh; needsReset = false; calib = 0
            sum = [Float](repeating: 0, count: nw * nh)
            mask = [UInt8](repeating: 0, count: nw * nh)
            streak = mask
            if qMode == .running { qMode = .calibrating; DispatchQueue.main.async { self.mode = .calibrating } }
        }

        // 1) Calibrazione: media dei primi fotogrammi = vetro appannato intatto
        if qMode == .calibrating {
            for i in 0..<cur.count { sum[i] += cur[i] }
            calib += 1
            if calib >= Self.calibFrames {
                ref = sum.map { $0 / Float(Self.calibFrames) }
                qMode = .running
                DispatchQueue.main.async { self.mode = .running }
            }
            return
        }

        // 2) Confronto: dove il vetro è diverso in modo stabile, c'è un tratto
        var offset: Float = 0
        for i in 0..<cur.count { offset += cur[i] - ref[i] }
        offset /= Float(cur.count)   // compensa variazioni globali di luce
        for i in 0..<cur.count {
            if abs(cur[i] - ref[i] - offset) > Self.threshold {
                if streak[i] < 255 { streak[i] += 1 }
                if streak[i] >= Self.confirmFrames { mask[i] = 1 }
            } else {
                streak[i] = 0
            }
        }

        frameN += 1
        if frameN % 3 == 0, let cg = Self.makeImage(mask, w, h, invert: invert) {
            DispatchQueue.main.async { self.image = cg }
        }
    }

    static func makeImage(_ ink: [UInt8], _ w: Int, _ h: Int, invert: Bool) -> CGImage? {
        guard w > 0, h > 0, ink.count == w * h else { return nil }
        let paper: UInt8 = invert ? 0 : 255, pen: UInt8 = invert ? 255 : 0
        var px = [UInt8](repeating: paper, count: w * h)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] != 0 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, xx < w, yy >= 0, yy < h { px[yy * w + xx] = pen }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
