import SwiftUI

struct RecordingPopup: View {
    @ObservedObject var state: RecordingState
    @State private var animationAmount = 1.0

    var body: some View {
        VStack(spacing: 16) {
            // Waveform animation
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

            // Status text
            Text(state.statusText)
                .font(.headline)
                .foregroundColor(.primary)

            // Last transcription preview
            if !state.lastTranscription.isEmpty && !state.isRecording {
                Text(state.lastTranscription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Instructions
            if !state.isRecording && state.statusText == "Prêt" {
                Text("Maintenez ⌘ droite pour enregistrer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(minWidth: 280)
    }
}

struct WaveformView: View {
    var audioLevel: Float
    @State private var bars = Array(repeating: CGFloat.random(in: 0.2...0.5), count: 5)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red)
                    .frame(width: 4, height: bars[index] * 40)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                for i in 0..<5 {
                    bars[i] = CGFloat.random(in: 0.3...1.0)
                }
            }
        }
    }
}
