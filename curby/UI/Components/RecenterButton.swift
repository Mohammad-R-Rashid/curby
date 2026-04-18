//
//  RecenterButton.swift
//  curby
//
//  Animated recenter button with haptic feedback.
//

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
            triggerHaptic()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )

                Image(systemName: "location.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(
                width: CurbyConstants.overlayButtonSize,
                height: CurbyConstants.overlayButtonSize
            )
            .scaleEffect(isPressed ? 0.9 : 1.0)
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

    // MARK: - Haptics

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
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
