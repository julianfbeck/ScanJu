import AVFoundation
import simd

/// Preserve optical calibration alongside original RGB-D data. Mapping follows
/// AVCameraCalibrationData.h: inverse LUT maps raw pixels to rectilinear pixels;
/// the forward LUT maps rectilinear pixels back to raw imagery.
struct DepthCalibration: Codable {
    let matrix: [Float]
    let referenceWidth: Float
    let referenceHeight: Float
    let center: SIMD2<Float>
    let forward: [Float]
    let inverse: [Float]

    init(_ value: AVCameraCalibrationData) {
        matrix = (0..<3).flatMap { c in (0..<3).map { r in value.intrinsicMatrix[c][r] } }
        referenceWidth = Float(value.intrinsicMatrixReferenceDimensions.width)
        referenceHeight = Float(value.intrinsicMatrixReferenceDimensions.height)
        center = SIMD2(Float(value.lensDistortionCenter.x), Float(value.lensDistortionCenter.y))
        func floats(_ data: Data?) -> [Float] {
            guard let data else { return [] }
            return data.withUnsafeBytes { bytes in (0..<(data.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        }
        forward = floats(value.lensDistortionLookupTable); inverse = floats(value.inverseLensDistortionLookupTable)
    }

    init(matrix: [Float], referenceWidth: Float, referenceHeight: Float, center: SIMD2<Float>, forward: [Float], inverse: [Float]) {
        self.matrix = matrix; self.referenceWidth = referenceWidth; self.referenceHeight = referenceHeight
        self.center = center; self.forward = forward; self.inverse = inverse
    }

    func intrinsics(width: Int, height: Int) -> simd_float3x3 {
        var k = simd_float3x3(SIMD3(matrix[0],matrix[1],matrix[2]), SIMD3(matrix[3],matrix[4],matrix[5]), SIMD3(matrix[6],matrix[7],matrix[8]))
        k[0][0] *= Float(width) / referenceWidth; k[2][0] *= Float(width) / referenceWidth
        k[1][1] *= Float(height) / referenceHeight; k[2][1] *= Float(height) / referenceHeight
        return k
    }

    func rectified(_ pixel: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        map(pixel, width: width, height: height, table: inverse)
    }
    func distorted(_ pixel: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        map(pixel, width: width, height: height, table: forward)
    }
    private func map(_ pixel: SIMD2<Float>, width: Int, height: Int, table: [Float]) -> SIMD2<Float> {
        guard table.count > 1, width > 0, height > 0, referenceWidth > 0, referenceHeight > 0 else { return pixel }
        let scale = SIMD2(referenceWidth / Float(width), referenceHeight / Float(height))
        let vector = pixel * scale - center
        let maximum = simd_length(SIMD2(max(center.x, referenceWidth - center.x), max(center.y, referenceHeight - center.y)))
        guard maximum > 0 else { return pixel }
        let position = min(Float(table.count - 1), simd_length(vector) / maximum * Float(table.count - 1))
        let index = min(table.count - 2, Int(position)), fraction = position - Float(index)
        let magnification = table[index] * (1 - fraction) + table[index + 1] * fraction
        return (center + vector * (1 + magnification)) / scale
    }
}
