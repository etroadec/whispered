import SwiftUI

/// Onde audio en barres, alimentée par les niveaux réels du micro.
///
/// Remplace le cercle qui pulsait indépendamment de ce que captait le micro :
/// ici, si rien n'entre, les barres restent plates.
struct WaveformView: View {
    let levels: [Float]
    let isActive: Bool

    /// Hauteur des barres au repos, en proportion de la hauteur disponible
    private let idleRatio: CGFloat = 0.06
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int((geo.size.width + spacing) / (barWidth + spacing)))
            let shown = paddedLevels(count: count)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color(for: level))
                        .frame(width: barWidth, height: height(for: level, in: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: shown)
        }
        .accessibilityLabel(isActive ? "Niveau du micro" : "Micro inactif")
    }

    /// Les niveaux arrivent à droite et défilent vers la gauche ; on complète à
    /// gauche avec du silence tant qu'on n'a pas assez d'échantillons.
    private func paddedLevels(count: Int) -> [Float] {
        if levels.count >= count {
            return Array(levels.suffix(count))
        }
        return Array(repeating: 0, count: count - levels.count) + levels
    }

    private func height(for level: Float, in available: CGFloat) -> CGFloat {
        let minHeight = available * idleRatio
        guard isActive else { return minHeight }
        // Racine carrée : les niveaux faibles restent visibles sans écraser les forts
        let scaled = CGFloat(sqrt(max(0, level)))
        return max(minHeight, scaled * available)
    }

    private func color(for level: Float) -> Color {
        guard isActive else { return Color.secondary.opacity(0.35) }
        // Rouge quand ça sature, pour qu'un micro trop près se voie
        return level > 0.92 ? .orange : .accentColor
    }
}

#if DEBUG
#Preview("Onde active") {
    WaveformView(
        levels: (0..<44).map { i in Float(abs(sin(Double(i) / 3)) * 0.8) },
        isActive: true
    )
    .frame(width: 240, height: 48)
    .padding()
}
#endif
