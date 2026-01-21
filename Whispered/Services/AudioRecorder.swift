import AVFoundation
import Foundation

class AudioRecorder: NSObject {
    static let shared = AudioRecorder()

    private var audioRecorder: AVAudioRecorder?
    private var audioURL: URL?

    private override init() {
        super.init()
    }

    func startRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        audioURL = tempDir.appendingPathComponent("whispered_recording.wav")

        // Whisper requires 16kHz mono audio
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioURL!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard let recorder = audioRecorder, recorder.isRecording else {
            completion(nil)
            return
        }

        recorder.stop()

        // Small delay to ensure file is written
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            completion(self?.audioURL)
        }
    }

    func getAudioLevel() -> Float {
        audioRecorder?.updateMeters()
        return audioRecorder?.averagePower(forChannel: 0) ?? -160
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording finished unsuccessfully")
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error)")
        }
    }
}
