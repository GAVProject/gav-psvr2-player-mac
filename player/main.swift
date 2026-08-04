// PSVR2 Player — просмотр 180°/360° видео в PlayStation VR2 на macOS.
//
// Видео выводится на дисплей шлема (4000x2040, side-by-side), ориентация головы
// читается из SLAM-потока шлема по USB (см. cpsvr2.c), дисторсия линз
// корректируется по калибровке конкретного экземпляра шлема.
//
// Клавиши: Space — пауза, R — рецентр, F — проекция, G — стерео-раскладка,
// V — вертикальный флип, стрелки — перемотка, +/- — FOV fisheye, Q — выход.

import AppKit
import AVFoundation
import CoreAudio
import Metal
import MetalKit
import simd

// MARK: - Метал-шейдер

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
    // uv: (0,0) — левый верх экрана, y вниз
    o.uv = float2(p[vid].x * 0.5 + 0.5, 1.0 - (p[vid].y * 0.5 + 0.5));
    return o;
}

struct Uniforms {
    float4x4 rot;
    float4 calibL;   // k1,k2,k3,k4 левого глаза
    float4 calibR;
    float4 p0;       // mode, stereo, fisheyeFovRad, flipV
    float4 p1;       // гироскоп в мировых осях (xyz) + длительность развёртки (w), с
    float4 p2;       // x: хроматика, y: панель UI видима, zw: курсор (uv текстуры панели)
    float4 p3;       // панель в tan-пространстве: центр (xy), полуразмеры (zw)
};

constant float FX = 0.3585564;
constant float FY = 0.3762281;
constant float PI = 3.14159265358979;

static float2 project_dir(float3 w, int mode, int stereo, int eye, float fovRad, thread bool &valid) {
    float u, v;
    valid = true;
    if (mode == 2) {
        // равноудалённый fisheye, ось вперёд -Z
        float cosT = clamp(-w.z, -1.0, 1.0);
        float theta = acos(cosT);
        if (theta > fovRad * 0.5) { valid = false; return float2(0.0); }
        float2 xy = w.xy;
        float len = length(xy);
        float2 d = len > 1e-6 ? xy / len : float2(0.0);
        float r = theta / fovRad;   // 0..0.5 на краю
        u = 0.5 + r * d.x;
        v = 0.5 - r * d.y;
    } else {
        float lon = atan2(w.x, -w.z);
        float lat = asin(clamp(w.y, -1.0, 1.0));
        if (mode == 1) {
            // полу-эквирект 180°
            if (fabs(lon) > PI * 0.5) { valid = false; return float2(0.0); }
            u = lon / PI + 0.5;
        } else {
            u = lon / (2.0 * PI) + 0.5;
        }
        v = 0.5 - lat / PI;
    }
    if (stereo == 1) {
        u = u * 0.5 + (eye == 1 ? 0.5 : 0.0);
    } else if (stereo == 2) {
        v = v * 0.5 + (eye == 1 ? 0.5 : 0.0);
    }
    return float2(u, v);
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        constant Uniforms &uni [[buffer(0)]],
                        device const packed_float3 *lut [[buffer(1)]],
                        texture2d<float> video [[texture(0)]],
                        texture2d<float> ui [[texture(1)]]) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

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

    // Поправка на развёртку: панель сканируется сверху вниз, строка uv.y
    // видит позу со сдвигом по времени относительно середины кадра
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

        // За пределами области рендера (uv глаза вне [0,1]) — чёрный
        float uvx = tanx * FX + cxTan;
        float uvy = tanyDown * FY + 0.5;
        if (uvx < 0.0 || uvx > 1.0 || uvy < 0.0 || uvy > 1.0) {
            continue;
        }

        float3 dir = normalize(float3(tanx, -tanyDown * flipV, -1.0));
        float3 w = (uni.rot * float4(dir, 0.0)).xyz;
        w = normalize(w + cross(gyroW, w) * rowTime);

        bool valid;
        float2 uv = project_dir(w, mode, stereo, eye, fovRad, valid);
        if (!valid) {
            continue;
        }
        if (chromatic) {
            rgb[ch] = video.sample(smp, uv)[ch];
        } else {
            rgb = video.sample(smp, uv).rgb;
        }
    }

    // Панель управления: висит перед глазами (~1.5 м, лёгкий параллакс),
    // координаты по зелёному каналу без флипа видео
    if (uni.p2.y > 0.5) {
        float aG = local_x * scale[1];
        float bG = (local_y - 0.0002302693) * scale[1];
        float panelTanX = k3 * aG - k4 * bG;
        float panelTanUp = -(k4 * aG + k3 * bG);

        float disp = eye == 0 ? 0.021 : -0.021;
        float2 pc = uni.p3.xy;
        float2 ph = uni.p3.zw;
        float pu = (panelTanX - disp - pc.x) / (2.0 * ph.x) + 0.5;
        float pv = (panelTanUp - pc.y) / (2.0 * ph.y) + 0.5;
        if (pu >= 0.0 && pu <= 1.0 && pv >= 0.0 && pv <= 1.0) {
            float2 tuv = float2(pu, 1.0 - pv);
            float4 uiC = ui.sample(smp, tuv);

            // Виртуальный курсор: белая точка с тёмной обводкой
            float2 dvec = (tuv - uni.p2.zw) * float2(2.0, 1.0); // аспект панели 2:1
            float dcur = length(dvec);
            if (dcur < 0.014) {
                uiC = float4(1.0, 1.0, 1.0, 1.0);
            } else if (dcur < 0.020) {
                uiC = float4(0.0, 0.0, 0.0, 1.0);
            }

            rgb = rgb * (1.0 - uiC.a) + uiC.rgb; // premultiplied alpha
        }
    }

    return float4(rgb, 1.0);
}
"""#

// MARK: - Настройки воспроизведения

enum Projection: Int32, CaseIterable {
    case equirect360 = 0
    case equirect180 = 1
    case fisheye = 2

    var label: String {
        switch self {
        case .equirect360: return "равнопромежуточная 360°"
        case .equirect180: return "полу-эквирект 180°"
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
        case .mono: return "моно"
        case .sbs: return "стерео SBS"
        case .tb: return "стерео верх/низ"
        }
    }
}

struct PlaybackConfig {
    var projection = Projection.equirect180
    var stereo = StereoLayout.sbs
    var fisheyeFovDeg: Float = 190
    var flipV: Float = 1

    // Угадать формат по имени файла
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

// MARK: - Трекинг головы

final class HeadTracker {
    private var recenter = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var didAutoRecenter = false
    private let correction = simd_quatf(ix: 0, iy: 0, iz: sqrt(0.5), r: sqrt(0.5))
    var connected = false
    var predictionEnabled = true
    // Задержка вывода: рендер + сканаут дисплея (настраивается [ и ])
    var extraLookaheadS: Float = 0.010

    // Ориентация в системе x-вправо, y-вверх, -z-вперёд (оси Monado)
    private func currentOrientation() -> simd_quatf? {
        // SLAM обновляется ~60 Гц, рендер — 120 Гц: C-ядро доинтегрирует позу
        // IMU-сэмплами (2000 Гц) и экстраполирует на задержку вывода
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

    func requestRecenter() {
        didAutoRecenter = false
    }

    // Угловая скорость в мировой (уже отрецентренной) системе — для
    // построчной коррекции развёртки в шейдере
    private(set) var worldAngularVelocity = SIMD3<Float>(repeating: 0)

    func viewRotation() -> float4x4 {
        guard let q = currentOrientation() else {
            connected = false
            return matrix_identity_float4x4
        }
        connected = true

        if !didAutoRecenter {
            // Убираем только рысканье (yaw), сохраняя горизонт
            let f = q.act(SIMD3<Float>(0, 0, -1))
            let yaw = atan2(-f.x, -f.z)
            recenter = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
            didAutoRecenter = true
        }

        let view = recenter * q

        var gyro = [Float](repeating: 0, count: 3)
        var age: Double = 0
        if psvr2_get_motion(&gyro, &age) == 1 {
            // Гироскоп в осях тела -> мировые оси текущего вида
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
    var calibL: SIMD4<Float>
    var calibR: SIMD4<Float>
    var p0: SIMD4<Float>
    var p1: SIMD4<Float> // гироскоп в мировых осях (xyz) + длительность развёртки, с
    var p2: SIMD4<Float> // хроматика, панель видима, курсор uv
    var p3: SIMD4<Float> // панель: центр и полуразмеры в tan-пространстве
}

// MARK: - Видео

final class VideoSource {
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    private(set) var texture: MTLTexture?
    private(set) var audioDeviceID: AudioDeviceID?

    init(url: URL, device: MTLDevice) {
        let item = AVPlayerItem(url: url)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
        }
    }

    func routeAudioToHeadset() {
        // Ищем аудиовыход "PS VR2" через CoreAudio и направляем звук туда
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
                    print("[audio] Звук направлен в шлем: \(name)")
                }
                return
            }
        }
    }

    // «Виртуальная» системная громкость устройства ('vmvc') — ей управляет
    // ползунок в настройках звука, когда у USB-устройства нет своего регулятора
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'

    // Пары (селектор, элемент) в порядке предпочтения: аппаратный регулятор,
    // поканальный, затем виртуальная громкость macOS
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
                    break // главный или виртуальный регулятор достаточно установить один раз
                }
            }
        }
        return ok
    }

    func updateTexture() {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let cache = textureCache else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let res = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        if res == kCVReturnSuccess, let cvTex, let mtl = CVMetalTextureGetTexture(cvTex) {
            texture = mtl
        }
    }
}

// MARK: - Рендерер

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let lutBuffer: MTLBuffer
    let placeholder: MTLTexture
    let tracker = HeadTracker()
    var video: VideoSource?
    var config: PlaybackConfig
    var calibration: [Float]
    var chromaticEnabled = true
    var scanlineEnabled = true
    var overlay: UIOverlay!
    // Панель UI в tan-пространстве: центр и полуразмеры (аспект 2:1 как текстура)
    let panelCenter = SIMD2<Float>(0, -0.05)
    let panelHalf = SIMD2<Float>(0.5, 0.25)
    // Развёртка панели: 2040/2200 строки кадра при 120 Гц (из драйвера Monado)
    let scanoutDuration: Float = (1.0 / 120.0) * (2040.0 / 2200.0)

    // Диагностика
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

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        texDesc.usage = [.shaderRead]
        placeholder = device.makeTexture(descriptor: texDesc)!
        var gray = [UInt8](repeating: 60, count: 2 * 2 * 4)
        placeholder.replace(
            region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &gray, bytesPerRow: 8)

        super.init()
    }

    private var lastButton = false

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Кнопка Fn на шлеме — рецентр (по фронту нажатия)
        let button = psvr2_get_button() == 1
        if button && !lastButton {
            tracker.requestRecenter()
            print("[player] рецентр (кнопка шлема)")
        }
        lastButton = button

        overlay?.tick()
        video?.updateTexture()

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let rot = tracker.viewRotation()
        let gyroW = scanlineEnabled ? tracker.worldAngularVelocity : .zero
        var uni = Uniforms(
            rot: rot,
            calibL: SIMD4(calibration[0], calibration[1], calibration[4], calibration[5]),
            calibR: SIMD4(calibration[2], calibration[3], calibration[6], calibration[7]),
            p0: SIMD4(
                Float(config.projection.rawValue),
                Float(config.stereo.rawValue),
                config.fisheyeFovDeg * .pi / 180,
                config.flipV),
            p1: SIMD4(gyroW.x, gyroW.y, gyroW.z, scanoutDuration),
            p2: SIMD4(
                chromaticEnabled ? 1 : 0,
                (overlay?.active ?? false) ? 1 : 0,
                Float(overlay?.cursorU ?? 0.5),
                Float(overlay?.cursorV ?? 0.5)),
            p3: SIMD4(panelCenter.x, panelCenter.y, panelHalf.x, panelHalf.y))

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBuffer(lutBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(video?.texture ?? placeholder, index: 0)
        enc.setFragmentTexture(overlay?.texture ?? placeholder, index: 1)
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
            print(String(format: "[stat] fps=%.1f gpu=%.2fмс (бюджет 8.3мс на 120Гц)", fps, gpuMs))
            statFrames = 0
            statGpuTime = 0
            statLastReport = now
        }
    }
}

// MARK: - Окно и клавиатура

final class PlayerView: MTKView {
    var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let r = renderer else { return }
        switch event.keyCode {
        case 12, 53: // Q, Esc
            print("[player] выход")
            r.overlay?.hide() // вернуть системный курсор
            r.video?.player.pause()
            psvr2_stop()
            exit(0)
        case 49: // Space
            togglePause()
        case 15: // R
            r.tracker.requestRecenter()
            print("[player] рецентр")
        case 3: // F
            cycleProjection()
        case 5: // G
            cycleStereo()
        case 9: // V
            r.config.flipV *= -1
            print("[player] вертикальный флип: \(r.config.flipV < 0 ? "вкл" : "выкл")")
        case 123: // ←
            seek(by: -15)
        case 124: // →
            seek(by: 15)
        case 126: // ↑
            changeVolume(by: 0.1)
        case 125: // ↓
            changeVolume(by: -0.1)
        case 35: // P
            r.tracker.predictionEnabled.toggle()
            print("[player] предсказание позы: \(r.tracker.predictionEnabled ? "вкл" : "выкл")")
        case 1: // S
            r.scanlineEnabled.toggle()
            print("[player] коррекция развёртки: \(r.scanlineEnabled ? "вкл" : "выкл")")
        case 8: // C
            r.chromaticEnabled.toggle()
            print("[player] хроматическая коррекция: \(r.chromaticEnabled ? "вкл" : "выкл")")
        case 2: // D
            if let layer = self.layer as? CAMetalLayer {
                layer.displaySyncEnabled.toggle()
                print("[player] vsync презентации: \(layer.displaySyncEnabled ? "вкл" : "выкл")")
            }
        case 30: // ]
            r.tracker.extraLookaheadS = min(0.08, r.tracker.extraLookaheadS + 0.005)
            print("[player] упреждение позы: \(Int(r.tracker.extraLookaheadS * 1000)) мс")
        case 33: // [
            r.tracker.extraLookaheadS = max(0, r.tracker.extraLookaheadS - 0.005)
            print("[player] упреждение позы: \(Int(r.tracker.extraLookaheadS * 1000)) мс")
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
        r.config.fisheyeFovDeg += delta
        if r.config.projection == .fisheye {
            print("[player] fisheye FOV: \(r.config.fisheyeFovDeg)°")
        } else {
            print("[player] fisheye FOV: \(r.config.fisheyeFovDeg)° — влияет только на проекцию fisheye (переключи клавишей F)")
        }
    }

    private func changeVolume(by delta: Float) {
        guard let video = renderer?.video else { return }

        // Сначала крутим аппаратную громкость USB-аудио шлема, если она есть
        if let current = video.deviceVolume() {
            let target = max(0, min(1, current + delta))
            if video.setDeviceVolume(target) {
                video.player.volume = 1
                print("[player] громкость шлема (аппаратная): \(Int(target * 100))%")
                return
            }
        }

        let p = video.player
        p.volume = max(0, min(1, p.volume + delta))
        print("[player] громкость плеера: \(Int(p.volume * 100))%")
    }

    private func seek(by seconds: Double) {
        guard let p = renderer?.video?.player else { return }
        let target = CMTimeAdd(p.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    }

    private func togglePause() {
        guard let p = renderer?.video?.player else { return }
        p.rate == 0 ? p.play() : p.pause()
        print("[player] \(p.rate == 0 ? "пауза" : "воспроизведение")")
    }

    private func cycleProjection() {
        guard let r = renderer else { return }
        let all = Projection.allCases
        let next = all[(all.firstIndex(of: r.config.projection)! + 1) % all.count]
        r.config.projection = next
        print("[player] проекция: \(next.label)")
    }

    private func cycleStereo() {
        guard let r = renderer else { return }
        let all = StereoLayout.allCases
        let next = all[(all.firstIndex(of: r.config.stereo)! + 1) % all.count]
        r.config.stereo = next
        print("[player] стерео: \(next.label)")
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

    func perform(uiAction: UIAction) {
        guard let r = renderer else { return }
        switch uiAction {
        case .playPause: togglePause()
        case .seekBack: seek(by: -15)
        case .seekFwd: seek(by: 15)
        case .seekBack30: seek(by: -30)
        case .seekFwd30: seek(by: 30)
        case .volDown: changeVolume(by: -0.1)
        case .volUp: changeVolume(by: 0.1)
        case .recenter:
            r.tracker.requestRecenter()
            print("[player] рецентр")
        case .cycleProjection: cycleProjection()
        case .cycleStereo: cycleStereo()
        }
    }
}

// Безрамочное окно по умолчанию не принимает клавиатуру — разрешаем явно
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    var keyMonitor: Any?
    var cvLink: CVDisplayLink?
    var playerView: PlayerView?
    let videoURL: URL?

    init(videoURL: URL?) {
        self.videoURL = videoURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // USB-трекинг
        var calibration = [Float](repeating: 0, count: 8)
        if psvr2_start() == 0 {
            print("[usb] PSVR2 подключён, SLAM-трекинг запущен")
            psvr2_get_distortion_calibration(&calibration)
            print("[usb] Калибровка дисторсии: \(calibration)")
            psvr2_set_brightness(1.0)
        } else {
            print("[usb] !!! Шлем не найден по USB — рендер без трекинга")
            calibration = [-0.09919293, 0, 0.09919293, 0, 1, 0, 1, 0]
        }
        if calibration[4] == 0 && calibration[6] == 0 {
            // Старая версия калибровки: k3/k4 не заданы — единичный поворот
            calibration[4] = 1
            calibration[6] = 1
        }

        // Экран шлема
        let vrScreen = NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("PS VR2")
                || ($0.frame.width * $0.backingScaleFactor) == 4000
        }
        let screen = vrScreen ?? NSScreen.main!
        if vrScreen == nil {
            print("[display] !!! Дисплей PS VR2 не найден — вывод в окно на основном экране")
        } else {
            print("[display] Дисплей PS VR2: \(screen.frame)")
        }

        let device = MTLCreateSystemDefaultDevice()!

        var config = PlaybackConfig()
        if let url = videoURL {
            config = PlaybackConfig.detect(from: url.lastPathComponent)
        }

        renderer = try! Renderer(device: device, config: config, calibration: calibration)

        // Панель управления в шлеме (появляется при движении мыши)
        let overlay = UIOverlay(device: device)
        overlay.renderer = renderer
        overlay.captureEnabled = vrScreen != nil
        let primaryHeight = NSScreen.screens[0].frame.height
        overlay.warpPoint = CGPoint(x: screen.frame.midX, y: primaryHeight - screen.frame.midY)
        renderer.overlay = overlay

        if let url = videoURL {
            let vs = VideoSource(url: url, device: device)
            vs.routeAudioToHeadset()
            renderer.video = vs
            print("[player] Файл: \(url.lastPathComponent)")
            print("[player] Проекция: \(config.projection.label), \(config.stereo.label)"
                + (config.projection == .fisheye ? ", FOV \(config.fisheyeFovDeg)°" : ""))
        }

        let view = PlayerView(frame: screen.frame, device: device)
        view.renderer = renderer
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        // Внутренний таймер MTKView может тикать от другого (60 Гц) дисплея —
        // рисуем сами от CADisplayLink, привязанного к экрану окна
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        playerView = view

        if vrScreen != nil {
            window = KeyableWindow(
                contentRect: screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false, screen: screen)
            window.level = .mainMenu + 1
            window.setFrame(screen.frame, display: true)
        } else {
            let rect = NSRect(x: 100, y: 100, width: 1000, height: 510)
            window = NSWindow(
                contentRect: rect, styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "PSVR2 Player (предпросмотр)"
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Подстраховка: ловим клавиши на уровне приложения, даже если окно
        // на дисплее шлема не в фокусе
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            view.keyDown(with: event)
            return nil
        }

        // Пейсинг от конкретного дисплея шлема через CVDisplayLink:
        // CADisplayLink/MTKView могут тикать от другого (60 Гц) экрана
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
        let displayID = CGDirectDisplayID(truncating: screenNumber)
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            print("[display] Частота дисплея шлема по CoreGraphics: \(mode.refreshRate) Гц, "
                + "maxFPS экрана: \(screen.maximumFramesPerSecond)")
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
            print("[display] !!! CVDisplayLink не создался — падаю обратно на таймер MTKView")
            view.isPaused = false
        }

        renderer.video?.player.play()
        print("[player] Управление: Space пауза · R или кнопка Fn шлема — рецентр · F проекция · G стерео · V флип")
        print("[player]             ←/→ ±15с · ↑/↓ громкость · +/- FOV fisheye · Q выход")
        print("[player]             отладка: P предсказание · [/] упреждение · S развёртка · C хроматика")
    }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.overlay?.hide()
        if let link = cvLink {
            CVDisplayLinkStop(link)
        }
        psvr2_stop()
    }
}

// MARK: - Запуск

setbuf(stdout, nil)
setbuf(stderr, nil)

let args = CommandLine.arguments
var url: URL?
if args.count > 1 {
    url = URL(fileURLWithPath: args[1])
} else {
    let panel = NSOpenPanel()
    panel.title = "Выберите 180/360 видео"
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    if panel.runModal() == .OK {
        url = panel.url
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(videoURL: url)
app.delegate = delegate
app.run()
