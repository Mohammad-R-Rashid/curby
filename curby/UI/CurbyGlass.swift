//
//  CurbyGlass.swift
//  curby
//
//  Shared Liquid Glass styling tokens.
//

import SwiftUI

enum CurbyGlass {
    static let primaryTint = Color(red: 0.18, green: 0.56, blue: 1.0)
    static let successTint = Color(red: 0.42, green: 0.82, blue: 0.45)
    static let warningTint = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let destinationTint = Color(red: 0.96, green: 0.34, blue: 0.28)

    static let outline = LinearGradient(
        colors: [
            Color.white.opacity(0.24),
            Color.white.opacity(0.08)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let barCornerRadius: CGFloat = 28
    static let cardCornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 16
    static let chromeSpacing: CGFloat = 18
}

private struct CurbyGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .glassEffect(glass, in: shape)
            .overlay {
                shape.strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
            }
    }

    private var glass: Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint.opacity(0.18))
    }
}

extension View {
    func curbyGlassSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = CurbyGlass.cardCornerRadius
    ) -> some View {
        modifier(CurbyGlassSurfaceModifier(tint: tint, cornerRadius: cornerRadius))
    }
}
