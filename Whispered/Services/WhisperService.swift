import Foundation
import WhisperCpp

class WhisperService {
    static let shared = WhisperService()

    private var context: OpaquePointer?
    private let modelName = "ggml-base.bin"
    private var isModelLoaded = false

    private init() {
        loadModelIfAvailable()
    }

    private var modelPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let whisperDir = appSupport.appendingPathComponent("Whispered/models", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: whisperDir, withIntermediateDirectories: true)

        return whisperDir.appendingPathComponent(modelName)
    }

    private func loadModelIfAvailable() {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            print("Model not found at: \(modelPath.path)")
            return
        }

        loadModel()
    }

    private func loadModel() {
        guard context == nil else { return }

        var params = whisper_context_default_params()
        params.use_gpu = true

        context = whisper_init_from_file_with_params(modelPath.path, params)

        if context != nil {
            isModelLoaded = true
            print("Whisper model loaded successfully")
        } else {
            print("Failed to load Whisper model")
        }
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, WhisperError>) -> Void) {
        guard isModelLoaded, let ctx = context else {
            completion(.failure(.modelNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Read audio file
            guard let samples = self.readAudioSamples(from: audioURL) else {
                DispatchQueue.main.async {
                    completion(.failure(.audioReadFailed))
                }
                return
            }

            // Setup transcription parameters
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.language = nil  // Auto-detect language
            params.translate = false
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.single_segment = false
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            // Run transcription
            let result = samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
            }

            if result != 0 {
                DispatchQueue.main.async {
                    completion(.failure(.transcriptionFailed))
                }
                return
            }

            // Extract text
            let segmentCount = whisper_full_n_segments(ctx)
            var fullText = ""

            for i in 0..<segmentCount {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    fullText += String(cString: text)
                }
            }

            DispatchQueue.main.async {
                completion(.success(fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private func readAudioSamples(from url: URL) -> [Float]? {
        do {
            let data = try Data(contentsOf: url)

            // Skip WAV header (44 bytes for standard WAV)
            guard data.count > 44 else { return nil }

            let pcmData = data.dropFirst(44)

            // Convert Int16 PCM to Float32 samples
            var samples = [Float]()
            samples.reserveCapacity(pcmData.count / 2)

            pcmData.withUnsafeBytes { buffer in
                let int16Buffer = buffer.bindMemory(to: Int16.self)
                for sample in int16Buffer {
                    samples.append(Float(sample) / 32768.0)
                }
            }

            return samples
        } catch {
            print("Error reading audio file: \(error)")
            return nil
        }
    }

    // MARK: - Model Download

    func downloadModelIfNeeded(completion: @escaping (Result<Void, WhisperError>) -> Void) {
        if FileManager.default.fileExists(atPath: modelPath.path) {
            loadModel()
            completion(.success(()))
            return
        }

        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        guard let url = URL(string: urlString) else {
            completion(.failure(.downloadFailed("Invalid URL")))
            return
        }

        print("Downloading model from: \(urlString)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(.downloadFailed(error.localizedDescription)))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(.downloadFailed("No file downloaded")))
                return
            }

            do {
                // Create models directory
                try FileManager.default.createDirectory(
                    at: self.modelPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // Move downloaded file
                if FileManager.default.fileExists(atPath: self.modelPath.path) {
                    try FileManager.default.removeItem(at: self.modelPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: self.modelPath)

                // Load the model
                self.loadModel()

                completion(.success(()))
            } catch {
                completion(.failure(.downloadFailed(error.localizedDescription)))
            }
        }

        task.resume()
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }
}
