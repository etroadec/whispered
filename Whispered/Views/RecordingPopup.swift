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
        case .standard: return NSSize(width: 280, height: 220)
        case .compact: return NSSize(width: 220, height: 80)
        }
    }
}

// MARK: - Main Recording Popup

struct RecordingPopup: View {
    @ObservedObject var state: RecordingState
    let mode: PopupMode
    
    var body: some View {
        Group {
            switch mode {
            case .standard:
                StandardPopupContent(state: state)
            case .compact:
                CompactPopupContent(state: state)
            }
        }
    }
}

// MARK: - Hotkey Hint Helper

private struct HotkeyHintHelper {
    static var currentHotkey: HotkeyChoice {
        HotkeySettingsManager.shared.hotkeyChoice
    }
    
    static var currentMode: RecordingMode {
        HotkeySettingsManager.shared.recordingMode
    }
    
    static var recordHint: String {
        let key = currentHotkey.fullDescription
        switch currentMode {
        case .hold:
            return "Maintenez \(key) pour enregistrer"
        case .toggle:
            return "Appuyez sur \(key) pour enregistrer"
        }
    }
    
    static var stopHint: String {
        let key = currentHotkey.fullDescription
        switch currentMode {
        case .hold:
            return "\(key) pour arreter"
        case .toggle:
            return "\(key) pour arreter"
        }
    }
}

// MARK: - Standard Mode (Full)

struct StandardPopupContent: View {
    @ObservedObject var state: RecordingState
    @State private var animationAmount = 1.0
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Micro avec animation
            ZStack {
                Circle()
                    .stroke(state.isRecording ? Color.red.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 2)
                    .frame(width: 80, height: 80)
                
                if state.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 4)
                        .frame(width: 80, height: 80)
                        .scaleEffect(animationAmount)
                        .opacity(2 - animationAmount)
                        .animation(
                            .easeInOut(duration: 1)
                                .repeatForever(autoreverses: false),
                            value: animationAmount
                        )
                }
                
                Image(systemName: state.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 30))
                    .foregroundColor(state.isRecording ? .red : .primary)
            }
            .onAppear {
                animationAmount = 2.0
            }
            
            Spacer()
                .frame(height: 20)
            
            // Statut
            Text(state.statusText)
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
                .frame(height: 12)
            
            // Zone de texte secondaire
            Group {
                if !state.lastTranscription.isEmpty && !state.isRecording && state.statusText != "Pret" {
                    Text(state.lastTranscription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    Text(HotkeyHintHelper.recordHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 16)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compact Mode (Mini)

struct CompactPopupContent: View {
    @ObservedObject var state: RecordingState
    @State private var animationAmount = 1.0
    
    var body: some View {
        HStack(spacing: 14) {
            // Micro compact avec animation
            ZStack {
                Circle()
                    .stroke(state.isRecording ? Color.red.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 2)
                    .frame(width: 44, height: 44)
                
                if state.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .scaleEffect(animationAmount)
                        .opacity(2 - animationAmount)
                        .animation(
                            .easeInOut(duration: 1)
                                .repeatForever(autoreverses: false),
                            value: animationAmount
                        )
                }
                
                Image(systemName: state.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 18))
                    .foregroundColor(state.isRecording ? .red : .primary)
            }
            .onAppear {
                animationAmount = 2.0
            }
            
            // Statut texte
            VStack(alignment: .leading, spacing: 2) {
                Text(state.statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text(HotkeyHintHelper.stopHint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
