import Foundation

enum OutputMeterScale {
    private static let floorDbfs = -60.0

    static func normalizedFillLevel(forLinearLevel linearLevel: Double) -> Double {
        let clampedLevel = min(max(linearLevel, 0), 1)
        guard clampedLevel > 0 else { return 0 }

        let dbfs = 20 * log10(clampedLevel)
        let normalized = (dbfs - floorDbfs) / abs(floorDbfs)
        return min(max(normalized, 0), 1)
    }
}
