// Passthrough: вид с передних камер шлема.
//
// C-ядро (cpsvr2.c) читает кадры с USB в фоне; здесь они выгружаются в пару
// BC4-текстур (левая и правая камеры). BC4 — блочный формат Metal
// (.bc4_rUnorm), декодируется GPU бесплатно, поэтому кадры идут в текстуру
// как есть, без распаковки на CPU.

import Metal

final class PassthroughSource {
    static let width = Int(PSVR2_CAM_WIDTH)
    static let height = Int(PSVR2_CAM_HEIGHT)
    // BC4: 4 бита на пиксель (составной макрос из cpsvr2.h в Swift не виден)
    private static let planeBytes = width * height / 2

    private(set) var textureL: MTLTexture?
    private(set) var textureR: MTLTexture?
    private(set) var active = false
    private(set) var gotFrame = false

    // Угол обзора камер: точной калибровки объектива у нас нет,
    // подбирается на глаз клавишами +/-
    var fovDeg: Float = 150
    var brightness: Float = 1.6

    private var bufL = [UInt8](repeating: 0, count: planeBytes)
    private var bufR = [UInt8](repeating: 0, count: planeBytes)

    init(device: MTLDevice) {
        // BC4 поддерживается на Apple Silicon; если формат недоступен,
        // passthrough просто не включится
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
            print("[passthrough] камеры не запустились")
            return false
        }
        active = true
        gotFrame = false
        print("[passthrough] камеры включены")
        return true
    }

    func stop() {
        guard active else { return }
        active = false
        gotFrame = false
        psvr2_camera_stop()
        print("[passthrough] камеры выключены")
    }

    // Вызывается каждый кадр рендера
    func update() {
        guard active, let tl = textureL, let tr = textureR else { return }
        var fresh: Int32 = 0
        bufL.withUnsafeMutableBufferPointer { l in
            bufR.withUnsafeMutableBufferPointer { r in
                fresh = psvr2_camera_get_frame(l.baseAddress, r.baseAddress)
            }
        }
        guard fresh == 1 else { return }

        // BC4: 4 бита на пиксель, блок 4x4 = 8 байт -> строка блоков = width*2 байт
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
