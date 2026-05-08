import XCTest
@testable import Fader

final class VolumeConverterTests: XCTestCase {
    func testSliderToAmplitudeEdges() {
        XCTAssertEqual(VolumeConverter.sliderToAmplitude(0), 0)
        XCTAssertEqual(VolumeConverter.sliderToAmplitude(1), 1)
    }

    func testMidpointMapsToMinus15Db() {
        let amplitude = VolumeConverter.sliderToAmplitude(0.5)
        XCTAssertEqual(amplitude, 0.17782794, accuracy: 0.00001)
        XCTAssertEqual(VolumeConverter.amplitudeToDb(amplitude), -15, accuracy: 0.001)
    }

    func testRoundTripConversion() {
        for value in stride(from: Float(0.1), through: Float(0.9), by: Float(0.1)) {
            let amplitude = VolumeConverter.sliderToAmplitude(value)
            XCTAssertEqual(VolumeConverter.amplitudeToSlider(amplitude), value, accuracy: 0.0001)
        }
    }

    func testDisplayStrings() {
        XCTAssertEqual(VolumeConverter.displayString(forSlider: 0), "-∞ dB")
        XCTAssertEqual(VolumeConverter.displayString(forSlider: 0.5), "-15 dB")
        XCTAssertEqual(VolumeConverter.displayString(forSlider: 1), "0 dB")
    }
}
