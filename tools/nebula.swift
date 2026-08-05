// Generator of an equirect "space made for OLED" panorama: pure 0,0,0
// background, with a contrasting colored nebula along a tilted great circle
// (fbm noise with domain warping), plus separate cloud "blobs" and stars.
// Noise is sampled by 3D direction — seamless panorama, no pole artifacts.
// Usage: swift -O nebula.swift <width> <out.jpg> [variant]
import CoreGraphics
import CoreImage
import Foundation
import simd

let W = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 8192
let H = W / 2
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "nebula.jpg"
// Variant number: shifts the noise domain — same style, different pattern
let variant = CommandLine.arguments.count > 3 ? Float(CommandLine.arguments[3])! : 0
let seedOff = SIMD3<Float>(variant * 37.31, variant * 61.77, variant * 23.19)

// MARK: - Noise

@inline(__always) func hash3(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
    var h = UInt32(bitPattern: x) &* 374761393
        &+ UInt32(bitPattern: y) &* 668265263
        &+ UInt32(bitPattern: z) &* 2246822519
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) * (1.0 / 16777215.0)
}

@inline(__always) func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

@inline(__always) func vnoise(_ p: SIMD3<Float>) -> Float {
    let f = floor(p)
    let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
    let t = p - f
    let u = SIMD3<Float>(smooth(t.x), smooth(t.y), smooth(t.z))
    func h(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float {
        hash3(i.x &+ dx, i.y &+ dy, i.z &+ dz)
    }
    let c00 = h(0, 0, 0) + (h(1, 0, 0) - h(0, 0, 0)) * u.x
    let c10 = h(0, 1, 0) + (h(1, 1, 0) - h(0, 1, 0)) * u.x
    let c01 = h(0, 0, 1) + (h(1, 0, 1) - h(0, 0, 1)) * u.x
    let c11 = h(0, 1, 1) + (h(1, 1, 1) - h(0, 1, 1)) * u.x
    let c0 = c00 + (c10 - c00) * u.y
    let c1 = c01 + (c11 - c01) * u.y
    return c0 + (c1 - c0) * u.z
}

@inline(__always) func fbm(_ p: SIMD3<Float>, _ octaves: Int) -> Float {
    var v: Float = 0, a: Float = 0.5
    var q = p
    for _ in 0..<octaves {
        v += a * vnoise(q)
        q *= 2.03
        a *= 0.5
    }
    return v // ~0..1
}

// MARK: - Scene

let bandNormal = simd_normalize(SIMD3<Float>(0.42, 0.88, 0.22))
// Separate clouds: direction, radius, palette (0 — blue-teal,
// 1 — purple-pink, 2 — warm orange)
let blobs: [(dir: SIMD3<Float>, r: Float, pal: Int)] = [
    (simd_normalize(SIMD3<Float>(0.8, 0.15, -0.55)), 0.48, 1),
    (simd_normalize(SIMD3<Float>(-0.75, -0.3, 0.58)), 0.42, 2),
    (simd_normalize(SIMD3<Float>(-0.2, 0.62, 0.75)), 0.36, 0),
]

@inline(__always) func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

// Palettes: dark base -> bright edge -> "core"
let palettes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
    (SIMD3(0.02, 0.06, 0.22), SIMD3(0.05, 0.65, 0.85), SIMD3(0.75, 0.95, 1.0)),
    (SIMD3(0.10, 0.02, 0.20), SIMD3(0.65, 0.12, 0.75), SIMD3(1.0, 0.65, 0.9)),
    (SIMD3(0.16, 0.05, 0.02), SIMD3(0.9, 0.42, 0.08), SIMD3(1.0, 0.9, 0.6)),
]

@inline(__always) func nebulaColor(_ dir: SIMD3<Float>) -> SIMD3<Float> {
    // Region masks: band + blobs; outside them — immediately black (cheap)
    let bandD = abs(simd_dot(dir, bandNormal))
    var mask = max(0, 1 - bandD / 0.30)
    var pal = 0
    var best = mask
    for b in blobs {
        let d = simd_distance(dir, b.dir)
        let m = max(0, 1 - d / b.r)
        if m > best {
            best = m
            pal = b.pal
        }
        mask = max(mask, m)
    }
    if mask <= 0.001 {
        return .zero
    }

    // Domain warping: wispy filaments
    let s = dir * 3.1 + seedOff
    let warp = SIMD3<Float>(
        fbm(s + SIMD3(11.7, 3.1, 7.9), 5),
        fbm(s + SIMD3(5.2, 17.3, 2.6), 5),
        fbm(s + SIMD3(9.1, 1.4, 13.8), 5)) * 1.9
    let n = fbm(dir * 5.6 + warp + seedOff, 6)
    let detail = fbm(dir * 14.0 + warp * 1.4 + seedOff, 5)

    // Soft glow underlay + bright filaments on top; the threshold keeps
    // most of the field at zero — the background stays pure black
    let haze = max(0, fbm(dir * 2.4 + warp * 0.7 + seedOff, 4) - 0.40) * 1.8
    let fil = max(0, n * (0.55 + 0.45 * detail) - 0.24) * 3.4
    let density = min(1, haze * 0.40 + fil * fil) * smooth(min(1, mask * 1.8))
    if density <= 0.004 {
        return .zero
    }

    // Along the band the hue drifts smoothly between blue-teal and purple
    var (base, edge, core) = palettes[pal]
    if pal == 0 {
        let hueT = smooth(min(1, max(0, fbm(dir * 1.7 + SIMD3(3.3, 8.8, 1.2) + seedOff, 3) * 2.2 - 0.55)))
        let p1 = palettes[1]
        base = mix3(base, p1.0, hueT)
        edge = mix3(edge, p1.1, hueT)
        core = mix3(core, p1.2, hueT)
    }
    var c = mix3(base, edge, min(1, density * 2.2))
    let coreT = max(0, density - 0.58) * 1.7
    c = mix3(c, core, min(1, coreT))
    return c * density
}

// MARK: - Nebula render

var buf = [Float](repeating: 0, count: W * H * 3)
buf.withUnsafeMutableBufferPointer { bp in
    let px = bp.baseAddress!
    DispatchQueue.concurrentPerform(iterations: H) { y in
        let theta = (Float(y) + 0.5) / Float(H) * Float.pi // 0 — top
        let sy = sin(theta), cy = cos(theta)
        for x in 0..<W {
            let phi = (Float(x) + 0.5) / Float(W) * 2 * Float.pi - Float.pi
            let dir = SIMD3<Float>(sy * cos(phi), cy, sy * sin(phi))
            let c = nebulaColor(dir)
            if c.x == 0 && c.y == 0 && c.z == 0 { continue }
            let o = (y * W + x) * 3
            px[o] = c.x
            px[o + 1] = c.y
            px[o + 2] = c.z
        }
    }
}

// MARK: - Stars (additive on top)

var seed: UInt64 = 20260805 &+ UInt64(variant) &* 7919
@inline(__always) func rnd() -> Float {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return Float(seed & 0xFFFFFF) * (1.0 / 16777215.0)
}

buf.withUnsafeMutableBufferPointer { bp in
    let px = bp.baseAddress!
    func splat(_ cx: Float, _ cy: Float, _ radius: Float, _ col: SIMD3<Float>) {
        let r = Int(radius.rounded(.up))
        let ix = Int(cx), iy = Int(cy)
        for dy in -r...r {
            let yy = iy + dy
            if yy < 0 || yy >= H { continue }
            for dx in -r...r {
                var xx = ix + dx
                if xx < 0 { xx += W }
                if xx >= W { xx -= W } // horizontal seam wraps around
                let fx = Float(dx) - (cx - Float(ix))
                let fy = Float(dy) - (cy - Float(iy))
                let q = (fx * fx + fy * fy) / (radius * radius)
                if q > 1 { continue }
                let a = exp(-q * 4.5)
                let o = (yy * W + xx) * 3
                px[o] = min(1.5, px[o] + col.x * a)
                px[o + 1] = min(1.5, px[o + 1] + col.y * a)
                px[o + 2] = min(1.5, px[o + 2] + col.z * a)
            }
        }
    }

    var placed = 0
    while placed < 34000 {
        let z = rnd() * 2 - 1
        let phi = rnd() * 2 * Float.pi
        let rr = (1 - z * z).squareRoot()
        let dir = SIMD3<Float>(rr * cos(phi), z, rr * sin(phi))
        // More stars within the nebula band
        let nearBand = abs(simd_dot(dir, bandNormal)) < 0.3
        if !nearBand && rnd() < 0.45 { continue }
        placed += 1

        let cx = (atan2(dir.z, dir.x) / (2 * Float.pi) + 0.5) * Float(W)
        let cy = acos(max(-1, min(1, dir.y))) / Float.pi * Float(H)

        let m = pow(rnd(), 3.4)
        let bright = 0.12 + 1.1 * m
        let t = rnd()
        let col: SIMD3<Float> = t < 0.22
            ? SIMD3(0.72, 0.84, 1.0)
            : (t > 0.82 ? SIMD3(1.0, 0.85, 0.66) : SIMD3(1, 1, 1))
        let radius = (1.3 + 5.0 * m) * Float(W) / 8192
        splat(cx, cy, radius, col * bright)
        // Faint "rays" around the brightest ones
        if m > 0.85 {
            splat(cx, cy, radius * 2.6, col * bright * 0.10)
        }
    }
}

// MARK: - Saving

let ctx = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
let out = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
buf.withUnsafeBufferPointer { bp in
    let px = bp.baseAddress!
    DispatchQueue.concurrentPerform(iterations: H) { y in
        for x in 0..<W {
            let i = (y * W + x) * 3
            let o = (y * W + x) * 4
            // BGRA little-endian
            out[o] = UInt8(max(0, min(1, px[i + 2])) * 255)
            out[o + 1] = UInt8(max(0, min(1, px[i + 1])) * 255)
            out[o + 2] = UInt8(max(0, min(1, px[i])) * 255)
            out[o + 3] = 255
        }
    }
}

let img = ctx.makeImage()!
try CIContext().writeJPEGRepresentation(
    of: CIImage(cgImage: img), to: URL(fileURLWithPath: outPath),
    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    options: [CIImageRepresentationOption(
        rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
print("ok: \(W)x\(H) -> \(outPath)")
