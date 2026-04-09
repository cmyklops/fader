import Foundation

/// Converts between linear slider positions (0.0–1.0), decibels, and
/// amplitude scalars (0.0–1.0) using a dB-linear curve so that the
/// slider feels perceptually even to human ears.
///
/// Mapping:
///   sliderValue 0.0  → true silence (amplitude 0.0, shown as 0%)
///   sliderValue 0.5  → –30 dB       (amplitude ≈ 0.032, shown as 50%)
///   sliderValue 1.0  →   0 dB       (amplitude 1.0,     shown as 100%)
///
/// The dB floor is –60 dB — below that we clamp to silence because
/// the linear amplitude becomes negligibly small (~0.001) and any
/// further resolution is perceptually meaningless.
enum VolumeConverter {

    // MARK: - Constants

    /// Minimum dB value represented by a slider position above zero.
    static let minDB: Float = -60.0

    /// Maximum dB value (full volume, unity gain).
    static let maxDB: Float = 0.0

    // MARK: - Conversions

    /// Converts a linear slider value [0, 1] to a linear amplitude scalar [0, 1].
    ///
    /// The slider position maps through a dB-linear curve:
    /// > amplitude = 10 ^ (dB / 20)
    /// where dB is interpolated linearly from `minDB` to `maxDB`.
    ///
    /// A slider value of exactly 0.0 returns 0.0 (true silence).
    static func sliderToAmplitude(_ sliderValue: Float) -> Float {
        guard sliderValue > 0.0 else { return 0.0 }
        guard sliderValue < 1.0 else { return 1.0 }
        let db = minDB + (maxDB - minDB) * sliderValue
        return pow(10.0, db / 20.0)
    }

    /// Converts a linear amplitude scalar [0, 1] back to a slider position [0, 1].
    static func amplitudeToSlider(_ amplitude: Float) -> Float {
        guard amplitude > 0.0 else { return 0.0 }
        guard amplitude < 1.0 else { return 1.0 }
        let db = 20.0 * log10(amplitude)
        return (db - minDB) / (maxDB - minDB)
    }

    /// Converts a linear amplitude scalar to decibels.
    static func amplitudeToDb(_ amplitude: Float) -> Float {
        guard amplitude > 0.0 else { return -Float.infinity }
        return 20.0 * log10(amplitude)
    }

    /// Converts decibels to a linear amplitude scalar.
    static func dbToAmplitude(_ db: Float) -> Float {
        pow(10.0, db / 20.0)
    }

    /// Returns a display string for a slider value, e.g. "–23 dB" or "0 dB".
    static func displayString(forSlider sliderValue: Float) -> String {
        guard sliderValue > 0.0 else { return "-∞ dB" }
        let db = minDB + (maxDB - minDB) * sliderValue
        if db >= -0.05 { return "0 dB" }
        return String(format: "%.0f dB", db)
    }
}
