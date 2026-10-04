import Foundation
import simd

/// Verbindet die gesetzten Kantenpunkte zu einer weich geschwungenen, geschlossenen Kurve
/// (zentripetaler Catmull-Rom-Spline: läuft durch jeden Punkt, ohne Schleifen oder Ecken).
enum EdgeSpline {
    static func closedCurve(through points: [SIMD2<Float>], samplesPerSegment: Int = 12) -> [SIMD2<Float>] {
        let n = points.count
        guard n >= 3 else { return points }
        var curve: [SIMD2<Float>] = []
        curve.reserveCapacity(n * samplesPerSegment)
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            for s in 0..<samplesPerSegment {
                let u = Float(s) / Float(samplesPerSegment)
                curve.append(catmullRom(p0, p1, p2, p3, u))
            }
        }
        return curve
    }

    private static func catmullRom(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ u: Float) -> SIMD2<Float> {
        func knot(_ t: Float, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            t + max(sqrt(simd_distance(a, b)), 1e-4)
        }
        let t0: Float = 0
        let t1 = knot(t0, p0, p1)
        let t2 = knot(t1, p1, p2)
        let t3 = knot(t2, p2, p3)
        let t = t1 + (t2 - t1) * u

        let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        return (t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2
    }
}
