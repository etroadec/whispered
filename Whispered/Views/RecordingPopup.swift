import SwiftUI

// MARK: - Popup Mode Enum

enum PopupMode: String, CaseIterable {
    case standard = "standard"
    case compact = "compact"

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact"
        }
    }

    var size: NSSize {
        switch self {
        case .standard: return NSSize(width: 300, height: 200)
        case .compact: return NSSize(width: 240, height: 76)
        }
    }
}

// MARK: - Main Recording Popup

struct RecordingPopup: View {
    @ObservedObject var state: RecordingState
    let mode: PopupMode

    var body: some View {
        switch mode {
        case .standard:
            StandardPopupContent(state: state)
        case .compact:
            CompactPopupContent(state: state)
        }
    }
}

// MARK: - Rappel du raccourci

private struct HotkeyHintHelper {
    static var recordHint: String {
        let key = HotkeySettingsManager.shared.hotkeyChoice.fullDescription
        switch HotkeySettingsManager.shared.recordingMode {
        case .hold: return "Maintenez \(key) pour dicter"
        case .toggle: return "Appuyez sur \(key) pour dicter"
        }
    }

    static var stopHint: String {
        "\(HotkeySettingsManager.shared.hotkeyChoice.fullDescription) pour arrêter"
    }
}

// MARK: - Mode standard

struct StandardPopupContent: View {
    @ObservedObject var state: RecordingState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: state.isRecording ? "mic.fill" : "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.isRecording ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: state.isRecording)

                Text(state.statusText)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }

            WaveformView(levels: state.levels, isActive: state.isRecording)
                .frame(height: 56)

            // Texte en direct pendant la dictée, dernier texte ensuite,
            // rappel du raccourci au repos
            Group {
                if state.isRecording && !state.liveText.isEmpty {
                    Text(state.liveText)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !state.lastTranscription.isEmpty && !state.isRecording {
                    Text(state.lastTranscription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(state.isRecording ? HotkeyHintHelper.stopHint : HotkeyHintHelper.recordHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 46, alignment: .top)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Mode compact

struct CompactPopupContent: View {
    @ObservedObject var state: RecordingState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.isRecording ? "mic.fill" : "waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(state.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: state.isRecording)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                WaveformView(levels: state.levels, isActive: state.isRecording)
                    .frame(height: 22)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
