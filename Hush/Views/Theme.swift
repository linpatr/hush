import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.063)
    static let card = Color(red: 0.082, green: 0.094, blue: 0.129)
    static let cardRaised = Color(red: 0.115, green: 0.13, blue: 0.175)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.64, green: 0.80, blue: 1.0)

    /// One color per layer.
    static let tints: [Color] = [
        Color(red: 0.36, green: 0.84, blue: 0.78),
        Color(red: 0.98, green: 0.74, blue: 0.36),
        Color(red: 0.71, green: 0.62, blue: 0.99),
        Color(red: 0.98, green: 0.54, blue: 0.54),
        Color(red: 0.45, green: 0.72, blue: 0.99),
        Color(red: 0.72, green: 0.88, blue: 0.42),
    ]

    static func tint(_ index: Int) -> Color {
        tints[((index % tints.count) + tints.count) % tints.count]
    }
}

extension View {
    /// The rounded panel every block of controls sits on.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke))
    }
}
