//
//  OnboardingView.swift
//  curby
//
//  First-launch welcome screen — permissions and walking preference.
//

import SwiftUI

/// Welcome screen shown on first launch.
///
/// Requests location and calendar permissions, lets the user set
/// their comfortable walking distance, then navigates to the main app.
/// Uses Liquid Glass design throughout.
struct OnboardingView: View {

    @State private var state = OnboardingState()
    @Binding var hasCompletedOnboarding: Bool

    @State private var showContent = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.08, blue: 0.14),
                    Color(red: 0.08, green: 0.14, blue: 0.24),
                    Color(red: 0.03, green: 0.06, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Subtle animated circles in background
            backgroundOrbs

            ScrollView {
                VStack(spacing: 32) {
                    // MARK: - Header
                    headerSection
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 30)

                    // MARK: - Permission Cards (Liquid Glass)
                    permissionSection
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 40)

                    // MARK: - Walking Circumference (Liquid Glass)
                    walkingSection
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 50)

                    // MARK: - Continue Button (Liquid Glass)
                    continueButton
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 60)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                showContent = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            // App icon
            Image(systemName: "car.side.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .glassEffect(.regular.tint(CurbyGlass.primaryTint.opacity(0.18)), in: .circle)
                .overlay {
                    Circle()
                        .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
                }
                .shadow(color: CurbyGlass.primaryTint.opacity(0.35), radius: 20, y: 8)

            Text("Welcome to Curby")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Find parking before you arrive")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.bottom, 8)
    }

    // MARK: - Permissions (Liquid Glass)

    private var permissionSection: some View {
        VStack(spacing: 16) {
            Text("Get Started")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .textCase(.uppercase)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Location permission
            permissionCard(
                icon: "location.fill",
                iconColor: CurbyGlass.primaryTint,
                title: "Location Access",
                description: "See your position and find parking near you",
                isGranted: state.locationGranted,
                isRequired: true
            ) {
                state.requestLocationPermission()
            }

            // Calendar permission
            permissionCard(
                icon: "calendar",
                iconColor: CurbyGlass.warningTint,
                title: "Calendar Access",
                description: "Smart suggestions from your upcoming events",
                isGranted: state.calendarGranted,
                isRequired: false
            ) {
                state.requestCalendarPermission()
            }
        }
    }

    private func permissionCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        isGranted: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 48, height: 48)
            }
            .curbyGlassSurface(tint: iconColor, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    if isRequired {
                        Text("Required")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.14))
                            )
                    }
                }

                Text(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.64))
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: action) {
                    Text("Allow")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 72)
                }
                .buttonStyle(.glass)
                .tint(iconColor)
            }
        }
        .padding(16)
        .curbyGlassSurface(tint: iconColor, cornerRadius: CurbyGlass.cardCornerRadius)
        .animation(.spring(response: 0.3), value: isGranted)
    }

    // MARK: - Walking Circumference (Liquid Glass)

    private var walkingSection: some View {
        VStack(spacing: 16) {
            Text("Walking Distance")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .textCase(.uppercase)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                HStack {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 20))
                        .foregroundStyle(CurbyGlass.successTint)

                    Text("How far will you walk?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Text(String(format: "%.2f mi", state.walkingCircumference))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(CurbyGlass.successTint)
                        .contentTransition(.numericText())
                }

                // Slider
                VStack(spacing: 8) {
                    Slider(
                        value: $state.walkingCircumference,
                        in: CurbyConstants.walkingCircumferenceMin...CurbyConstants.walkingCircumferenceMax,
                        step: CurbyConstants.walkingCircumferenceStep
                    )
                    .tint(CurbyGlass.successTint)

                    HStack {
                        Text("\(String(format: "%.1f", CurbyConstants.walkingCircumferenceMin)) mi")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.42))

                        Spacer()

                        Text("\(String(format: "%.1f", CurbyConstants.walkingCircumferenceMax)) mi")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }

                Text("Only parking within this distance will be shown")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .curbyGlassSurface(
                tint: CurbyGlass.successTint,
                cornerRadius: CurbyGlass.cardCornerRadius
            )
        }
    }

    // MARK: - Continue Button (Liquid Glass)

    private var continueButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            state.completeOnboarding()
            withAnimation(.spring(response: 0.4)) {
                hasCompletedOnboarding = true
            }
        } label: {
            HStack(spacing: 8) {
                Text("Get Started")
                    .font(.system(size: 17, weight: .semibold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.glassProminent)
        .tint(CurbyGlass.primaryTint)
        .disabled(!state.locationGranted)
        .opacity(state.locationGranted ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.3), value: state.locationGranted)
    }

    // MARK: - Background Orbs

    private var backgroundOrbs: some View {
        ZStack {
            Circle()
                .fill(CurbyGlass.primaryTint.opacity(0.10))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: -100, y: -200)

            Circle()
                .fill(CurbyGlass.warningTint.opacity(0.08))
                .frame(width: 250, height: 250)
                .blur(radius: 60)
                .offset(x: 120, y: 300)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
