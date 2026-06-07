import SwiftUI

enum AloTheme {
    static let background = Color(red: 0.030, green: 0.031, blue: 0.038)
    static let surface = Color(red: 0.070, green: 0.071, blue: 0.084)
    static let surfaceRaised = Color(red: 0.112, green: 0.113, blue: 0.132)
    static let text = Color.white
    static let muted = Color(red: 0.62, green: 0.62, blue: 0.68)
    static let border = Color.white.opacity(0.035)
    static let accent = Color(red: 0.09, green: 0.49, blue: 1.0)
    static let outgoing = Color(red: 0.10, green: 0.50, blue: 1.0)
    static let incoming = Color(red: 0.13, green: 0.14, blue: 0.17)
}

extension View {
    func aloCard(radius: CGFloat = 24) -> some View {
        background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AloTheme.border, lineWidth: 1)
            )
    }
}
