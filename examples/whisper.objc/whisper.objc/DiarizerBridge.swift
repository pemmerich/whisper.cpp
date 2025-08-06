import FluidAudio
import Foundation

@objc public class DiarizerBridge: NSObject {
    @objc(diarizeWithSamples:sampleRate:completion:)
    public static func diarizeWithSamples(
        samples: NSArray,
        sampleRate: Int,
        completion: @escaping @Sendable (NSArray?, NSError?) -> Void
    ) {
        // ✅ Convert NSArray to Swift-native [Float]
        let floatSamples: [Float] = samples.compactMap { ($0 as? NSNumber)?.floatValue }
        let copiedRate = sampleRate

        Task { @Sendable in
            do {
                let diarizer = DiarizerManager()
                try await diarizer.initialize()

                let result = try await diarizer.performCompleteDiarization(floatSamples, sampleRate: copiedRate)

                let segments = result.segments.map { seg in
                    return [
                        "speakerId": seg.speakerId,
                        "startTime": seg.startTimeSeconds,
                        "endTime": seg.endTimeSeconds
                    ]
                } as NSArray

                DispatchQueue.main.async {
                    completion(segments, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error as NSError)
                }
            }
        }
    }
}





    
