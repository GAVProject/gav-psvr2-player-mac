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
import VideoToolbox
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
    float4x4 panelInv; // мир -> система панели (якорь взгляда в момент показа)
    float4 calibL;   // k1,k2,k3,k4 левого глаза
    float4 calibR;
    float4 p0;       // mode, stereo, fisheyeFovRad, flipV
    float4 p1;       // гироскоп в мировых осях (xyz) + длительность развёртки (w), с
    float4 p2;       // x: хроматика, y: панель UI видима, zw: курсор (uv текстуры панели)
    float4 p3;       // панель в tan-пространстве: центр (xy), полуразмеры (zw)
    float4 p4;       // x: есть видео, y: полный диапазон YUV, z: BT.2020, w: кадр BGRA
    float4 p5;       // x: passthrough вкл, y: FOV камер (рад), z: яркость, w: режим камер
    float4 p6;       // x: конвергенция камер (доли кадра)
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

// Кадры берём в родном YUV 4:2:0 (втрое меньше памяти, чем BGRA: для 8K
// это критично) и переводим в RGB здесь
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
            sampled = float3(0.16); // фон, когда файл не открыт
        }

        if (chromatic) {
            rgb[ch] = sampled[ch];
        } else {
            rgb = sampled;
        }
    }

    // Passthrough: вид с передних камер шлема. Камеры жёстко связаны с
    // корпусом, поэтому поза головы не применяется — картинка стоит в поле
    // зрения. Модель объектива — равноудалённая (fisheye), FOV настраивается.
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
            // p5.w: 0 — левая камера на оба глаза, 1 — правая, 2 — стерео.
            // p6.x — конвергенция: сдвиг картинок навстречу, компенсирует
            // разнос камер (он шире межзрачкового)
            int camMode = int(uni.p5.w);
            bool stereoMode = camMode == 2;
            bool useR = camMode == 1 || (stereoMode && eye == 1);
            float shift = stereoMode ? (eye == 0 ? uni.p6.x : -uni.p6.x) : 0.0;

            // Кадр 1016x1016 лежит в текстуре шириной 1024
            float u = (0.5 + r * d.x + shift) * (1016.0 / 1024.0);
            float v = 0.5 - r * d.y;
            float g = useR ? camR.sample(smp, float2(u, v)).r
                           : camL.sample(smp, float2(u, v)).r;
            rgb = float3(saturate(g * uni.p5.z));
        } else {
            rgb = float3(0.0);
        }
    }

    // Панель управления: закреплена в пространстве по направлению взгляда
    // в момент показа (~1.5 м, лёгкий параллакс). Направление луча переводим
    // текущей позой в мир, затем в систему панели; координаты по зелёному
    // каналу без флипа видео
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

    var shortLabel: String {
        switch self {
        case .mono: return "моно"
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

    // Ручная подстройка вида (перетаскивание сцены правой кнопкой):
    // только наклон вперёд/назад. Горизонтальное выравнивание делает рецентр,
    // а ручное рысканье в сочетании с наклоном геометрически рождает крен
    // и «перелёт через полюс» — поэтому его нет.
    // Мышь задаёт цель, кадры плавно подтягиваются slerp-доводчиком
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

    // Полный рецентр (долгое нажатие Fn): центр видео — ровно туда, куда
    // сейчас направлен взгляд, включая наклон головы. Для просмотра лёжа
    func requestFullRecenter() {
        guard let q = currentOrientation() else {
            requestRecenter()
            return
        }
        let f = q.act(SIMD3<Float>(0, 0, -1))
        let yaw = atan2(-f.x, -f.z)
        recenter = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
        didAutoRecenter = true
        // Компенсируем наклон головы ручным наклоном сцены
        manualPitch = max(-1.4, min(1.4, -asin(max(-1, min(1, f.y)))))
        offsetTarget = simd_quatf(angle: manualPitch, axis: SIMD3<Float>(1, 0, 0))
        offsetCurrent = offsetTarget
    }

    func addManualRotation(dxPx: Double, dyPx: Double) {
        _ = dxPx // горизонталь намеренно игнорируется
        let sens: Float = 0.002 // рад на пиксель (~0.11°)
        // Наклон ограничен ~±80°
        manualPitch = max(-1.4, min(1.4, manualPitch + Float(dyPx) * sens))
        offsetTarget = simd_quatf(angle: manualPitch, axis: SIMD3<Float>(1, 0, 0))
    }

    private func smoothManual() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastSmoothTime))
        lastSmoothTime = now
        // Экспоненциальный доводчик, ~90 мс до цели
        let alpha = 1 - expf(-dt * 12)
        offsetCurrent = simd_slerp(offsetCurrent, offsetTarget, alpha)
    }

    // Угловая скорость в мировой (уже отрецентренной) системе — для
    // построчной коррекции развёртки в шейдере
    private(set) var worldAngularVelocity = SIMD3<Float>(repeating: 0)

    // Последняя поза вида — для якоря панели UI
    private(set) var viewQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    func viewRotation() -> float4x4 {
        guard let q = currentOrientation() else {
            connected = false
            viewQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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

        smoothManual()
        let view = offsetCurrent * recenter * q
        viewQuat = view

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
    var panelInv: float4x4 // мир -> система панели (якорь в момент показа)
    var calibL: SIMD4<Float>
    var calibR: SIMD4<Float>
    var p0: SIMD4<Float>
    var p1: SIMD4<Float> // гироскоп в мировых осях (xyz) + длительность развёртки, с
    var p2: SIMD4<Float> // хроматика, панель видима, курсор uv
    var p3: SIMD4<Float> // панель: центр и полуразмеры в tan-пространстве
    var p4: SIMD4<Float> // есть видео, полный диапазон YUV, BT.2020
    var p5: SIMD4<Float> // passthrough вкл, FOV камер (рад), яркость, режим камер
    var p6: SIMD4<Float> // конвергенция камер
}

// MARK: - Видео

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
    // Не все файлы отдают кадры в запрошенном формате: если кадров нет,
    // по очереди пробуем другие варианты
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
        // Родной YUV: втрое меньше памяти, важно для 8K
        .attributes([
            kCVPixelBufferPixelFormatTypeKey as String: yuvFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]),
        // MV-HEVC (стереовидео Apple/DeoVR): без явного запроса слоя
        // декодер может не отдавать кадры вовсе
        .settings([
            kCVPixelBufferPixelFormatTypeKey as String: yuvFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoDecompressionPropertiesKey: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: [0],
            ],
        ]),
        // Только 8-битный YUV
        .attributes([
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]),
        // Пусть система выберет сама
        .attributes([kCVPixelBufferMetalCompatibilityKey as String: true]),
        .attributes(nil),
    ]

    init(url: URL, device: MTLDevice) {
        self.url = url
        let item = AVPlayerItem(url: url)
        // Без пережатия высоты тона звук на скоростях ≠ 1× превращается в писк
        item.audioTimePitchAlgorithm = .timeDomain
        output = Self.makeOutput(attempt: 0)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // В конце файла — стоп и перемотка в начало (без повтора);
        // «Играть» запустит с начала
        describeTracks(item.asset)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            print("[player] конец файла")
            if let self {
                ResumeStore.set(nil, for: self.url) // досмотрен — с начала
            }
        }

        // Периодически запоминаем позицию, чтобы продолжить с неё в другой раз
        saveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.savePosition()
        }
    }

    private var saveTimer: Timer?

    func savePosition() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let t = player.currentTime().seconds
        let d = item.duration.seconds
        guard t.isFinite, d > 60 else { return } // короткие ролики не запоминаем
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
                print("[video] Видеодорожка не найдена")
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
                    // Признак многослойного (стерео) HEVC
                    if exts.keys.contains(where: { $0.contains("Heroes") || $0.contains("MVHEVC") }) {
                        extra += ", MV-HEVC"
                    }
                    if let tags = exts["\(kCMFormatDescriptionExtension_ProjectionKind)"] {
                        extra += ", проекция \(tags)"
                    }
                }
                extra += ", слоёв: \(formats.count)"
            }

            print("[video] Дорожка: \(codec), \(Int(size.width))x\(Int(size.height)), "
                + "\(String(format: "%.0f", fps)) fps, "
                + "декодируется: \(decodable ? "да" : "НЕТ"), "
                + "воспроизводима: \(playable ? "да" : "НЕТ")\(extra)")

            // hev1 хранит параметры кодека внутри потока — AVFoundation такое
            // не декодирует, нужна перепаковка в hvc1 (без пережатия)
            if codec == "hev1" || !decodable {
                let hint = codec == "hev1"
                    ? "Формат hev1 не поддерживается macOS. Перепакуйте без потерь:"
                    : "Видеодорожка не декодируется. Возможно, поможет перепаковка:"
                print("[video] \(hint)")
                print("[video]   tools/fix-hev1 \"\(self.url.path)\"")
                await MainActor.run {
                    self.onUnsupported?(codec == "hev1"
                        ? "Формат hev1 не поддерживается — нужна перепаковка (см. лог)"
                        : "Видео не декодируется (см. лог)")
                }
            }
        }
    }

    // Явная остановка при замене файла
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
        // Диагностика: если эта строка не появляется при смене файла —
        // старый источник кто-то держит
        print("[video] источник освобождён: \(url.lastPathComponent)")
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
        // Без проверки hasNewPixelBuffer: часть файлов отдаёт кадры,
        // не сообщая о них через этот флаг
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
                + "\(fourCC), \(tenBit ? "10 бит" : "8 бит"), "
                + "\(fullRange ? "full" : "video") range, \(bt2020 ? "BT.2020" : "BT.709")")
        }

        // Непланарный кадр (BGRA) — читаем как RGB, YUV-преобразование не нужно
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
            print("[video] не удалось создать текстуру плоскости \(plane): код \(res)")
            return nil
        }
        return CVMetalTextureGetTexture(cvTex)
    }

    // Кадров нет — пробуем следующий формат пикселей
    private func retryOtherFormatIfNeeded() {
        guard !gotAnyFrame, player.rate != 0,
              CACurrentMediaTime() - noFrameSince > 2,
              let item = player.currentItem else { return }
        noFrameSince = CACurrentMediaTime()

        guard formatAttempt + 1 < Self.formatAttempts.count else {
            print("[video] Кадры не поступают ни в одном из форматов. Статус: "
                + "\(item.status.rawValue)"
                + (item.error.map { ", ошибка: \($0.localizedDescription)" } ?? ""))
            gotAnyFrame = true // больше не пробуем
            return
        }

        formatAttempt += 1
        item.remove(output)
        output = Self.makeOutput(attempt: formatAttempt)
        item.add(output)
        loggedFormat = false
        print("[video] Кадров нет — переключаюсь на формат №\(formatAttempt + 1)")
    }
}

// MARK: - Рендерер

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let lutBuffer: MTLBuffer
    let placeholderY: MTLTexture
    let placeholderCbCr: MTLTexture
    let tracker = HeadTracker()
    var video: VideoSource?
    var config: PlaybackConfig
    var calibration: [Float]
    var chromaticEnabled = true
    var scanlineEnabled = true
    var overlay: UIOverlay!
    // Скорость воспроизведения; при открытии нового файла сбрасывается на 1×
    var playbackRate: Float = 1.0
    // Вид с камер шлема (двойное нажатие Fn или клавиша B)
    var passthrough: PassthroughSource?
    private var pausedByPassthrough = false
    // Панель UI в tan-пространстве: центр и полуразмеры (аспект 2:1 как текстура)
    let panelCenter = SIMD2<Float>(0, -0.05)
    let panelHalf = SIMD2<Float>(0.5, 0.25)
    // Якорь панели в мире: направление взгляда (yaw+pitch, без крена)
    // в момент показа
    private var panelAnchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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
    }

    private var lastButton = false
    private var buttonDownTime = 0.0
    private var buttonLongFired = false
    private var pendingSingleClick = false
    private var lastClickTime = 0.0
    // Автопауза по датчику приближения (шлем снят/надет), с дебаунсом
    private var wornState = true
    private var lastProxRaw = true
    private var proxRawSince = CACurrentMediaTime()
    private var autoPaused = false

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func setPlaybackRate(_ v: Float) {
        playbackRate = v
        if let p = video?.player, p.rate != 0 {
            p.rate = v
        }
        overlay?.showOSD(String(format: "Скорость %g×", v))
        print(String(format: "[player] скорость: %g×", v))
    }

    // Вид с камер: видео паузим, чтобы не пропустить кусок
    func togglePassthrough() {
        guard let pt = passthrough, pt.available else {
            overlay?.showOSD("Камеры недоступны")
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
            overlay?.showOSD("Камеры не запустились (см. лог)")
            return
        }
        if let p = video?.player, p.rate != 0 {
            p.pause()
            pausedByPassthrough = true
        }
        // Никаких плашек и панели поверх камер: чистый вид на комнату
        overlay?.hide()
        overlay?.clearOSD()
    }

    // Закрепить панель перед текущим взглядом (горизонт сохраняем)
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
        // Состояние принимается после 0.4 с стабильности
        guard raw != wornState, now - proxRawSince > 0.4 else { return }
        wornState = raw

        guard let player = video?.player else { return }
        if !wornState {
            if player.rate != 0 {
                player.pause()
                autoPaused = true
                print("[player] шлем снят — пауза")
            }
        } else if autoPaused {
            player.play()
            autoPaused = false
            print("[player] шлем надет — продолжаем")
        }
    }

    func draw(in view: MTKView) {
        // Кнопка Fn на шлеме: одиночное нажатие — рецентр (горизонт
        // сохраняется), двойное — вид с камер и обратно, долгое (>0.8 с) —
        // центр видео точно по направлению взгляда
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
            overlay?.showOSD("Центр — по направлению взгляда")
            print("[player] полный рецентр (долгое нажатие кнопки шлема)")
        }
        if !button && lastButton && !buttonLongFired {
            if pendingSingleClick && nowBtn - lastClickTime < 0.45 {
                pendingSingleClick = false // второй клик — двойное нажатие
                togglePassthrough()
                print("[player] вид с камер (двойное нажатие кнопки шлема)")
            } else {
                pendingSingleClick = true
                lastClickTime = nowBtn
            }
        }
        // Одиночное нажатие срабатывает, когда пары уже не будет
        if pendingSingleClick && nowBtn - lastClickTime > 0.45 {
            pendingSingleClick = false
            tracker.requestRecenter()
            print("[player] рецентр (кнопка шлема)")
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
        let gyroW = scanlineEnabled ? tracker.worldAngularVelocity : .zero

        // Панель закреплена в мире; одиночная плашка OSD — приклеена к взгляду
        // (panelInv * rot = I). Если панель ушла из виду дальше ~70° —
        // переносим её к текущему взгляду
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

        var uni = Uniforms(
            rot: rot,
            panelInv: panelInv,
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
                // Пока зажата ПКМ (вращение сцены), панель и курсор прячем
                (overlay?.displayVisible ?? false) && NSEvent.pressedMouseButtons & 0x2 == 0 ? 1 : 0,
                // Курсор показываем только с панелью (не с одной плашкой OSD)
                Float((overlay?.active ?? false) ? overlay!.cursorU : -10),
                Float((overlay?.active ?? false) ? overlay!.cursorV : -10)),
            p3: SIMD4(panelCenter.x, panelCenter.y, panelHalf.x, panelHalf.y),
            p4: SIMD4(
                video?.textureY != nil ? 1 : 0,
                (video?.fullRange ?? false) ? 1 : 0,
                (video?.bt2020 ?? false) ? 1 : 0,
                (video?.isBGRA ?? false) ? 1 : 0),
            p5: SIMD4(
                (passthrough?.gotFrame ?? false) ? 1 : 0,
                (passthrough?.fovDeg ?? 150) * .pi / 180,
                passthrough?.brightness ?? 1.6,
                Float(passthrough?.source.rawValue ?? 0)),
            p6: SIMD4(passthrough?.convergence ?? 0, 0, 0, 0))

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBuffer(lutBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(video?.textureY ?? placeholderY, index: 0)
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
            print(String(format: "[stat] fps=%.1f gpu=%.2fмс mem=%.0fМБ", fps, gpuMs, Self.memoryFootprintMB()))
            statFrames = 0
            statGpuTime = 0
            statLastReport = now
        }
    }

    // Физическая память процесса — для отлова утечек по логу
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

// MARK: - Окно и клавиатура

final class PlayerView: MTKView {
    var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }
    // Клики по неключевому окну шлема (ключевое окно — пульт на мониторе)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let r = renderer else { return }
        switch event.keyCode {
        case 12, 53: // Q, Esc
            print("[player] выход")
            r.overlay?.hide() // вернуть системный курсор
            r.video?.savePosition()
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
        case 11: // B — вид с камер шлема
            r.togglePassthrough()
        case 46: // M — режим камер: стерео / моно левая / моно правая
            guard let pt = r.passthrough, pt.active else { break }
            let all = PassthroughSource.Source.allCases
            pt.source = all[(all.firstIndex(of: pt.source)! + 1) % all.count]
            r.overlay?.showOSD(pt.source.label)
            print("[passthrough] режим: \(pt.source.label)")
        case 43, 47: // «,» и «.» — сведение картинок (компенсация разноса камер)
            guard let pt = r.passthrough, pt.active else { break }
            pt.convergence = max(-0.15, min(0.15,
                pt.convergence + (event.keyCode == 47 ? 0.005 : -0.005)))
            r.overlay?.showOSD(String(format: "Сведение: %+.3f", pt.convergence))
            print(String(format: "[passthrough] сведение: %+.3f", pt.convergence))
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
        // В режиме камер +/- подгоняют угол объектива под ощущение масштаба
        if let pt = r.passthrough, pt.active {
            pt.fovDeg = max(60, min(220, pt.fovDeg + delta))
            r.overlay?.showOSD("FOV камер: \(Int(pt.fovDeg))°")
            print("[passthrough] FOV камер: \(Int(pt.fovDeg))°")
            return
        }
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
        let percent = Int((p.volume * 100).rounded())
        UserDefaults.standard.set(p.volume, forKey: "volume")
        renderer?.overlay?.showOSD("Громкость \(percent)%")
        print("[player] громкость плеера: \(percent)%")
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

    override func rightMouseDragged(with event: NSEvent) {
        guard let r = renderer else { return }
        // «Хватаем» сцену: тянем картинку за курсором
        r.tracker.addManualRotation(dxPx: event.deltaX, dyPx: event.deltaY)
        r.overlay?.markActivity()
    }

    private var scrollAccum = 0.0

    override func scrollWheel(with event: NSEvent) {
        // Прокрутка списка файлов. Тачпад шлёт поток мелких дельт и добавляет
        // инерционный «выбег» после отрыва пальцев — от него список улетал бы
        // на десятки строк, поэтому фазу инерции пропускаем, а дельты
        // накапливаем до целой строки
        if event.momentumPhase != [] {
            return
        }
        // У тачпада дельты «точные» и в разы мельче щелчка колеса
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
            print("[player] рецентр")
        case .cycleProjection: cycleProjection()
        case .cycleStereo: cycleStereo()
        case .seekFraction(let f):
            guard let p = r.video?.player, let item = p.currentItem,
                  item.duration.isNumeric else { break }
            let target = CMTime(seconds: item.duration.seconds * f, preferredTimescale: 600)
            p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            print("[player] перемотка на \(Int(item.duration.seconds * f)) с")
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
    // Окно-пульт на обычном мониторе: держит клавиатурный фокус, чтобы
    // системные диалоги открывались на видимом экране, а не в шлеме
    var controlWindow: NSWindow?
    // Поля значений в таблице пульта, по идентификатору строки
    var controlValues: [String: NSTextField] = [:]
    var statusTimer: Timer?
    var sweeper: WindowSweeper?
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

        renderer.passthrough = PassthroughSource(device: device)

        // Панель управления в шлеме (появляется при движении мыши)
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
        // Внутренний таймер MTKView может тикать от другого (60 Гц) дисплея —
        // рисуем сами от CADisplayLink, привязанного к экрану окна
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        playerView = view

        if vrScreen != nil {
            // Безрамочное окно шлема намеренно НЕ становится ключевым:
            // клавиатурный фокус живёт в окне-пульте на мониторе, поэтому
            // системные диалоги открываются там, где их видно
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
            window.title = "PSVR2 Player (предпросмотр)"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Подстраховка: ловим клавиши на уровне приложения, даже если окно
        // на дисплее шлема не в фокусе
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            view.keyDown(with: event)
            return nil
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDragged) { event in
            view.rightMouseDragged(with: event)
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
            print("[display] !!! CVDisplayLink не создался — падаю обратно на таймер MTKView")
            view.isPaused = false
        }

        // Без файла — сразу открываем выбор в шлеме
        if videoURL == nil {
            overlay.openPicker()
        }

        print("[player] Управление: Space пауза · R или кнопка Fn шлема — рецентр · F проекция · G стерео · V флип")
        print("[player]             ←/→ ±15с · ↑/↓ громкость · +/- FOV fisheye · Q выход")
        print("[player]             отладка: P предсказание · [/] упреждение · S развёртка · C хроматика")
    }

    // Окно-пульт на обычном мониторе: таблица «настройка — значение —
    // клавиша» по группам, как в типичных настройках приложения. Заодно
    // держит клавиатурный фокус, чтобы системные диалоги были видны
    private func makeControlWindow() {
        let deskScreen = NSScreen.screens.first {
            !$0.localizedName.localizedCaseInsensitiveContains("PS VR2")
        } ?? NSScreen.main!
        let size = NSSize(width: 620, height: 610)
        let frame = NSRect(
            x: deskScreen.visibleFrame.maxX - size.width - 24,
            y: deskScreen.visibleFrame.minY + 24,
            width: size.width, height: size.height)

        let win = NSWindow(
            contentRect: frame, styleMask: [.titled, .miniaturizable],
            backing: .buffered, defer: false, screen: deskScreen)
        win.title = "PSVR2 Player — пульт"
        win.isReleasedWhenClosed = false
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
            // Строка обязана иметь все 3 ячейки, иначе mergeCells падает
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

        addHeader("Воспроизведение")
        addRow("Файл", id: "file", key: "")
        addRow("Позиция", id: "pos", key: "Space · ←/→")
        addRow("Громкость", id: "vol", key: "↑/↓")
        addRow("Скорость", id: "rate", key: "панель в шлеме")
        addHeader("Изображение")
        addRow("Проекция", id: "proj", key: "F")
        addRow("Стерео", id: "stereo", key: "G")
        addRow("Флип по вертикали", id: "flip", key: "V")
        addRow("FOV fisheye", id: "fov", key: "+ / −")
        addHeader("Камеры (вид вокруг)")
        addRow("Режим", id: "pt", key: "B · двойное Fn")
        addRow("Стерео/моно", id: "ptmode", key: "M")
        addRow("Сведение", id: "ptconv", key: ", / .")
        addRow("Угол объектива", id: "ptfov", key: "+ / −")
        addHeader("Шлем и трекинг")
        addRow("Трекинг", id: "track", key: "")
        addRow("Предсказание позы", id: "pred", key: "P")
        addRow("Упреждение", id: "look", key: "[ / ]")
        addRow("Коррекция развёртки", id: "scan", key: "S")
        addRow("Хроматика", id: "chrom", key: "C")
        addRow("Vsync", id: "vsync", key: "D")

        grid.column(at: 0).width = 150
        grid.column(at: 1).width = 270
        grid.column(at: 2).xPlacement = .trailing

        let footer = NSTextField(wrappingLabelWithString:
            "Кнопка Fn: одиночное — рецентр · двойное — вид с камер · долгое — центр по взгляду\n"
            + "R — рецентр · Q — выход · мышь в шлеме: движение — панель, ПКМ — наклон, колесо — список")
        footer.font = .systemFont(ofSize: 11.5)
        footer.textColor = .tertiaryLabelColor

        let openBtn = NSButton(title: "Открыть видео…", target: self,
                               action: #selector(openVideoFromMonitor))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .large
        openBtn.font = .systemFont(ofSize: 15, weight: .semibold)

        for v in [grid, footer, openBtn] {
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
            openBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            openBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
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

    // Текущие значения всех настроек — раз в секунду в пульт
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
            set("pos", "\(pos) / \(dur) · \(v.player.rate == 0 ? "пауза" : "играет")")
            set("vol", v.deviceVolume().map { "\(Int($0 * 100))% (шлем)" }
                ?? "\(Int(v.player.volume * 100))%")
        } else {
            set("file", "не открыт")
            set("pos", "—")
            set("vol", "—")
        }
        set("rate", String(format: "%g×", r.playbackRate))

        let cfg = r.config
        set("proj", cfg.projection.label)
        set("stereo", cfg.stereo.label)
        set("flip", cfg.flipV < 0 ? "вкл" : "выкл")
        set("fov", String(format: "%.0f°", cfg.fisheyeFovDeg))

        if let pt = r.passthrough {
            set("pt", pt.active ? "включены" : (pt.available ? "выключены" : "недоступны"))
            set("ptmode", pt.source.label)
            set("ptconv", String(format: "%+.3f", pt.convergence))
            set("ptfov", "\(Int(pt.fovDeg))°")
        }

        set("track", r.tracker.connected ? "есть" : "НЕТ")
        set("pred", r.tracker.predictionEnabled ? "вкл" : "выкл")
        set("look", "\(Int(r.tracker.extraLookaheadS * 1000)) мс")
        set("scan", r.scanlineEnabled ? "вкл" : "выкл")
        set("chrom", r.chromaticEnabled ? "вкл" : "выкл")
        set("vsync", ((playerView?.layer as? CAMetalLayer)?.displaySyncEnabled ?? true)
            ? "вкл" : "выкл")
    }

    // Выбор видео стандартным диалогом на мониторе
    @objc private func openVideoFromMonitor() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["mp4", "m4v", "mov"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.level = .floating // не ниже других окон захваченного стола
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.loadVideo(url)
        }
    }

    // Сторож: чужие окна, попавшие на дисплей шлема, переносим на монитор
    private func startWindowSweeper(vrScreen: NSScreen) {
        let deskScreen = NSScreen.screens.first { $0 != vrScreen } ?? vrScreen
        guard deskScreen != vrScreen else { return }
        // NSScreen (y вверх от низа главного экрана) -> CG (y вниз от верха)
        let primaryHeight = NSScreen.screens[0].frame.height
        func cgRect(_ f: NSRect) -> CGRect {
            CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        }
        let sweeper = WindowSweeper(
            vrFrame: cgRect(vrScreen.frame), targetFrame: cgRect(deskScreen.frame))
        sweeper.onStray = { [weak self] name, moved in
            if moved {
                self?.renderer.overlay?.showOSD("Окно «\(name)» перенесено на монитор", duration: 4)
                print("[sweeper] окно «\(name)» перенесено с экрана шлема на монитор")
            } else {
                self?.renderer.overlay?.showOSD(
                    "Окно «\(name)» открылось на экране шлема (см. лог)", duration: 6)
                print("[sweeper] Окно «\(name)» на экране шлема. Для автопереноса дайте доступ:")
                print("[sweeper] Настройки → Конфиденциальность → Универсальный доступ → «+» → PSVR2Player.app")
            }
        }
        sweeper.start()
        self.sweeper = sweeper
    }

    // Системный запрос доступа macOS показывает на экране активного окна.
    // Наше окно — в шлеме, поэтому на время ожидания открываем окно-подсказку
    // на обычном мониторе: диалог появится там же.
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
        helper.title = "PSVR2 Player — доступ к диску"
        helper.level = .floating

        let label = NSTextField(wrappingLabelWithString:
            "Ожидание доступа к диску.\n\n"
            + "Разрешите доступ в системном запросе, если он появился. "
            + "Если запроса нет — нажмите кнопку ниже: откроются «Полный доступ к диску» "
            + "и папка с приложением. Добавьте PSVR2Player.app кнопкой «+» и включите "
            + "переключатель, затем повторите выбор диска.")
        label.frame = NSRect(x: 20, y: 60, width: size.width - 40, height: size.height - 76)
        label.font = .systemFont(ofSize: 13)
        helper.contentView?.addSubview(label)

        let button = NSButton(title: "Открыть настройки доступа", target: self,
                              action: #selector(openFullDiskAccess))
        button.frame = NSRect(x: 20, y: 16, width: 240, height: 32)
        button.bezelStyle = .rounded
        helper.contentView?.addSubview(button)

        helper.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        accessHelperWindow = helper
        print("[player] Открыто окно ожидания доступа на мониторе")
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        print("[player] Полный доступ к диску → «+» → \(Bundle.main.bundleURL.path)")
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
        // Восстанавливаем сохранённую громкость
        if let saved = UserDefaults.standard.object(forKey: "volume") as? Float {
            vs.player.volume = max(0, min(1, saved))
        }
        renderer.video = vs
        renderer.overlay?.setCurrentFile(url)
        renderer.config = PlaybackConfig.detect(from: url.lastPathComponent)
        renderer.playbackRate = 1.0 // скорость — ситуативная, новый файл с 1×

        // Продолжаем с прошлого места, если файл уже смотрели
        if let resume = ResumeStore.position(for: url), resume > 15 {
            vs.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            let s = Int(resume)
            let ts = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                : String(format: "%d:%02d", s / 60, s % 60)
            renderer.overlay?.showOSD("Продолжаю с \(ts)", duration: 3)
            print("[player] продолжаю с \(ts)")
        }

        vs.player.rate = renderer.playbackRate
        let config = renderer.config
        print("[player] Файл: \(url.lastPathComponent)")
        print("[player] Проекция: \(config.projection.label), \(config.stereo.label)"
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

// MARK: - Запуск

setbuf(stdout, nil)
setbuf(stderr, nil)

// Запуск из Finder/Dock: терминала нет, лог пишем в файл.
// Смотреть: tail -f ~/Library/Logs/PSVR2Player.log или приложение «Консоль»
if isatty(STDOUT_FILENO) == 0 {
    let logPath = ("~/Library/Logs/PSVR2Player.log" as NSString).expandingTildeInPath
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    print("[player] Запуск \(Date()); лог: \(logPath)")
}

let args = CommandLine.arguments
// Без аргумента файл выбирается панелью в шлеме после запуска
let url: URL? = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(videoURL: url)
app.delegate = delegate
app.run()
