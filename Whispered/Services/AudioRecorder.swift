@preconcurrency import AVFoundation
import Foundation
import os.log

private let audioLogger = Logger(subsystem: "com.whispered", category: "AudioRecorder")

// MARK: - Erreurs

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case microphonePending
    case noInputDevice
    case converterUnavailable(from: Double)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Accès au microphone refusé. Autorisez Whispered dans Réglages Système > Confidentialité et sécurité > Microphone."
        case .microphonePending:
            return "Autorisation du microphone en attente. Réessayez."
        case .noInputDevice:
            return "Aucun microphone disponible."
        case .converterUnavailable(let rate):
            return "Conversion \(Int(rate)) Hz vers 16 kHz impossible."
        case .engineStartFailed(let detail):
            return "Démarrage de la capture impossible : \(detail)"
        }
    }
}

// MARK: - Tampon partagé

/// Tampon entre le thread audio temps réel (écriture) et le main thread (lecture).
///
/// Volontairement séparé d'`AudioRecorder` pour que le bloc de tap ne capture
/// **rien de mutable** appartenant au recorder : ni le convertisseur, ni les
/// closures de callback. Le tap ne fait que remplir ce tampon sous `NSLock`.
///
/// Trois règles tenues pour que le thread de rendu audio reste temps réel :
/// pas d'allocation (capacité réservée une fois pour toutes), pas de
/// `DispatchQueue.async`, pas de `Task { @MainActor }`. Le niveau et les
/// compteurs de silence sont lus par un timer côté main thread.
private final class AudioSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothedLevel: Float = 0
    private var hadSpeech = false
    private var silentSampleCount = 0

    private let capacity: Int
    private let silenceThreshold: Float

    init(capacity: Int, silenceThreshold: Float) {
        self.capacity = capacity
        self.silenceThreshold = silenceThreshold
        samples.reserveCapacity(capacity)
    }

    /// Appelée depuis le thread audio temps réel.
    func append(_ chunk: UnsafeBufferPointer<Float>) {
        guard !chunk.isEmpty else { return }

        // Énergie calculée hors verrou.
        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in chunk {
            sumSquares += sample * sample
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        let rms = (sumSquares / Float(chunk.count)).squareRoot()
        let target = Self.displayLevel(rms: rms, peak: peak)

        lock.lock()
        let room = capacity - samples.count
        if room > 0 {
            if chunk.count <= room {
                samples.append(contentsOf: chunk)
            } else {
                samples.append(contentsOf: chunk.prefix(room))
            }
        }

        // Attaque rapide, relâchement lent : une onde lisible plutôt qu'un stroboscope.
        smoothedLevel += (target - smoothedLevel) * (target > smoothedLevel ? 0.6 : 0.15)

        if rms >= silenceThreshold {
            hadSpeech = true
            silentSampleCount = 0
        } else if hadSpeech {
            silentSampleCount += chunk.count
        }
        lock.unlock()
    }

    /// Rend les échantillons capturés et repart d'un tampon neuf.
    ///
    /// `swap` plutôt que copie puis `removeAll` : la copie rendait le tampon
    /// partagé, donc `removeAll(keepingCapacity:)` devait réallouer 7,7 Mo
    /// **sous le verrou**, que le thread audio attend.
    func drain() -> [Float] {
        var fresh = [Float]()
        fresh.reserveCapacity(capacity)

        lock.lock()
        swap(&samples, &fresh)
        smoothedLevel = 0
        hadSpeech = false
        silentSampleCount = 0
        lock.unlock()

        return fresh
    }

    func reset() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            smoothedLevel = 0
            hadSpeech = false
            silentSampleCount = 0
        }
    }

    /// Instantané cohérent de l'état, lu par le timer du main thread.
    func snapshot() -> (level: Float, sampleCount: Int, silentSampleCount: Int, hadSpeech: Bool) {
        lock.withLock { (smoothedLevel, samples.count, silentSampleCount, hadSpeech) }
    }

    var count: Int { lock.withLock { samples.count } }

    /// dB → 0…1 calibré pour la voix : -50 dB = plancher, -6 dB = plein.
    /// Le niveau crête brut plafonnait l'onde à mi-hauteur, une voix normale
    /// culminant vers -12 dBFS, soit 0,25 en linéaire.
    private static func displayLevel(rms: Float, peak: Float) -> Float {
        let reference = max(rms, peak * 0.5)
        guard reference > 0 else { return 0 }
        let decibels = 20 * log10f(reference)
        return min(1, max(0, (decibels + 50) / 44))
    }
}

/// Drapeau « buffer déjà fourni » du bloc d'entrée d'`AVAudioConverter`.
/// Le bloc est appelé de façon synchrone, un seul fil y touche à la fois.
private final class ConversionState: @unchecked Sendable {
    var consumed = false
}

// MARK: - Consommateur du direct

/// Porte le consommateur de la transcription en direct, attaché *après* le
/// démarrage de la capture : ouvrir la session du moteur système prend quelques
/// centaines de millisecondes, et on ne va pas retarder l'enregistrement pour
/// ça. Le bloc de tap capture cette boîte par valeur immuable et ne lit donc
/// jamais une propriété mutable du recorder.
private final class LiveConsumerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ newValue: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { handler = newValue }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { handler }
        current?(buffer)
    }

    var isAttached: Bool { lock.withLock { handler != nil } }
}

// MARK: - Enregistreur

/// Capture micro en mémoire, au format attendu par les moteurs : 16 kHz, mono,
/// float 32 bits.
///
/// Rien ne touche le disque et le tableau d'échantillons est disponible dès le
/// relâchement de la touche : plus de WAV temporaire, plus d'en-tête supposé de
/// 44 octets, plus d'attente de 0,1 s.
///
/// **Concurrence** — ce qui a motivé cette structure :
/// - `start` / `stop` / `cleanup` et les callbacks sont sur le **main thread** ;
/// - le bloc de tap tourne sur un **thread audio temps réel** et ne touche que
///   `AudioSampleSink`, via `NSLock`, sans allocation ni dispatch ;
/// - le convertisseur est capturé **par valeur immuable** dans le bloc de tap,
///   jamais relu depuis une propriété : une propriété `var converter` écrite par
///   `stop()` et lue par le tap est une course de données réelle, que
///   `@unchecked Sendable` masque sans la corriger ;
/// - `onLevel` et `onSilenceTimeout` sont appelés par un timer à 30 Hz côté main
///   thread, pas depuis le thread audio : spawner un `Task { @MainActor }` par
///   bloc audio alloue sur le thread de rendu et inonde le main actor.
@MainActor
final class AudioRecorder {
    static let shared = AudioRecorder()

    /// Niveau du micro entre 0 et 1, appelé sur le main thread à 30 Hz.
    var onLevel: ((Float) -> Void)?
    /// Silence prolongé après de la parole, ou durée maximale atteinte.
    var onSilenceTimeout: (() -> Void)?

    /// Format attendu par la transcription en direct, à régler avant `start()`.
    /// Nil désactive complètement ce chemin.
    var liveOutputFormat: AVAudioFormat?

    /// Durée de silence avant déclenchement de `onSilenceTimeout`.
    var silenceTimeout: TimeInterval = 1.5
    /// Garde-fou contre un raccourci resté enfoncé. La capacité du tampon en
    /// découle : deux constantes indépendantes finissaient par diverger, et le
    /// tampon cessait d'accepter des échantillons avant que l'arrêt automatique
    /// ne se déclenche — enregistrement sans fin, audio jeté en silence.
    static let maximumDuration: TimeInterval = 120

    static let sampleRate: Double = 16_000

    /// Seuil d'énergie du détecteur de silence pour l'arrêt automatique.
    /// Volontairement bas : à 0,006 une voix posée à bout de bras passe pour du
    /// silence et l'enregistrement se coupe en pleine phrase.
    private static let silenceThreshold: Float = 0.0015

    /// 120 s × 16 kHz × 4 octets ≈ 7,7 Mo, réservés au premier démarrage.
    private static let maximumSampleCount = Int(sampleRate * maximumDuration)

    private let engine = AVAudioEngine()
    private let sink = AudioSampleSink(
        capacity: maximumSampleCount,
        silenceThreshold: silenceThreshold
    )

    private let liveConsumer = LiveConsumerBox()
    private var isCapturing = false
    private var pollTimer: Timer?
    private var silenceFired = false
    private var configurationObserver: NSObjectProtocol?

    private init() {
        observeConfigurationChanges()
    }

    // MARK: - État

    var isRecording: Bool { isCapturing }

    /// Branche (ou débranche) le consommateur du direct en cours de capture.
    func setLiveConsumer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        liveConsumer.set(handler)
    }

    // MARK: - Démarrage

    func start() throws {
        guard !isCapturing else { return }

        // Sans cette vérification, macOS livre un moteur qui tourne et ne
        // délivre que du silence : l'utilisateur voit « Aucune parole détectée »
        // indéfiniment sans savoir pourquoi.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:          break
        case .notDetermined:       throw AudioRecorderError.microphonePending
        case .denied, .restricted: throw AudioRecorderError.microphoneDenied
        @unknown default:          throw AudioRecorderError.microphoneDenied
        }

        sink.reset()
        silenceFired = false

        let inputNode = engine.inputNode
        // `inputFormat(forBus:)` est le format matériel. `outputFormat(forBus:)`
        // décrit la sortie du nœud et peut différer en nombre de canaux ; passer
        // un format qui ne correspond pas à `installTap` lève une NSException,
        // donc un crash que Swift ne peut pas rattraper.
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            audioLogger.error("Format d'entrée invalide (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) canaux)")
            throw AudioRecorderError.noInputDevice
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioRecorderError.converterUnavailable(from: inputFormat.sampleRate)
        }
        // `.max` sature un cœur sur le thread audio pour un gain inaudible à 16 kHz.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.downmix = true

        let sink = self.sink

        // Second convertisseur, vers le format exact du moteur système : le
        // chemin « flux de buffers » de SpeechAnalyzer ne convertit rien tout seul.
        let live: (converter: AVAudioConverter, format: AVAudioFormat, box: LiveConsumerBox)?
        if let liveOutputFormat, let liveConverter = AVAudioConverter(from: inputFormat, to: liveOutputFormat) {
            liveConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            liveConverter.downmix = true
            live = (liveConverter, liveOutputFormat, liveConsumer)
        } else {
            live = nil
        }

        // 4096 trames ≈ 85 ms à 48 kHz : assez pour amortir la conversion, assez
        // peu pour que le niveau affiché reste réactif.
        // `@Sendable` n'est pas décoratif ici : `AVAudioNodeTapBlock` n'est pas
        // déclaré Sendable, donc une fermeture créée dans cette méthode
        // `@MainActor` **hérite de l'isolation du main actor**. Le bloc est
        // appelé depuis le thread audio temps réel : en Swift 6, le runtime y
        // vérifie l'exécuteur courant et abandonne le processus
        // (`dispatch_assert_queue` → SIGTRAP). `@Sendable` détache la fermeture
        // de l'acteur, ce qui est correct puisqu'elle ne touche que des valeurs
        // immuables et le tampon verrouillé.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            Self.convert(buffer: buffer, with: converter, to: target, into: sink)
            if let live, live.box.isAttached,
               let converted = Self.convert(buffer: buffer, with: live.converter, to: live.format) {
                live.box.deliver(converted)
            }
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioLogger.error("AVAudioEngine.start: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }

        isCapturing = true
        startPolling()
        audioLogger.info("Enregistrement démarré (\(Int(inputFormat.sampleRate)) Hz × \(inputFormat.channelCount) → 16 kHz mono)")
    }

    // MARK: - Arrêt

    /// Arrête l'enregistrement et rend les échantillons capturés.
    @discardableResult
    func stop() -> [Float] {
        guard isCapturing else { return [] }

        stopPolling()
        liveConsumer.set(nil)
        // `stop()` puis `removeTap` : au retour, aucun bloc de tap n'est plus en
        // vol, d'où la disparition du délai de 0,1 s de la version précédente.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false

        let captured = sink.drain()
        audioLogger.info("Enregistrement arrêté : \(captured.count) échantillons (\(String(format: "%.2f", Double(captured.count) / 16000.0)) s)")
        return captured
    }

    /// Abandonne la capture sans rien rendre.
    func discard() {
        guard isCapturing else { return }
        stopPolling()
        liveConsumer.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        sink.reset()
        audioLogger.info("Enregistrement abandonné")
    }

    func cleanup() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if isCapturing { discard() }
        liveConsumer.set(nil)
        onLevel = nil
        onSilenceTimeout = nil
        engine.reset()
    }

    // MARK: - Surveillance (main thread, 30 Hz)

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard isCapturing else { return }

        let state = sink.snapshot()
        onLevel?(state.level)

        guard !silenceFired else { return }

        let silentDuration = Double(state.silentSampleCount) / Self.sampleRate
        let totalDuration = Double(state.sampleCount) / Self.sampleRate

        if state.hadSpeech, silentDuration >= silenceTimeout {
            silenceFired = true
            audioLogger.info("Silence de \(String(format: "%.1f", silentDuration)) s après parole, arrêt automatique")
            onSilenceTimeout?()
        } else if totalDuration >= Self.maximumDuration {
            silenceFired = true
            audioLogger.notice("Durée maximale de \(Int(Self.maximumDuration)) s atteinte, arrêt automatique")
            onSilenceTimeout?()
        }
    }

    // MARK: - Conversion (thread audio)

    /// `AVAudioConverter` en mode « input block » : un rééchantillonnage
    /// 48 → 16 kHz n'est pas une relation 1:1 entre trames d'entrée et de
    /// sortie, et `convert(to:from:)` échouerait avec
    /// `kAudioConverterErr_InvalidInputSize`.
    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat,
        into sink: AudioSampleSink
    ) {
        guard let output = convert(buffer: buffer, with: converter, to: format) else { return }
        guard let channel = output.floatChannelData?[0] else { return }
        sink.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Même conversion, mais rend le buffer au lieu de l'accumuler : utilisé
    /// pour alimenter le moteur système, qui veut son propre format.
    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // Le bloc d'entrée est appelé de façon synchrone par le convertisseur,
        // mais il est typé `@Sendable` : un `var` local capturé déclenche un
        // avertissement de concurrence légitime. Une boîte lève l'ambiguïté.
        let state = ConversionState()
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            if let conversionError {
                audioLogger.error("Conversion audio : \(conversionError.localizedDescription, privacy: .public)")
            }
            return nil
        @unknown default:
            return nil
        }

        guard output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Changement de configuration audio

    /// macOS poste `AVAudioEngineConfigurationChange` quand l'entrée par défaut
    /// change (AirPods connectés, casque branché). Le graphe est invalidé : sans
    /// réaction, le tap ne reçoit plus rien et la dictée part silencieuse.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                audioLogger.notice("Configuration audio modifiée pendant la capture, arrêt")
                self.discard()
                NotificationCenter.default.post(name: .audioCaptureInterrupted, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Postée sur le main thread quand le système interrompt la capture.
    static let audioCaptureInterrupted = Notification.Name("audioCaptureInterrupted")
}
