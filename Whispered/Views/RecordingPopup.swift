import SwiftUI

struct RecordingPopup: View {
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

            // Zone de texte secondaire (toujours présente pour la cohérence)
            Group {
                if !state.lastTranscription.isEmpty && !state.isRecording && state.statusText != "Prêt" {
                    Text(state.lastTranscription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Maintenez ⌘ droite pour enregistrer")
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
