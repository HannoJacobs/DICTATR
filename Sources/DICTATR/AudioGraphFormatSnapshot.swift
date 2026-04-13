import AVFoundation
import Foundation

struct AudioGraphFormatSnapshot: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let commonFormatRawValue: Int

    init(sampleRate: Double, channelCount: UInt32, commonFormatRawValue: Int = 0) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormatRawValue = commonFormatRawValue
    }

    init(_ format: AVAudioFormat) {
        self.init(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            commonFormatRawValue: Int(format.commonFormat.rawValue)
        )
    }

    static let invalid = AudioGraphFormatSnapshot(sampleRate: 0, channelCount: 0)

    var isValid: Bool {
        sampleRate > 0 && channelCount > 0
    }

    var description: String {
        let sampleRateDescription = String(format: "%.1f", sampleRate)
        return "\(sampleRateDescription)Hz/\(channelCount)ch/commonFormat=\(commonFormatRawValue)"
    }
}
