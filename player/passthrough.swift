// Passthrough: view from the headset's front cameras.
//
// The C core (cpsvr2.c) reads frames from USB in the background; here they are
// uploaded into a pair of BC4 textures (left and right cameras). BC4 is a Metal
// block format (.bc4_rUnorm) decoded by the GPU for free, so frames go into
// the texture as-is, without CPU unpacking.

import Metal

final class PassthroughSource {
    static let width = Int(PSVR2_CAM_WIDTH)
    static let height = Int(PSVR2_CAM_HEIGHT)
    // BC4: 4 bits per pixel (the composite macro from cpsvr2.h isn't visible in Swift)
    private static let planeBytes = width * height / 2

    private(set) var textureL: MTLTexture?
    private(set) var textureR: MTLTexture?
    private(set) var active = false
    private(set) var gotFrame = false

    // Camera field of view: we have no precise lens calibration,
    // tuned by eye with the +/- keys
    var fovDeg: Float = 150
    var brightness: Float = 1.6

    // The cameras are spaced wider than the eyes, so the stereo comes out
    // exaggerated ("hyperstereo") and is hard to fuse. The M key switches
    // the mode; mono is the guaranteed-comfortable option.
    enum Source: Int32, CaseIterable {
        case stereo = 2, mono0 = 0, mono1 = 1

        var label: String {
            switch self {
            case .stereo: return "stereo"
            case .mono0: return "mono (left camera)"
            case .mono1: return "mono (right camera)"
            }
        }
    }
    var source = Source.stereo

    // Convergence: shifting the images toward each other, in fractions of the
    // frame. Compensates for the camera spacing (noticeably wider than the
    // interpupillary distance). 0.100 tuned by live viewing; adjusted with
    // the "," and "." keys
    var convergence: Float = 0.100

    private var bufL = [UInt8](repeating: 0, count: planeBytes)
    private var bufR = [UInt8](repeating: 0, count: planeBytes)

    init(device: MTLDevice) {
        // BC4 is supported on Apple Silicon; if the format is unavailable,
        // passthrough simply won't turn on
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bc4_rUnorm, width: Self.width, height: Self.height,
            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        textureL = device.makeTexture(descriptor: desc)
        textureR = device.makeTexture(descriptor: desc)
    }

    var available: Bool { textureL != nil && textureR != nil }

    func start() -> Bool {
        guard available, !active else { return active }
        guard psvr2_camera_start() == 0 else {
            print("[passthrough] cameras failed to start")
            return false
        }
        active = true
        gotFrame = false
        print("[passthrough] cameras on")
        return true
    }

    func stop() {
        guard active else { return }
        active = false
        gotFrame = false
        psvr2_camera_stop()
        print("[passthrough] cameras off")
    }

    // Called every render frame
    func update() {
        guard active, let tl = textureL, let tr = textureR else { return }
        var fresh: Int32 = 0
        bufL.withUnsafeMutableBufferPointer { l in
            bufR.withUnsafeMutableBufferPointer { r in
                fresh = psvr2_camera_get_frame(l.baseAddress, r.baseAddress)
            }
        }
        guard fresh == 1 else { return }

        // BC4: 4 bits per pixel, 4x4 block = 8 bytes -> block row = width*2 bytes
        let bytesPerRow = Self.width * 2
        let region = MTLRegionMake2D(0, 0, Self.width, Self.height)
        bufL.withUnsafeBytes {
            tl.replace(region: region, mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow)
        }
        bufR.withUnsafeBytes {
            tr.replace(region: region, mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow)
        }
        gotFrame = true
    }
}
