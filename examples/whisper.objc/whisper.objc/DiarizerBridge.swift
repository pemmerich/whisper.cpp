import FluidAudio
import Foundation

@objc public class DiarizerBridge: NSObject {
    @MainActor
    @objc public static func diarize(
        samples: NSArray,
        sampleRate: Int,
        completion: @escaping (NSArray?, NSError?) -> Void
    ) {
        Task {
            do {
                let diarizer = DiarizerManager()
                try await diarizer.initialize()
                let floats = samples.compactMap { ($0 as? NSNumber)?.floatValue }
                let result = try await diarizer.performCompleteDiarization(floats, sampleRate: sampleRate)
                let segments = result.segments.map { seg in
                    return [
                        "speakerId": seg.speakerId,
                        "startTime": seg.startTimeSeconds,
                        "endTime": seg.endTimeSeconds
                    ]
                } as NSArray
                completion(segments, nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }
}

    
