// PSVR2 Player — 180°/360° video playback on PlayStation VR2 under macOS.
//
// Video is output to the headset display (4000x2040, side-by-side), head
// orientation is read from the headset's SLAM stream over USB (see cpsvr2.c),
// lens distortion is corrected using the calibration of the specific headset unit.
//
// Keys: Space — pause, R — recenter, F — projection, G — stereo layout,
// V — vertical flip, arrows — seek, +/- — fisheye FOV, Q — quit.

import AppKit
import AVFoundation
import CoreAudio
import Metal
import MetalKit
import VideoToolbox
import simd

// MARK: - Metal shader

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VSOut vs_main(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VSOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    // uv: (0,0) — top-left of the screen, y goes down
    o.uv = float2(p[vid].x * 0.5 + 0.5, 1.0 - (p[vid].y * 0.5 + 0.5));
    return o;
}

struct Uniforms {
    float4x4 rot;
    float4x4 panelInv; // world -> panel space (gaze anchor at the moment it was shown)
    float4 calibL;   // k1,k2,k3,k4 of the left eye
    float4 calibR;
    float4 p0;       // mode, stereo, fisheyeFovRad, flipV
    float4 p1;       // gyro in world axes (xyz) + scanout duration (w), seconds
    float4 p2;       // x: chromatic, y: UI panel visible, zw: cursor (panel texture uv)
    float4 p3;       // panel in tan space: center (xy), half-sizes (zw)
    float4 p4;       // x: has video, y: full-range YUV, z: BT.2020, w: BGRA frame
    float4 p5;       // x: passthrough on, y: camera FOV (rad), z: brightness, w: camera mode
    float4 p6;       // x: camera convergence, y: video stereo depth (fractions of frame)
};

constant float FX = 0.3585564;
constant float FY = 0.3762281;
constant float PI = 3.14159265358979;

static float2 project_dir(float3 w, int mode, int stereo, int eye, float fovRad, float shift, thread bool &valid) {
    float u, v;
    valid = true;
    if (mode == 2) {
        // equidistant fisheye, forward axis -Z
        float cosT = clamp(-w.z, -1.0, 1.0);
        float theta = acos(cosT);
        if (theta > fovRad * 0.5) { valid = false; return float2(0.0); }
        float2 xy = w.xy;
        float len = length(xy);
        float2 d = len > 1e-6 ? xy / len : float2(0.0);
        float r = theta / fovRad;   // 0..0.5 at the edge
        u = 0.5 + r * d.x;
        v = 0.5 - r * d.y;
    } else {
        float lon = atan2(w.x, -w.z);
        float lat = asin(clamp(w.y, -1.0, 1.0));
        if (mode == 1) {
            // half-equirect 180°
            if (fabs(lon) > PI * 0.5) { valid = false; return float2(0.0); }
            u = lon / PI + 0.5;
        } else {
            u = lon / (2.0 * PI) + 0.5;
        }
        v = 0.5 - lat / PI;
    }
    // Stereo depth: shift the eye images horizontally toward/away from each
    // other (inside each eye's own frame) to push a too-close scene back
    if (shift != 0.0) {
        u = clamp(u + shift, 0.0, 1.0);
    }
    if (stereo == 1) {
        u = u * 0.5 + (eye == 1 ? 0.5 : 0.0);
    } else if (stereo == 2) {
        v = v * 0.5 + (eye == 1 ? 0.5 : 0.0);
    }
    return float2(u, v);
}

// Frames come in native YUV 4:2:0 (a third of the memory of BGRA: critical
// for 8K) and are converted to RGB here
static float3 yuv_to_rgb(float y, float2 cbcr, bool fullRange, bool bt2020) {
    if (!fullRange) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cbcr = (cbcr - 128.0 / 255.0) * (255.0 / 224.0);
    } else {
        cbcr -= 0.5;
    }
    float3 rgb;
    if (bt2020) {
        rgb = float3(y + 1.4746 * cbcr.y,
                     y - 0.16455 * cbcr.x - 0.57135 * cbcr.y,
                     y + 1.8814 * cbcr.x);
    } else { // BT.709
        rgb = float3(y + 1.5748 * cbcr.y,
                     y - 0.1873 * cbcr.x - 0.4681 * cbcr.y,
                     y + 1.8556 * cbcr.x);
    }
    return saturate(rgb);
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        constant Uniforms &uni [[buffer(0)]],
                        device const packed_float3 *lut [[buffer(1)]],
                        texture2d<float> videoY [[texture(0)]],
                        texture2d<float> ui [[texture(1)]],
                        texture2d<float> videoCbCr [[texture(2)]],
                        texture2d<float> camL [[texture(3)]],
                        texture2d<float> camR [[texture(4)]]) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    bool hasVideo = uni.p4.x > 0.5;
    bool fullRange = uni.p4.y > 0.5;
    bool bt2020 = uni.p4.z > 0.5;

    int mode = int(uni.p0.x);
    int stereo = int(uni.p0.y);
    float fovRad = uni.p0.z;
    float flipV = uni.p0.w;

    int eye = in.uv.x < 0.5 ? 0 : 1;
    float fU = eye == 0 ? in.uv.x * 2.0 : (in.uv.x - 0.5) * 2.0;
    float fV = in.uv.y;

    float4 c = eye == 0 ? uni.calibL : uni.calibR;
    float k1 = c.x, k2 = c.y, k3 = c.z, k4 = c.w;

    float local_x = k1 + (fU * 2.0 - 1.0) * 0.9803922 * 0.9394987;
    float local_y = k2 + (fV * 2.0 - 1.0) * 0.9394987;

    float Rs = (local_x * local_x + local_y * local_y) * 1023.0;
    int idx = int(Rs);
    float3 scale;
    if (idx > -1 && idx + 1 < 1024) {
        float frac = Rs - float(idx);
        float3 t1 = float3(lut[idx + 1]);
        float3 t0 = float3(lut[idx]);
        scale = frac * t1 + (1.0 - frac) * t0;
    } else {
        float v = Rs - 1023.0;
        scale = float3(v * 0.003648639 + 1.592586,
                       v * 0.004862547 + 1.692979,
                       v * 0.007425308 + 1.841771);
    }

    float cxTan = eye == 0 ? 0.6603788 : 0.3396213;
    float3 rgb = float3(0.0);

    // Scanout correction: the panel scans top to bottom, so row uv.y sees
    // the pose time-shifted relative to the middle of the frame
    float3 gyroW = uni.p1.xyz;
    float rowTime = (in.uv.y - 0.5) * uni.p1.w;

    bool chromatic = uni.p2.x > 0.5;
    int chFrom = chromatic ? 0 : 1;
    int chTo = chromatic ? 2 : 1;

    for (int ch = chFrom; ch <= chTo; ch++) {
        float ny = local_y + (ch == 1 ? -0.0002302693 : 0.0);
        float a = local_x * scale[ch];
        float b = ny * scale[ch];

        float tanx = k3 * a - k4 * b;
        float tanyDown = k4 * a + k3 * b;

        // Outside the render area (per-eye uv outside [0,1]) — black
        float uvx = tanx * FX + cxTan;
        float uvy = tanyDown * FY + 0.5;
        if (uvx < 0.0 || uvx > 1.0 || uvy < 0.0 || uvy > 1.0) {
            continue;
        }

        float3 dir = normalize(float3(tanx, -tanyDown * flipV, -1.0));
        float3 w = (uni.rot * float4(dir, 0.0)).xyz;
        w = normalize(w + cross(gyroW, w) * rowTime);

        // p6.y — video depth: per-eye shift, mirrored between the eyes;
        // positive pushes the scene away, zero (default) leaves it untouched
        float depthShift = stereo == 0 ? 0.0 : (eye == 0 ? uni.p6.y : -uni.p6.y);
        bool valid;
        float2 uv = project_dir(w, mode, stereo, eye, fovRad, depthShift, valid);
        if (!valid) {
            continue;
        }
        float3 sampled;
        if (hasVideo) {
            if (uni.p4.w > 0.5) {
                sampled = videoY.sample(smp, uv).rgb;
            } else {
                float yv = videoY.sample(smp, uv).r;
                float2 cc = videoCbCr.sample(smp, uv).rg;
                sampled = yuv_to_rgb(yv, cc, fullRange, bt2020);
            }
        } else {
            sampled = float3(0.16); // background when no file is open
        }

        if (chromatic) {
            rgb[ch] = sampled[ch];
        } else {
            rgb = sampled;
        }
    }

    // Passthrough: view from the headset's front cameras. The cameras are
    // rigidly attached to the body, so head pose is not applied — the image
    // stays fixed in the field of view. Lens model is equidistant (fisheye),
    // FOV is adjustable.
    if (uni.p5.x > 0.5) {
        float aG = local_x * scale[1];
        float bG = (local_y - 0.0002302693) * scale[1];
        float ptx = k3 * aG - k4 * bG;
        float ptyDown = k4 * aG + k3 * bG;

        float3 dir = normalize(float3(ptx, -ptyDown, -1.0));
        float theta = acos(clamp(-dir.z, -1.0, 1.0));
        float r = theta / uni.p5.y;
        if (r <= 0.5) {
            float2 xy = dir.xy;
            float len = length(xy);
            float2 d = len > 1e-6 ? xy / len : float2(0.0);
            // p5.w: 0 — left camera to both eyes, 1 — right, 2 — stereo.
            // p6.x — convergence: shifts the images toward each other,
            // compensating the camera baseline (wider than the IPD)
            int camMode = int(uni.p5.w);
            bool stereoMode = camMode == 2;
            bool useR = camMode == 1 || (stereoMode && eye == 1);
            float shift = stereoMode ? (eye == 0 ? uni.p6.x : -uni.p6.x) : 0.0;

            // The 1016x1016 frame sits in a 1024-wide texture
            float u = (0.5 + r * d.x + shift) * (1016.0 / 1024.0);
            float v = 0.5 - r * d.y;
            float g = useR ? camR.sample(smp, float2(u, v)).r
                           : camL.sample(smp, float2(u, v)).r;
            rgb = float3(saturate(g * uni.p5.z));
        } else {
            rgb = float3(0.0);
        }
    }

    // Control panel: anchored in space along the gaze direction at the moment
    // it was shown (~1.5 m, slight parallax). The ray direction is transformed
    // by the current pose into world space, then into panel space; coordinates
    // use the green channel, without the video flip
    if (uni.p2.y > 0.5) {
        float aG = local_x * scale[1];
        float bG = (local_y - 0.0002302693) * scale[1];
        float panelTanX = k3 * aG - k4 * bG;
        float panelTanUp = -(k4 * aG + k3 * bG);

        float3 wDir = (uni.rot * float4(panelTanX, panelTanUp, -1.0, 0.0)).xyz;
        float3 pDir = (uni.panelInv * float4(wDir, 0.0)).xyz;
        if (pDir.z < -1e-3) {
            float disp = eye == 0 ? 0.021 : -0.021;
            float2 pc = uni.p3.xy;
            float2 ph = uni.p3.zw;
            float pu = (pDir.x / -pDir.z - disp - pc.x) / (2.0 * ph.x) + 0.5;
            float pv = (pDir.y / -pDir.z - pc.y) / (2.0 * ph.y) + 0.5;
            // Margin around the panel (values match UIOverlay.marginU/V):
            // the cursor may go past the edge, clicking there hides the panel;
            // the texture edge is transparent, so clamp_to_edge doesn't smear
            if (pu >= -0.05 && pu <= 1.05 && pv >= -0.10 && pv <= 1.10) {
                float2 tuv = float2(pu, 1.0 - pv);
                float4 uiC = ui.sample(smp, tuv);

                // Virtual cursor: white dot with a dark outline
                float2 dvec = (tuv - uni.p2.zw) * float2(2.0, 1.0); // panel aspect 2:1
                float dcur = length(dvec);
                if (dcur < 0.014) {
                    uiC = float4(1.0, 1.0, 1.0, 1.0);
                } else if (dcur < 0.020) {
                    uiC = float4(0.0, 0.0, 0.0, 1.0);
                }

                rgb = rgb * (1.0 - uiC.a) + uiC.rgb; // premultiplied alpha
            }
        }
    }

    return float4(rgb, 1.0);
}
"""#

// MARK: - Playback settings

enum Projection: Int32, CaseIterable {
    case equirect360 = 0
    case equirect180 = 1
    case fisheye = 2

    var label: String {
        switch self {
        case .equirect360: return "equirect 360°"
        case .equirect180: return "half-equirect 180°"
        case .fisheye: return "fisheye"
        }
    }

    var shortLabel: String {
        switch self {
        case .equirect360: return "360°"
        case .equirect180: return "180°"
        case .fisheye: return "fisheye"
        }
    }
}

enum StereoLayout: Int32, CaseIterable {
    case mono = 0
    case sbs = 1
    case tb = 2

    var label: String {
        switch self {
        case .mono: return "mono"
        case .sbs: return "stereo SBS"
        case .tb: return "stereo top/bottom"
        }
    }

    var shortLabel: String {
        switch self {
        case .mono: return "mono"
        case .sbs: return "SBS"
        case .tb: return "TB"
        }
    }
}

struct PlaybackConfig {
    var projection = Projection.equirect180
    var stereo = StereoLayout.sbs
    var fisheyeFovDeg: Float = 190
    var flipV: Float = 1
    // Stereo depth: horizontal shift of the eye images (fraction of the
    // per-eye frame). Positive pushes the scene away — for videos with
    // uncomfortably close shots. Separate from the passthrough convergence;
    // resets to 0 for every opened file
    var depth: Float = 0

    // Guess the format from the file name
    static func detect(from name: String) -> PlaybackConfig {
        var cfg = PlaybackConfig()
        let n = name.uppercased()

        if n.contains("FISHEYE") || n.contains("VR180FISH") {
            cfg.projection = .fisheye
            if let range = n.range(of: #"FISHEYE(\d{3})"#, options: .regularExpression) {
                let digits = n[range].dropFirst("FISHEYE".count)
                if let fov = Float(digits) { cfg.fisheyeFovDeg = fov }
            }
        } else if n.contains("360") {
            cfg.projection = .equirect360
        } else if n.contains("180") {
            cfg.projection = .equirect180
        }

        if n.contains("_TB") || n.contains("OVERUNDER") || n.contains("_OU") || n.contains("TOPBOTTOM") {
            cfg.stereo = .tb
        } else if n.contains("SBS") || n.contains("_LR") || n.contains("SIDEBYSIDE") || n.contains("180") || n.contains("FISHEYE") {
            cfg.stereo = .sbs
        } else if cfg.projection == .equirect360 {
            cfg.stereo = .mono
        }
        return cfg
    }
}

// MARK: - Head tracking

final class HeadTracker {
    private var recenter = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var didAutoRecenter = false
    private let correction = simd_quatf(ix: 0, iy: 0, iz: sqrt(0.5), r: sqrt(0.5))
    var connected = false
    var predictionEnabled = true
    // Output latency: render + display scanout (adjusted with [ and ])
    var extraLookaheadS: Float = 0.010

    // Orientation in x-right, y-up, -z-forward space (Monado axes)
    private func currentOrientation() -> simd_quatf? {
        // SLAM updates at ~60 Hz, render at 120 Hz: the C core integrates the
        // pose forward with IMU samples (2000 Hz) and extrapolates by the
        // output latency
        if predictionEnabled {
            var q = [Float](repeating: 0, count: 4)
            guard psvr2_get_predicted_quat(extraLookaheadS, &q) == 1 else { return nil }
            let mapped = simd_quatf(ix: q[1], iy: q[2], iz: q[3], r: q[0])
            return (correction * mapped).normalized
        }

        var q = [Float](repeating: 0, count: 4)
        var p = [Float](repeating: 0, count: 3)
        guard psvr2_get_pose(&q, &p) == 1 else { return nil }
        let mapped = simd_quatf(ix: -q[2], iy: -q[1], iz: q[3], r: q[0])
        return (correction * mapped).normalized
    }

    // Manual view adjustment (dragging the scene with the right button):
    // pitch only. Horizontal alignment is handled by recenter, and manual yaw
    // combined with pitch geometrically produces roll and "flying over the
    // pole" — so there is none.
    // The mouse sets the target; frames catch up smoothly via a slerp follower
    private var offsetTarget = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var offsetCurrent = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var manualPitch: Float = 0
    private var lastSmoothTime = CACurrentMediaTime()

    func requestRecenter() {
        didAutoRecenter = false
        manualPitch = 0
        offsetTarget = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        offsetCurrent = offsetTarget
    }

    // Full recenter (long Fn press): the video center goes exactly where the
    // gaze points right now, including head pitch. For watching while lying down
    func requestFullRecenter() {
        guard let q = currentOrientation() else {
            requestRecenter()
            return
        }
        let f = q.act(SIMD3<Float>(0, 0, -1))
        let yaw = atan2(-f.x, -f.z)
        recenter = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
        didAutoRecenter = true
        // Compensate head pitch with a manual scene pitch
        manualPitch = max(-1.4, min(1.4, -asin(max(-1, min(1, f.y)))))
        offsetTarget = simd_quatf(angle: manualPitch, axis: SIMD3<Float>(1, 0, 0))
        offsetCurrent = offsetTarget
    }

    func addManualRotation(dxPx: Double, dyPx: Double) {
        _ = dxPx // horizontal is intentionally ignored
        let sens: Float = 0.002 // rad per pixel (~0.11°)
        // Pitch limited to ~±80°
        manualPitch = max(-1.4, min(1.4, manualPitch + Float(dyPx) * sens))
        offsetTarget = simd_quatf(angle: manualPitch, axis: SIMD3<Float>(1, 0, 0))
    }

    private func smoothManual() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastSmoothTime))
        lastSmoothTime = now
        // Exponential follower, ~90 ms to target
        let alpha = 1 - expf(-dt * 12)
        offsetCurrent = simd_slerp(offsetCurrent, offsetTarget, alpha)
    }

    // Angular velocity in world (already recentered) space — for per-row
    // scanout correction in the shader
    private(set) var worldAngularVelocity = SIMD3<Float>(repeating: 0)

    // Last view pose — used to anchor the UI panel
    private(set) var viewQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    func viewRotation() -> float4x4 {
        guard let q = currentOrientation() else {
            connected = false
            viewQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            return matrix_identity_float4x4
        }
        connected = true

        if !didAutoRecenter {
            // Remove yaw only, keeping the horizon
            let f = q.act(SIMD3<Float>(0, 0, -1))
            let yaw = atan2(-f.x, -f.z)
            recenter = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
            didAutoRecenter = true
        }

        smoothManual()
        let view = offsetCurrent * recenter * q
        viewQuat = view

        var gyro = [Float](repeating: 0, count: 3)
        var age: Double = 0
        if psvr2_get_motion(&gyro, &age) == 1 {
            // Gyro in body axes -> world axes of the current view
            worldAngularVelocity = view.act(SIMD3<Float>(gyro[0], gyro[1], gyro[2]))
        } else {
            worldAngularVelocity = .zero
        }

        return float4x4(view)
    }
}

// MARK: - Uniforms

struct Uniforms {
    var rot: float4x4
    var panelInv: float4x4 // world -> panel space (anchor at the moment it was shown)
    var calibL: SIMD4<Float>
    var calibR: SIMD4<Float>
    var p0: SIMD4<Float>
    var p1: SIMD4<Float> // gyro in world axes (xyz) + scanout duration, seconds
    var p2: SIMD4<Float> // chromatic, panel visible, cursor uv
    var p3: SIMD4<Float> // panel: center and half-sizes in tan space
    var p4: SIMD4<Float> // has video, full-range YUV, BT.2020
    var p5: SIMD4<Float> // passthrough on, camera FOV (rad), brightness, camera mode
    var p6: SIMD4<Float> // camera convergence
}

// MARK: - Video

final class VideoSource {
    let player: AVPlayer
    private var output: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    private(set) var textureY: MTLTexture?
    private(set) var textureCbCr: MTLTexture?
    private(set) var fullRange = false
    private(set) var bt2020 = false
    private(set) var isBGRA = false
    private(set) var audioDeviceID: AudioDeviceID?
    private var endObserver: NSObjectProtocol?
    let url: URL
    var onUnsupported: ((String) -> Void)?
    private var loggedFormat = false
    private var noFrameSince = CACurrentMediaTime()
    private var gotAnyFrame = false
    // Not every file delivers frames in the requested format: if no frames
    // arrive, try the other variants in turn
    private var formatAttempt = 0

    private enum OutputRecipe {
        case attributes([String: Any]?)
        case settings([String: Any])
    }

    private static let yuvFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    private static let formatAttempts: [OutputRecipe] = [
        // Native YUV: a third of the memory, important for 8K
        .attributes([
            kCVPixelBufferPixelFormatTypeKey as String: yuvFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]),
        // MV-HEVC (Apple/DeoVR stereo video): without an explicit layer
        // request the decoder may not deliver frames at all
        .settings([
            kCVPixelBufferPixelFormatTypeKey as String: yuvFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: [0],
            ],
        ]),
        // 8-bit YUV only
        .attributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]),
        // Let the system decide
        .attributes([kCVPixelBufferMetalCompatibilityKey as String: true]),
        .attributes(nil),
    ]

    init(url: URL, device: MTLDevice) {
        self.url = url
        let item = AVPlayerItem(url: url)
        // Without pitch correction, audio at rates ≠ 1× turns into a squeak
        item.audioTimePitchAlgorithm = .timeDomain
        output = Self.makeOutput(attempt: 0)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // At end of file — stop and rewind to the start (no looping);
        // "Play" will start from the beginning
        describeTracks(item.asset)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            print("[player] end of file")
            if let self {
                ResumeStore.set(nil, for: self.url) // watched to the end — restart
            }
        }

        // Save the position periodically so playback can resume there next time
        saveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.savePosition()
        }
    }

    private var saveTimer: Timer?

    func savePosition() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let t = player.currentTime().seconds
        let d = item.duration.seconds
        guard t.isFinite, d > 60 else { return } // don't remember short clips
        if t > 15 && t < d - 30 {
            ResumeStore.set(t, for: url)
        } else if t >= d - 30 {
            ResumeStore.set(nil, for: url)
        }
    }

    private func describeTracks(_ asset: AVAsset) {
        Task {
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let track = tracks.first else {
                print("[video] No video track found")
                return
            }
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let fps = (try? await track.load(.nominalFrameRate)) ?? 0
            let decodable = (try? await track.load(.isDecodable)) ?? false
            let playable = (try? await track.load(.isPlayable)) ?? false
            let formats = (try? await track.load(.formatDescriptions)) ?? []

            var codec = "?"
            var extra = ""
            if let desc = formats.first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                codec = String(bytes: [
                    UInt8((sub >> 24) & 0xff), UInt8((sub >> 16) & 0xff),
                    UInt8((sub >> 8) & 0xff), UInt8(sub & 0xff),
                ], encoding: .ascii) ?? "?"

                if let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                    // Marker of multi-layer (stereo) HEVC
                    if exts.keys.contains(where: { $0.contains("Heroes") || $0.contains("MVHEVC") }) {
                        extra += ", MV-HEVC"
                    }
                    if let tags = exts["\(kCMFormatDescriptionExtension_ProjectionKind)"] {
                        extra += ", projection \(tags)"
                    }
                }
                extra += ", layers: \(formats.count)"
            }

            print("[video] Track: \(codec), \(Int(size.width))x\(Int(size.height)), "
                + "\(String(format: "%.0f", fps)) fps, "
                + "decodable: \(decodable ? "yes" : "NO"), "
                + "playable: \(playable ? "yes" : "NO")\(extra)")

            // hev1 keeps codec parameters inside the stream — AVFoundation
            // cannot decode that; remuxing to hvc1 (lossless) is needed
            if codec == "hev1" || !decodable {
                let hint = codec == "hev1"
                    ? "hev1 format is not supported by macOS. Remux losslessly:"
                    : "Video track cannot be decoded. Remuxing may help:"
                print("[video] \(hint)")
                print("[video]   tools/fix-hev1 \"\(self.url.path)\"")
                await MainActor.run {
                    self.onUnsupported?(codec == "hev1"
                        ? "hev1 format not supported — remux needed (see log)"
                        : "Video cannot be decoded (see log)")
                }
            }
        }
    }

    // Explicit stop when replacing the file
    func stop() {
        savePosition()
        saveTimer?.invalidate()
        saveTimer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        stop()
        // Diagnostics: if this line doesn't appear when switching files,
        // something is holding on to the old source
        print("[video] source released: \(url.lastPathComponent)")
    }

    func routeAudioToHeadset() {
        // Find the "PS VR2" audio output via CoreAudio and route sound there
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return }

        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let err = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            guard err == noErr else { continue }
            if (name as String).contains("PS VR2") || (name as String).contains("PSVR2") {
                var uidAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var uid: CFString = "" as CFString
                var uidSize = UInt32(MemoryLayout<CFString>.size)
                let uidErr = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
                    AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
                }
                if uidErr == noErr {
                    player.audioOutputDeviceUniqueID = uid as String
                    audioDeviceID = id
                    print("[audio] Audio routed to headset: \(name)")
                }
                return
            }
        }
    }

    // The device's "virtual" system volume ('vmvc') — controlled by the slider
    // in Sound settings when the USB device has no volume control of its own
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'

    // (selector, element) pairs in order of preference: hardware control,
    // per-channel, then the macOS virtual volume
    private var volumeAddresses: [AudioObjectPropertyAddress] {
        let candidates: [(AudioObjectPropertySelector, UInt32)] = [
            (kAudioDevicePropertyVolumeScalar, UInt32(kAudioObjectPropertyElementMain)),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (Self.virtualMainVolume, UInt32(kAudioObjectPropertyElementMain)),
        ]
        return candidates.map {
            AudioObjectPropertyAddress(
                mSelector: $0.0,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: $0.1)
        }
    }

    func deviceVolume() -> Float? {
        guard let id = audioDeviceID else { return nil }
        for var addr in volumeAddresses {
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return nil
    }

    func setDeviceVolume(_ v: Float) -> Bool {
        guard let id = audioDeviceID else { return false }
        var vol = Float32(max(0, min(1, v)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var ok = false
        for var addr in volumeAddresses {
            guard AudioObjectHasProperty(id, &addr) else { continue }
            if AudioObjectSetPropertyData(id, &addr, 0, nil, size, &vol) == noErr {
                ok = true
                if addr.mSelector != kAudioDevicePropertyVolumeScalar || addr.mElement == UInt32(kAudioObjectPropertyElementMain) {
                    break // main or virtual control only needs to be set once
                }
            }
        }
        return ok
    }

    private static func makeOutput(attempt: Int) -> AVPlayerItemVideoOutput {
        switch formatAttempts[attempt] {
        case .attributes(let attrs):
            if let attrs {
                return AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            }
            return AVPlayerItemVideoOutput(outputSettings: nil)
        case .settings(let settings):
            return AVPlayerItemVideoOutput(outputSettings: settings)
        }
    }

    func updateTexture() {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        // No hasNewPixelBuffer check: some files deliver frames without
        // reporting them via that flag
        guard let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let cache = textureCache else {
            retryOtherFormatIfNeeded()
            return
        }
        noFrameSince = CACurrentMediaTime()
        gotAnyFrame = true

        let format = CVPixelBufferGetPixelFormatType(pb)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

        if let matrix = CVBufferGetAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil)?
            .takeUnretainedValue() as? NSString {
            bt2020 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as NSString)
        }

        if !loggedFormat {
            loggedFormat = true
            let fourCC = String(bytes: [
                UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff),
                UInt8((format >> 8) & 0xff), UInt8(format & 0xff),
            ], encoding: .ascii) ?? "?"
            print("[video] \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) "
                + "\(fourCC), \(tenBit ? "10-bit" : "8-bit"), "
                + "\(fullRange ? "full" : "video") range, \(bt2020 ? "BT.2020" : "BT.709")")
        }

        // Non-planar frame (BGRA) — read as RGB, no YUV conversion needed
        isBGRA = CVPixelBufferGetPlaneCount(pb) == 0
        if isBGRA {
            if let tex = makeTexture(pb, cache: cache, plane: 0, format: .bgra8Unorm) {
                textureY = tex
                textureCbCr = tex
            }
            return
        }

        let yFormat: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
        let cbcrFormat: MTLPixelFormat = tenBit ? .rg16Unorm : .rg8Unorm

        if let y = makeTexture(pb, cache: cache, plane: 0, format: yFormat) {
            textureY = y
        }
        if let cbcr = makeTexture(pb, cache: cache, plane: 1, format: cbcrFormat) {
            textureCbCr = cbcr
        }
    }

    private func makeTexture(_ pb: CVPixelBuffer, cache: CVMetalTextureCache,
                             plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTex: CVMetalTexture?
        let res = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, format, w, h, plane, &cvTex)
        guard res == kCVReturnSuccess, let cvTex else {
            print("[video] failed to create texture for plane \(plane): code \(res)")
            return nil
        }
        return CVMetalTextureGetTexture(cvTex)
    }

    // No frames — try the next pixel format
    private func retryOtherFormatIfNeeded() {
        guard !gotAnyFrame, player.rate != 0,
              CACurrentMediaTime() - noFrameSince > 2,
              let item = player.currentItem else { return }
        noFrameSince = CACurrentMediaTime()

        guard formatAttempt + 1 < Self.formatAttempts.count else {
            print("[video] No frames arrive in any format. Status: "
                + "\(item.status.rawValue)"
                + (item.error.map { ", error: \($0.localizedDescription)" } ?? ""))
            gotAnyFrame = true // stop trying
            return
        }

        formatAttempt += 1
        item.remove(output)
        output = Self.makeOutput(attempt: formatAttempt)
        item.add(output)
        loggedFormat = false
        print("[video] No frames — switching to format #\(formatAttempt + 1)")
    }
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let lutBuffer: MTLBuffer
    let placeholderY: MTLTexture
    let placeholderCbCr: MTLTexture
    // Environment instead of gray emptiness while no file is open: a 360°
    // equirect panorama from Resources (generated by tools/nebula.swift),
    // loaded in the background after startup
    private var envTexture: MTLTexture?
    let tracker = HeadTracker()
    var video: VideoSource?
    var config: PlaybackConfig
    var calibration: [Float]
    var chromaticEnabled = true
    var scanlineEnabled = true
    var overlay: UIOverlay!
    // Playback rate; reset to 1× when a new file is opened
    var playbackRate: Float = 1.0
    // View from the headset cameras (double Fn press or the B key)
    var passthrough: PassthroughSource?
    private var pausedByPassthrough = false
    // UI panel in tan space: center and half-sizes (2:1 aspect like the texture)
    let panelCenter = SIMD2<Float>(0, -0.05)
    let panelHalf = SIMD2<Float>(0.5, 0.25)
    // Panel anchor in world space: gaze direction (yaw+pitch, no roll)
    // at the moment it was shown
    private var panelAnchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    // Panel scanout: 2040/2200 of the frame's rows at 120 Hz (from the Monado driver)
    let scanoutDuration: Float = (1.0 / 120.0) * (2040.0 / 2200.0)

    // Diagnostics
    private var statFrames = 0
    private var statGpuTime = 0.0
    private var statLastReport = CACurrentMediaTime()

    init(device: MTLDevice, config: PlaybackConfig, calibration: [Float]) throws {
        self.device = device
        self.config = config
        self.calibration = calibration
        queue = device.makeCommandQueue()!

        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vs_main")
        desc.fragmentFunction = lib.makeFunction(name: "fs_main")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        lutBuffer = device.makeBuffer(
            bytes: psvr2_distortion_lut(), length: 1024 * 3 * 4, options: .storageModeShared)!

        let yDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false)
        yDesc.usage = [.shaderRead]
        placeholderY = device.makeTexture(descriptor: yDesc)!
        var luma = [UInt8](repeating: 40, count: 4)
        placeholderY.replace(
            region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &luma, bytesPerRow: 2)

        let cDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: 2, height: 2, mipmapped: false)
        cDesc.usage = [.shaderRead]
        placeholderCbCr = device.makeTexture(descriptor: cDesc)!
        var chroma = [UInt8](repeating: 128, count: 8)
        placeholderCbCr.replace(
            region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &chroma, bytesPerRow: 4)

        super.init()

        // Decoding the 8K panorama takes a while — don't delay startup.
        // SRGB=false: the shader works in gamma space, same as with video
        if let url = Bundle.main.url(forResource: "environment", withExtension: "jpg") {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let loader = MTKTextureLoader(device: device)
                let tex = try? loader.newTexture(URL: url, options: [.SRGB: false])
                DispatchQueue.main.async { self?.envTexture = tex }
            }
        }
    }

    private var lastButton = false
    private var buttonDownTime = 0.0
    private var buttonLongFired = false
    private var pendingSingleClick = false
    private var lastClickTime = 0.0
    // Auto-pause via the proximity sensor (headset on/off), debounced
    private var wornState = true
    private var lastProxRaw = true
    private var proxRawSince = CACurrentMediaTime()
    private var autoPaused = false
    // At startup the headset usually lies taken off, and the auto-recenter
    // from the first pose points anywhere. Once "off" is detected, repeat the
    // recenter on first wear so the scene and panel end up in front of the eyes
    private var wornRecenterArmed = false
    private var didWornRecenter = false
    private var reanchorPanel = false

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func setPlaybackRate(_ v: Float) {
        playbackRate = v
        if let p = video?.player, p.rate != 0 {
            p.rate = v
        }
        overlay?.showOSD(String(format: "Speed %g×", v))
        print(String(format: "[player] speed: %g×", v))
    }

    // Camera view: pause the video so nothing is missed
    func togglePassthrough() {
        guard let pt = passthrough, pt.available else {
            overlay?.showOSD("Cameras unavailable")
            return
        }
        if pt.active {
            pt.stop()
            if pausedByPassthrough {
                pausedByPassthrough = false
                video?.player.rate = playbackRate
            }
            return
        }
        guard pt.start() else {
            overlay?.showOSD("Cameras failed to start (see log)")
            return
        }
        if let p = video?.player, p.rate != 0 {
            p.pause()
            pausedByPassthrough = true
        }
        // No OSD or panel over the cameras: a clear view of the room
        overlay?.hide()
        overlay?.clearOSD()
    }

    // Stop: close the file (position is saved) and return to the file list
    func stopVideo() {
        guard let v = video else { return }
        v.savePosition()
        v.stop()
        video = nil
        autoPaused = false
        pausedByPassthrough = false
        print("[player] stop — file closed")
        overlay?.openPicker()
    }

    // Anchor the panel in front of the current gaze (keeping the horizon)
    func anchorPanel() {
        let f = tracker.viewQuat.act(SIMD3<Float>(0, 0, -1))
        let yaw = atan2(-f.x, -f.z)
        let pitch = asin(max(-1, min(1, f.y)))
        panelAnchor = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    private func updateProximity() {
        var prox: Int32 = 0
        var ipd: Int32 = 0
        psvr2_get_status(&prox, &ipd)
        let raw = prox == 1

        let now = CACurrentMediaTime()
        if raw != lastProxRaw {
            lastProxRaw = raw
            proxRawSince = now
        }

        // First wear after starting with the headset off — recenter
        if !didWornRecenter {
            if !raw {
                wornRecenterArmed = true
            } else if wornRecenterArmed && now - proxRawSince > 0.4 {
                didWornRecenter = true
                tracker.requestRecenter()
                reanchorPanel = true
                print("[player] headset on — scene and panel aligned to gaze")
            }
        }

        // A state is accepted after 0.4 s of stability
        guard raw != wornState, now - proxRawSince > 0.4 else { return }
        wornState = raw
        // The player needs the mouse only while the headset is worn: take it
        // off and the cursor is free — no alt-tabbing just for the mouse
        overlay?.setWorn(wornState)

        guard let player = video?.player else { return }
        if !wornState {
            if player.rate != 0 {
                player.pause()
                autoPaused = true
                print("[player] headset off — pausing")
            }
        } else if autoPaused {
            player.play()
            autoPaused = false
            print("[player] headset on — resuming")
        }
    }

    func draw(in view: MTKView) {
        // Fn button on the headset: single press — recenter (horizon kept),
        // double — camera view and back, long (>0.8 s) — video center exactly
        // along the gaze direction
        let button = psvr2_get_button() == 1
        let nowBtn = CACurrentMediaTime()
        if button && !lastButton {
            buttonDownTime = nowBtn
            buttonLongFired = false
        }
        if button && !buttonLongFired && nowBtn - buttonDownTime > 0.8 {
            buttonLongFired = true
            pendingSingleClick = false
            tracker.requestFullRecenter()
            overlay?.showOSD("Centered on gaze direction")
            print("[player] full recenter (long headset button press)")
        }
        if !button && lastButton && !buttonLongFired {
            if pendingSingleClick && nowBtn - lastClickTime < 0.45 {
                pendingSingleClick = false // second click — double press
                togglePassthrough()
                print("[player] camera view (double headset button press)")
            } else {
                pendingSingleClick = true
                lastClickTime = nowBtn
            }
        }
        // A single press fires once a pair can no longer happen
        if pendingSingleClick && nowBtn - lastClickTime > 0.45 {
            pendingSingleClick = false
            tracker.requestRecenter()
            print("[player] recenter (headset button)")
        }
        lastButton = button

        updateProximity()

        overlay?.tick()
        video?.updateTexture()
        passthrough?.update()

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let rot = tracker.viewRotation()
        // Anchor the panel after recenter is applied (viewQuat is already fresh)
        if reanchorPanel {
            reanchorPanel = false
            anchorPanel()
        }
        let gyroW = scanlineEnabled ? tracker.worldAngularVelocity : .zero

        // The panel is fixed in the world; a lone OSD toast is glued to the
        // gaze (panelInv * rot = I). If the panel drifts more than ~70° out
        // of view, move it to the current gaze
        let panelInv: float4x4
        if overlay?.active == true {
            let gaze = tracker.viewQuat.act(SIMD3<Float>(0, 0, -1))
            if simd_dot(gaze, panelAnchor.act(SIMD3<Float>(0, 0, -1))) < 0.35 {
                anchorPanel()
            }
            panelInv = float4x4(panelAnchor.inverse)
        } else {
            panelInv = rot.transpose
        }

        // With no file open, show the environment panorama: it goes through
        // the shader's video path as a 360° mono BGRA "video"
        let env = video == nil ? envTexture : nil

        var uni = Uniforms(
            rot: rot,
            panelInv: panelInv,
            calibL: SIMD4(calibration[0], calibration[1], calibration[4], calibration[5]),
            calibR: SIMD4(calibration[2], calibration[3], calibration[6], calibration[7]),
            p0: SIMD4(
                Float((env != nil ? .equirect360 : config.projection).rawValue),
                Float((env != nil ? .mono : config.stereo).rawValue),
                config.fisheyeFovDeg * .pi / 180,
                env != nil ? 1 : config.flipV),
            p1: SIMD4(gyroW.x, gyroW.y, gyroW.z, scanoutDuration),
            p2: SIMD4(
                chromaticEnabled ? 1 : 0,
                // While RMB is held (scene rotation), hide the panel and cursor
                (overlay?.displayVisible ?? false) && NSEvent.pressedMouseButtons & 0x2 == 0 ? 1 : 0,
                // Show the cursor only with the panel (not with a lone OSD toast)
                Float((overlay?.active ?? false) ? overlay!.cursorU : -10),
                Float((overlay?.active ?? false) ? overlay!.cursorV : -10)),
            p3: SIMD4(panelCenter.x, panelCenter.y, panelHalf.x, panelHalf.y),
            p4: SIMD4(
                video?.textureY != nil || env != nil ? 1 : 0,
                (video?.fullRange ?? false) ? 1 : 0,
                (video?.bt2020 ?? false) ? 1 : 0,
                video?.isBGRA ?? false || env != nil ? 1 : 0),
            p5: SIMD4(
                (passthrough?.gotFrame ?? false) ? 1 : 0,
                (passthrough?.fovDeg ?? 150) * .pi / 180,
                passthrough?.brightness ?? 1.6,
                Float(passthrough?.source.rawValue ?? 0)),
            p6: SIMD4(passthrough?.convergence ?? 0, env != nil ? 0 : config.depth, 0, 0))

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBuffer(lutBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(video?.textureY ?? env ?? placeholderY, index: 0)
        enc.setFragmentTexture(overlay?.texture ?? placeholderY, index: 1)
        enc.setFragmentTexture(video?.textureCbCr ?? placeholderCbCr, index: 2)
        enc.setFragmentTexture(passthrough?.textureL ?? placeholderY, index: 3)
        enc.setFragmentTexture(passthrough?.textureR ?? placeholderY, index: 4)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [weak self] buf in
            guard let self else { return }
            DispatchQueue.main.async {
                self.statGpuTime += buf.gpuEndTime - buf.gpuStartTime
            }
        }
        cmd.commit()

        statFrames += 1
        let now = CACurrentMediaTime()
        if now - statLastReport >= 2.0 {
            let fps = Double(statFrames) / (now - statLastReport)
            let gpuMs = statFrames > 0 ? statGpuTime / Double(statFrames) * 1000 : 0
            print(String(format: "[stat] fps=%.1f gpu=%.2fms mem=%.0fMB", fps, gpuMs, Self.memoryFootprintMB()))
            statFrames = 0
            statGpuTime = 0
            statLastReport = now
        }
    }

    // Physical memory of the process — for spotting leaks in the log
    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : 0
    }
}

// MARK: - Window and keyboard

final class PlayerView: MTKView {
    var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }
    // Clicks on the non-key headset window (the key window is the remote on the monitor)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let r = renderer else { return }
        switch event.keyCode {
        case 12, 53: // Q, Esc
            print("[player] quit")
            r.overlay?.hide() // restore the system cursor
            r.video?.savePosition()
            r.video?.player.pause()
            psvr2_stop()
            exit(0)
        case 49: // Space
            togglePause()
        case 15: // R
            r.tracker.requestRecenter()
            print("[player] recenter")
        case 3: // F
            cycleProjection()
        case 5: // G
            cycleStereo()
        case 9: // V
            r.config.flipV *= -1
            print("[player] vertical flip: \(r.config.flipV < 0 ? "on" : "off")")
        case 11: // B — headset camera view
            r.togglePassthrough()
        case 46: // M — camera mode: stereo / mono left / mono right
            guard let pt = r.passthrough, pt.active else { break }
            let all = PassthroughSource.Source.allCases
            pt.source = all[(all.firstIndex(of: pt.source)! + 1) % all.count]
            r.overlay?.showOSD(pt.source.label)
            print("[passthrough] mode: \(pt.source.label)")
        case 43, 47: // "," and "." — in camera view: convergence; in video: stereo depth
            let delta: Float = event.keyCode == 47 ? 0.005 : -0.005
            if let pt = r.passthrough, pt.active {
                pt.convergence = max(-0.15, min(0.15, pt.convergence + delta))
                r.overlay?.showOSD(String(format: "Convergence: %+.3f", pt.convergence))
                print(String(format: "[passthrough] convergence: %+.3f", pt.convergence))
            } else if r.video != nil, r.config.stereo != .mono {
                r.config.depth = max(-0.1, min(0.1, r.config.depth + delta))
                r.overlay?.showOSD(String(format: "Depth: %+.3f", r.config.depth))
                print(String(format: "[player] stereo depth: %+.3f", r.config.depth))
            }
        case 123: // ←
            seek(by: -15)
        case 124: // →
            seek(by: 15)
        case 126: // ↑
            changeVolume(by: 0.05)
        case 125: // ↓
            changeVolume(by: -0.05)
        case 35: // P
            r.tracker.predictionEnabled.toggle()
            print("[player] pose prediction: \(r.tracker.predictionEnabled ? "on" : "off")")
        case 1: // S
            r.scanlineEnabled.toggle()
            print("[player] scanout correction: \(r.scanlineEnabled ? "on" : "off")")
        case 8: // C
            r.chromaticEnabled.toggle()
            print("[player] chromatic correction: \(r.chromaticEnabled ? "on" : "off")")
        case 2: // D
            if let layer = self.layer as? CAMetalLayer {
                layer.displaySyncEnabled.toggle()
                print("[player] presentation vsync: \(layer.displaySyncEnabled ? "on" : "off")")
            }
        case 30: // ]
            r.tracker.extraLookaheadS = min(0.08, r.tracker.extraLookaheadS + 0.005)
            print("[player] pose lookahead: \(Int(r.tracker.extraLookaheadS * 1000)) ms")
        case 33: // [
            r.tracker.extraLookaheadS = max(0, r.tracker.extraLookaheadS - 0.005)
            print("[player] pose lookahead: \(Int(r.tracker.extraLookaheadS * 1000)) ms")
        case 24, 69: // + (=)
            changeFov(by: 5)
        case 27, 78: // -
            changeFov(by: -5)
        default:
            break
        }
    }

    private func changeFov(by delta: Float) {
        guard let r = renderer else { return }
        // In camera mode, +/- tune the lens angle to match the sense of scale
        if let pt = r.passthrough, pt.active {
            pt.fovDeg = max(60, min(220, pt.fovDeg + delta))
            r.overlay?.showOSD("Camera FOV: \(Int(pt.fovDeg))°")
            print("[passthrough] camera FOV: \(Int(pt.fovDeg))°")
            return
        }
        r.config.fisheyeFovDeg += delta
        if r.config.projection == .fisheye {
            print("[player] fisheye FOV: \(r.config.fisheyeFovDeg)°")
        } else {
            print("[player] fisheye FOV: \(r.config.fisheyeFovDeg)° — only affects the fisheye projection (switch with F)")
        }
    }

    private func changeVolume(by delta: Float) {
        guard let video = renderer?.video else { return }

        // First adjust the headset's USB audio hardware volume, if present
        if let current = video.deviceVolume() {
            let target = max(0, min(1, current + delta))
            if video.setDeviceVolume(target) {
                video.player.volume = 1
                print("[player] headset volume (hardware): \(Int(target * 100))%")
                return
            }
        }

        let p = video.player
        p.volume = max(0, min(1, p.volume + delta))
        let percent = Int((p.volume * 100).rounded())
        UserDefaults.standard.set(p.volume, forKey: "volume")
        renderer?.overlay?.showOSD("Volume \(percent)%")
        print("[player] player volume: \(percent)%")
    }

    private func seek(by seconds: Double) {
        guard let p = renderer?.video?.player else { return }
        let target = CMTimeAdd(p.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    }

    private func togglePause() {
        guard let r = renderer, let p = r.video?.player else { return }
        if p.rate == 0 {
            p.rate = r.playbackRate
        } else {
            p.pause()
        }
        print("[player] \(p.rate == 0 ? "pause" : "play")")
    }

    private func cycleProjection() {
        guard let r = renderer else { return }
        let all = Projection.allCases
        let next = all[(all.firstIndex(of: r.config.projection)! + 1) % all.count]
        r.config.projection = next
        print("[player] projection: \(next.label)")
    }

    private func cycleStereo() {
        guard let r = renderer else { return }
        let all = StereoLayout.allCases
        let next = all[(all.firstIndex(of: r.config.stereo)! + 1) % all.count]
        r.config.stereo = next
        print("[player] stereo: \(next.label)")
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let r = renderer else { return }
        // "Grab" the scene: drag the image along with the cursor
        r.tracker.addManualRotation(dxPx: event.deltaX, dyPx: event.deltaY)
        r.overlay?.markActivity()
    }

    private var scrollAccum = 0.0

    override func scrollWheel(with event: NSEvent) {
        // File list scrolling. The touchpad sends a stream of tiny deltas and
        // adds inertial "coasting" after fingers lift — that would fling the
        // list dozens of rows, so the momentum phase is skipped and deltas
        // accumulate up to a whole row
        if event.momentumPhase != [] {
            return
        }
        // Touchpad deltas are "precise" and much smaller than a wheel click
        scrollAccum += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 28 : 1)
        while abs(scrollAccum) >= 1 {
            renderer?.overlay?.scrollPicker(rows: scrollAccum > 0 ? -1 : 1)
            scrollAccum -= scrollAccum > 0 ? 1 : -1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let r = renderer, let overlay = r.overlay else { return }
        guard overlay.active else {
            overlay.markActivity()
            return
        }
        if let action = overlay.click() {
            perform(uiAction: action)
            overlay.redrawSoon()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let overlay = renderer?.overlay else { return }
        if let action = overlay.mouseUp() {
            perform(uiAction: action)
            overlay.redrawSoon()
        }
    }

    func perform(uiAction: UIAction) {
        guard let r = renderer else { return }
        switch uiAction {
        case .playPause: togglePause()
        case .seekBack: seek(by: -15)
        case .seekFwd: seek(by: 15)
        case .seekBack30: seek(by: -30)
        case .seekFwd30: seek(by: 30)
        case .volDown: changeVolume(by: -0.05)
        case .volUp: changeVolume(by: 0.05)
        case .recenter:
            r.tracker.requestRecenter()
            print("[player] recenter")
        case .cycleProjection: cycleProjection()
        case .cycleStereo: cycleStereo()
        case .seekFraction(let f):
            guard let p = r.video?.player, let item = p.currentItem,
                  item.duration.isNumeric else { break }
            let target = CMTime(seconds: item.duration.seconds * f, preferredTimescale: 600)
            p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            print("[player] seek to \(Int(item.duration.seconds * f)) s")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    var keyMonitor: Any?
    var cvLink: CVDisplayLink?
    var playerView: PlayerView?
    var accessHelperWindow: NSWindow?
    // Remote-control window on the regular monitor: holds keyboard focus so
    // system dialogs open on a visible screen, not inside the headset
    var controlWindow: NSWindow?
    // Value fields in the remote's table, by row identifier
    var controlValues: [String: NSTextField] = [:]
    var statusTimer: Timer?
    var sweeper: WindowSweeper?
    let videoURL: URL?

    init(videoURL: URL?) {
        self.videoURL = videoURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // USB tracking
        var calibration = [Float](repeating: 0, count: 8)
        if psvr2_start() == 0 {
            print("[usb] PSVR2 connected, SLAM tracking started")
            psvr2_get_distortion_calibration(&calibration)
            print("[usb] Distortion calibration: \(calibration)")
            psvr2_set_brightness(1.0)
        } else {
            print("[usb] !!! Headset not found on USB — rendering without tracking")
            calibration = [-0.09919293, 0, 0.09919293, 0, 1, 0, 1, 0]
        }
        if calibration[4] == 0 && calibration[6] == 0 {
            // Old calibration version: k3/k4 not set — identity rotation
            calibration[4] = 1
            calibration[6] = 1
        }

        // Headset screen
        let vrScreen = NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("PS VR2")
                || ($0.frame.width * $0.backingScaleFactor) == 4000
        }
        let screen = vrScreen ?? NSScreen.main!
        if vrScreen == nil {
            print("[display] !!! PS VR2 display not found — output to a window on the main screen")
        } else {
            print("[display] PS VR2 display: \(screen.frame)")
        }

        let device = MTLCreateSystemDefaultDevice()!

        var config = PlaybackConfig()
        if let url = videoURL {
            config = PlaybackConfig.detect(from: url.lastPathComponent)
        }

        renderer = try! Renderer(device: device, config: config, calibration: calibration)

        renderer.passthrough = PassthroughSource(device: device)

        // Control panel inside the headset (appears on mouse movement)
        let overlay = UIOverlay(device: device)
        overlay.renderer = renderer
        overlay.captureEnabled = vrScreen != nil
        let primaryHeight = NSScreen.screens[0].frame.height
        overlay.warpPoint = CGPoint(x: screen.frame.midX, y: primaryHeight - screen.frame.midY)
        overlay.onOpenFile = { [weak self] url in
            self?.loadVideo(url)
        }
        overlay.onWindowLevelRequest = { [weak self] onTop in
            onTop ? self?.hideAccessHelper() : self?.showAccessHelper()
        }
        renderer.overlay = overlay

        if let url = videoURL {
            loadVideo(url)
        }

        let view = PlayerView(frame: screen.frame, device: device)
        view.renderer = renderer
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        // MTKView's internal timer may tick from another (60 Hz) display —
        // we draw ourselves from a CADisplayLink bound to the window's screen
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        playerView = view

        if vrScreen != nil {
            // The borderless headset window intentionally does NOT become key:
            // keyboard focus lives in the remote window on the monitor, so
            // system dialogs open where they can be seen
            window = NSWindow(
                contentRect: screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false, screen: screen)
            window.level = .mainMenu + 1
            window.setFrame(screen.frame, display: true)
            window.contentView = view
            window.orderFrontRegardless()
            makeControlWindow()
        } else {
            let rect = NSRect(x: 100, y: 100, width: 1000, height: 510)
            window = NSWindow(
                contentRect: rect, styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "PSVR2 Player (preview)"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Safety net: catch keys at the application level even if the window
        // on the headset display is not focused
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            view.keyDown(with: event)
            return nil
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDragged) { event in
            view.rightMouseDragged(with: event)
            return nil
        }

        // Pacing from the specific headset display via CVDisplayLink:
        // CADisplayLink/MTKView may tick from another (60 Hz) screen
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
        let displayID = CGDirectDisplayID(truncating: screenNumber)
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            print("[display] Headset display refresh rate per CoreGraphics: \(mode.refreshRate) Hz, "
                + "screen maxFPS: \(screen.maximumFramesPerSecond)")
        }
        if vrScreen != nil {
            startWindowSweeper(vrScreen: screen)
        }

        var linkOut: CVDisplayLink?
        CVDisplayLinkCreateWithCGDisplay(displayID, &linkOut)
        if let link = linkOut {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                DispatchQueue.main.async {
                    self?.playerView?.draw()
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            cvLink = link
        } else {
            print("[display] !!! CVDisplayLink failed to create — falling back to the MTKView timer")
            view.isPaused = false
        }

        // No file — open the picker in the headset right away
        if videoURL == nil {
            overlay.openPicker()
        }

        print("[player] Controls: Space pause · R or headset Fn button — recenter · F projection · G stereo · V flip")
        print("[player]           ←/→ ±15s · ↑/↓ volume · +/- fisheye FOV · Q quit")
        print("[player]           debug: P prediction · [/] lookahead · S scanout · C chromatic")
    }

    // Remote window on the regular monitor: a "setting — value — key" table
    // grouped like typical app preferences. It also holds keyboard focus so
    // system dialogs stay visible
    private func makeControlWindow() {
        let deskScreen = NSScreen.screens.first {
            !$0.localizedName.localizedCaseInsensitiveContains("PS VR2")
        } ?? NSScreen.main!
        let size = NSSize(width: 620, height: 578)
        let frame = NSRect(
            x: deskScreen.visibleFrame.maxX - size.width - 24,
            y: deskScreen.visibleFrame.minY + 24,
            width: size.width, height: size.height)

        let win = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false, screen: deskScreen)
        win.title = "GAV PSVR2 Player — Remote"
        win.isReleasedWhenClosed = false
        // The remote's close button quits the whole player — same as the Q key
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
            NSApp.terminate(nil)
        }
        let content = win.contentView!

        func label(_ s: String, size: CGFloat = 12.5, color: NSColor = .labelColor,
                   weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = mono
                ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                : .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            return l
        }

        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        controlValues.removeAll()

        func addHeader(_ title: String) {
            // The row must have all 3 cells, otherwise mergeCells crashes
            let row = grid.addRow(with: [
                label(title, size: 12, color: .secondaryLabelColor, weight: .semibold),
                NSGridCell.emptyContentView,
                NSGridCell.emptyContentView,
            ])
            row.mergeCells(in: NSRange(location: 0, length: 3))
            row.topPadding = grid.numberOfRows > 1 ? 14 : 0
        }
        func addRow(_ name: String, id: String, key: String) {
            let value = label("—", mono: true)
            value.lineBreakMode = .byTruncatingMiddle
            grid.addRow(with: [
                label(name, color: .secondaryLabelColor),
                value,
                label(key, size: 11.5, color: .tertiaryLabelColor, mono: true),
            ])
            controlValues[id] = value
        }

        addHeader("Playback")
        addRow("File", id: "file", key: "")
        addRow("Position", id: "pos", key: "Space · ←/→")
        addRow("Volume", id: "vol", key: "↑/↓")
        addRow("Speed", id: "rate", key: "panel in headset")
        addHeader("Image")
        addRow("Projection", id: "proj", key: "F")
        addRow("Stereo", id: "stereo", key: "G")
        addRow("Vertical flip", id: "flip", key: "V")
        addRow("Stereo depth", id: "depth", key: ", / .")
        addRow("Fisheye FOV", id: "fov", key: "+ / −")
        addHeader("Cameras (passthrough)")
        addRow("Mode", id: "pt", key: "B · double Fn")
        addRow("Stereo/mono", id: "ptmode", key: "M")
        addRow("Convergence", id: "ptconv", key: ", / .")
        addRow("Lens angle", id: "ptfov", key: "+ / −")
        addHeader("Headset and tracking")
        addRow("Tracking", id: "track", key: "")
        addRow("Pose prediction", id: "pred", key: "P")
        addRow("Lookahead", id: "look", key: "[ / ]")
        addRow("Scanout correction", id: "scan", key: "S")
        addRow("Chromatic", id: "chrom", key: "C")
        addRow("Vsync", id: "vsync", key: "D")

        grid.column(at: 0).width = 150
        grid.column(at: 1).width = 270
        grid.column(at: 2).xPlacement = .trailing

        let footer = NSTextField(wrappingLabelWithString:
            "Fn button: single — recenter · double — camera view · long — center on gaze\n"
            + "Mouse: move — panel · click — select · right-drag — tilt scene · wheel — file list\n"
            + "Touchpad: same — two fingers scroll the list, a two-finger press "
            + "with a drag tilts the scene")
        footer.font = .systemFont(ofSize: 11.5)
        footer.textColor = .tertiaryLabelColor

        for v in [grid, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        win.makeKeyAndOrderFront(nil)
        controlWindow = win

        updateControlStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateControlStatus()
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // Current values of all settings — pushed to the remote once a second
    private func updateControlStatus() {
        guard let r = renderer, !controlValues.isEmpty else { return }
        func set(_ id: String, _ text: String) {
            controlValues[id]?.stringValue = text
        }

        if let v = r.video {
            set("file", v.url.lastPathComponent)
            var pos = "--:--", dur = "--:--"
            if let item = v.player.currentItem, item.duration.isNumeric {
                pos = Self.timeText(v.player.currentTime().seconds)
                dur = Self.timeText(item.duration.seconds)
            }
            set("pos", "\(pos) / \(dur) · \(v.player.rate == 0 ? "paused" : "playing")")
            set("vol", v.deviceVolume().map { "\(Int($0 * 100))% (headset)" }
                ?? "\(Int(v.player.volume * 100))%")
        } else {
            set("file", "not open")
            set("pos", "—")
            set("vol", "—")
        }
        set("rate", String(format: "%g×", r.playbackRate))

        let cfg = r.config
        set("proj", cfg.projection.label)
        set("stereo", cfg.stereo.label)
        set("flip", cfg.flipV < 0 ? "on" : "off")
        set("depth", cfg.depth == 0 ? "0 (default)" : String(format: "%+.3f", cfg.depth))
        set("fov", String(format: "%.0f°", cfg.fisheyeFovDeg))

        if let pt = r.passthrough {
            set("pt", pt.active ? "on" : (pt.available ? "off" : "unavailable"))
            set("ptmode", pt.source.label)
            set("ptconv", String(format: "%+.3f", pt.convergence))
            set("ptfov", "\(Int(pt.fovDeg))°")
        }

        set("track", r.tracker.connected ? "yes" : "NO")
        set("pred", r.tracker.predictionEnabled ? "on" : "off")
        set("look", "\(Int(r.tracker.extraLookaheadS * 1000)) ms")
        set("scan", r.scanlineEnabled ? "on" : "off")
        set("chrom", r.chromaticEnabled ? "on" : "off")
        set("vsync", ((playerView?.layer as? CAMetalLayer)?.displaySyncEnabled ?? true)
            ? "on" : "off")
    }

    // Watchdog: foreign windows that land on the headset display are moved to the monitor
    private func startWindowSweeper(vrScreen: NSScreen) {
        let deskScreen = NSScreen.screens.first { $0 != vrScreen } ?? vrScreen
        guard deskScreen != vrScreen else { return }
        // NSScreen (y up from the bottom of the main screen) -> CG (y down from the top)
        let primaryHeight = NSScreen.screens[0].frame.height
        func cgRect(_ f: NSRect) -> CGRect {
            CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        }
        let sweeper = WindowSweeper(
            vrFrame: cgRect(vrScreen.frame), targetFrame: cgRect(deskScreen.frame))
        sweeper.onStray = { [weak self] name, moved in
            if moved {
                self?.renderer.overlay?.showOSD("Window \"\(name)\" moved to the monitor", duration: 4)
                print("[sweeper] window \"\(name)\" moved from the headset screen to the monitor")
            } else {
                self?.renderer.overlay?.showOSD(
                    "Window \"\(name)\" opened on the headset screen (see log)", duration: 6)
                print("[sweeper] Window \"\(name)\" is on the headset screen. For auto-move, grant access:")
                print("[sweeper] Settings → Privacy & Security → Accessibility → \"+\" → PSVR2Player.app")
            }
        }
        sweeper.start()
        self.sweeper = sweeper
    }

    // macOS shows the system access prompt on the active window's screen.
    // Our window is in the headset, so while waiting we open a helper window
    // on the regular monitor: the dialog will appear there too.
    private func showAccessHelper() {
        window.level = .normal
        guard accessHelperWindow == nil else { return }

        let deskScreen = NSScreen.screens.first { !$0.localizedName.localizedCaseInsensitiveContains("PS VR2") }
            ?? NSScreen.main!
        let size = NSSize(width: 520, height: 150)
        let frame = NSRect(
            x: deskScreen.frame.midX - size.width / 2,
            y: deskScreen.frame.midY - size.height / 2,
            width: size.width, height: size.height)

        let helper = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false,
            screen: deskScreen)
        helper.title = "GAV PSVR2 Player — Disk Access"
        helper.level = .floating

        let label = NSTextField(wrappingLabelWithString:
            "Waiting for disk access.\n\n"
            + "Allow access in the system prompt if it appeared. "
            + "If there is no prompt, press the button below: \"Full Disk Access\" "
            + "and the app folder will open. Add PSVR2Player.app with the \"+\" button, "
            + "enable the toggle, then pick the disk again.")
        label.frame = NSRect(x: 20, y: 60, width: size.width - 40, height: size.height - 76)
        label.font = .systemFont(ofSize: 13)
        helper.contentView?.addSubview(label)

        let button = NSButton(title: "Open access settings", target: self,
                              action: #selector(openFullDiskAccess))
        button.frame = NSRect(x: 20, y: 16, width: 240, height: 32)
        button.bezelStyle = .rounded
        helper.contentView?.addSubview(button)

        helper.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        accessHelperWindow = helper
        print("[player] Access-waiting window opened on the monitor")
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        print("[player] Full Disk Access → \"+\" → \(Bundle.main.bundleURL.path)")
    }

    private func hideAccessHelper() {
        if let helper = accessHelperWindow {
            helper.orderOut(nil)
            accessHelperWindow = nil
        }
        window.level = .mainMenu + 1
        window.orderFrontRegardless()
        if let control = controlWindow {
            control.makeKeyAndOrderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            if let view = playerView {
                window.makeFirstResponder(view)
            }
        }
    }

    func loadVideo(_ url: URL) {
        guard let renderer else { return }
        renderer.video?.stop()
        let vs = VideoSource(url: url, device: renderer.device)
        vs.onUnsupported = { [weak renderer] message in
            renderer?.overlay?.showOSD(message, duration: 8)
        }
        vs.routeAudioToHeadset()
        // Restore the saved volume
        if let saved = UserDefaults.standard.object(forKey: "volume") as? Float {
            vs.player.volume = max(0, min(1, saved))
        }
        renderer.video = vs
        renderer.overlay?.setCurrentFile(url)
        renderer.config = PlaybackConfig.detect(from: url.lastPathComponent)
        renderer.playbackRate = 1.0 // rate is situational; a new file starts at 1×

        // Resume from the last position if the file was watched before
        if let resume = ResumeStore.position(for: url), resume > 15 {
            vs.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            let s = Int(resume)
            let ts = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                : String(format: "%d:%02d", s / 60, s % 60)
            renderer.overlay?.showOSD("Resuming from \(ts)", duration: 3)
            print("[player] resuming from \(ts)")
        }

        vs.player.rate = renderer.playbackRate
        let config = renderer.config
        print("[player] File: \(url.lastPathComponent)")
        print("[player] Projection: \(config.projection.label), \(config.stereo.label)"
            + (config.projection == .fisheye ? ", FOV \(config.fisheyeFovDeg)°" : ""))
    }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.video?.savePosition()
        renderer?.overlay?.hide()
        if let link = cvLink {
            CVDisplayLinkStop(link)
        }
        psvr2_stop()
    }
}

// MARK: - Startup

setbuf(stdout, nil)
setbuf(stderr, nil)

// Launched from Finder/Dock: no terminal, so write the log to a file.
// Watch it: tail -f ~/Library/Logs/PSVR2Player.log or the Console app
if isatty(STDOUT_FILENO) == 0 {
    let logPath = ("~/Library/Logs/PSVR2Player.log" as NSString).expandingTildeInPath
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    print("[player] Started \(Date()); log: \(logPath)")
}

let args = CommandLine.arguments
// With no argument, the file is chosen via the in-headset panel after launch
let url: URL? = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(videoURL: url)
app.delegate = delegate
app.run()
