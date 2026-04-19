//
//  RecenterButton.swift
//  curby
//
//  Animated recenter button with haptic feedback.
//

import PhosphorSwift
import SwiftUI

/// A premium-feeling recenter button that appears when the user is in free-explore mode.
///
/// Features spring animation on appear, haptic feedback on tap, and glassmorphism styling.
struct RecenterButton: View {

    /// Callback when tapped.
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            CurbyHaptics.medium()
            action()
        } label: {
            Ph.crosshairSimple.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(CurbyGlass.primaryTint)
                .frame(width: 22, height: 22)
                .frame(width: CurbyConstants.overlayButtonSize, height: CurbyConstants.overlayButtonSize)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay {
                    Circle()
                        .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .shadow(color: CurbyGlass.primaryTint.opacity(0.14), radius: 12, x: 0, y: 6)
                .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        isPressed = false
                    }
                }
        )
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.5).combined(with: .opacity)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7)),
                removal: .scale(scale: 0.8).combined(with: .opacity)
                    .animation(.easeOut(duration: 0.2))
            )
        )
        .accessibilityLabel("Re-center map on current location")
        .accessibilityIdentifier("recenter_button")
    }

}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()

        VStack {
            Spacer()
            HStack {
                Spacer()
                RecenterButton { print("Recenter tapped") }
                    .padding()
            }
        }
    }
}
