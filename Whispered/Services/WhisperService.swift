import Foundation
import WhisperCpp

enum WhisperModel: String, CaseIterable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75MB) - Rapide"
        case .base: return "Base (~150MB) - Équilibré"
        case .small: return "Small (~500MB) - Précis"
        case .medium: return "Medium (~1.5GB) - Très précis"
        }
    }

    var fileName: String {
        return "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")!
    }

    var coreMLFileName: String {
        return "ggml-\(rawValue)-encoder.mlmodelc"
    }

    var coreMLDownloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue)-encoder.mlmodelc.zip")!
    }
}

class WhisperService {
    static let shared = WhisperService()

    private var context: OpaquePointer?
    private var currentModel: WhisperModel = .base
    private var isModelLoaded = false

    private init() {
        // Load saved model preference
        if let savedModel = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = WhisperModel(rawValue: savedModel) {
            currentModel = model
        }
        loadModelIfAvailable()
    }

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let whisperDir = appSupport.appendingPathComponent("Whispered/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: whisperDir, withIntermediateDirectories: true)
        return whisperDir
    }

    private func modelPath(for model: WhisperModel) -> URL {
        return modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isModelAvailable(_ model: WhisperModel) -> Bool {
        return FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    func getAvailableModels() -> [WhisperModel] {
        return WhisperModel.allCases.filter { isModelAvailable($0) }
    }

    func getCurrentModel() -> WhisperModel {
        return currentModel
    }

    func switchModel(to model: WhisperModel, completion: @escaping (Result<Void, WhisperError>) -> Void) {
        guard isModelAvailable(model) else {
            completion(.failure(.modelNotFound))
            return
        }

        // Unload current model
        if let ctx = context {
            whisper_free(ctx)
            context = nil
            isModelLoaded = false
        }

        // Switch to new model
        currentModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")

        // Load new model
        loadModel()

        if isModelLoaded {
            completion(.success(()))
        } else {
            completion(.failure(.modelLoadFailed))
        }
    }

    private func loadModelIfAvailable() {
        guard isModelAvailable(currentModel) else {
            print("Model not found: \(currentModel.fileName)")
            // Try to fallback to base if available
            if currentModel != .base && isModelAvailable(.base) {
                currentModel = .base
                loadModelIfAvailable()
            }
            return
        }
        loadModel()
    }

    private func loadModel() {
        guard context == nil else { return }

        let path = modelPath(for: currentModel)

        var params = whisper_context_default_params()
        params.use_gpu = true

        context = whisper_init_from_file_with_params(path.path, params)

        if context != nil {
            isModelLoaded = true
            print("Whisper model loaded: \(currentModel.fileName)")
        } else {
            print("Failed to load Whisper model: \(currentModel.fileName)")
        }
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, WhisperError>) -> Void) {
        guard isModelLoaded, let ctx = context else {
            completion(.failure(.modelNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let samples = self.readAudioSamples(from: audioURL) else {
                DispatchQueue.main.async {
                    completion(.failure(.audioReadFailed))
                }
                return
            }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

            // Get language preference
            let languagePref = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
            if languagePref != "auto" {
                params.language = (languagePref as NSString).utf8String
            } else {
                params.language = nil
            }

            params.translate = false
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.single_segment = false
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            let result = samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
            }

            if result != 0 {
                DispatchQueue.main.async {
                    completion(.failure(.transcriptionFailed))
                }
                return
            }

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
            guard data.count > 44 else { return nil }

            let pcmData = data.dropFirst(44)
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

    func downloadModel(_ model: WhisperModel, completion: @escaping (Result<Void, WhisperError>) -> Void) {
        let destinationPath = modelPath(for: model)

        if FileManager.default.fileExists(atPath: destinationPath.path) {
            completion(.success(()))
            return
        }

        print("Downloading model: \(model.fileName)")

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { tempURL, response, error in
            if let error = error {
                completion(.failure(.downloadFailed(error.localizedDescription)))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(.downloadFailed("No file downloaded")))
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: destinationPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if FileManager.default.fileExists(atPath: destinationPath.path) {
                    try FileManager.default.removeItem(at: destinationPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationPath)

                completion(.success(()))
            } catch {
                completion(.failure(.downloadFailed(error.localizedDescription)))
            }
        }

        task.resume()
    }

    func downloadModelIfNeeded(completion: @escaping (Result<Void, WhisperError>) -> Void) {
        downloadModel(currentModel, completion: completion)
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }
}
