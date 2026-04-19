//
//  OnboardingView.swift
//  curby
//
//  Premium single-screen onboarding — permissions + walking distance.
//

import PhosphorSwift
import SwiftUI

/// Single-screen welcome shown on first launch.
///
/// Minimal text, premium aesthetic. Requests location (Always) and
/// calendar permissions, lets the user set walking distance, then
/// transitions to the main app.
struct OnboardingView: View {

    @State private var state = OnboardingState()
    @Binding var hasCompletedOnboarding: Bool

    // MARK: - Animation State

    @State private var showHero = false
    @State private var showPermissions = false
    @State private var showSlider = false
    @State private var showCTA = false
    @State private var pulseGlow = false

    var body: some View {
        ZStack {
            // Deep gradient background
            backgroundGradient

            // Ambient glow orbs
            backgroundOrbs

            VStack(spacing: 0) {
                Spacer()

                // MARK: - Hero
                heroSection
                    .opacity(showHero ? 1 : 0)
                    .scaleEffect(showHero ? 1 : 0.85)
                    .offset(y: showHero ? 0 : 20)

                Spacer()
                    .frame(height: 48)

                // MARK: - Permissions Card
                permissionsCard
                    .opacity(showPermissions ? 1 : 0)
                    .offset(y: showPermissions ? 0 : 30)

                Spacer()
                    .frame(height: 20)

                // MARK: - Walking Slider
                walkingSliderRow
                    .opacity(showSlider ? 1 : 0)
                    .offset(y: showSlider ? 0 : 24)

                Spacer()

                // MARK: - CTA
                getStartedButton
                    .opacity(showCTA ? 1 : 0)
                    .offset(y: showCTA ? 0 : 20)

                Spacer()
                    .frame(height: 40)
            }
            .padding(.horizontal, 28)
        }
        .onAppear { runEntrance() }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            // Animated icon with glow ring
            ZStack {
                // Outer pulsing glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                CurbyGlass.primaryTint.opacity(0.35),
                                CurbyGlass.primaryTint.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulseGlow ? 1.15 : 0.95)
                    .opacity(pulseGlow ? 0.7 : 0.4)

                // Glass icon circle
                Ph.car.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular.tint(CurbyGlass.primaryTint.opacity(0.22)), in: .circle)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.4),
                                        CurbyGlass.primaryTint.opacity(0.2),
                                        .white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    }
                    .shadow(color: CurbyGlass.primaryTint.opacity(0.4), radius: 24, y: 8)
            }

            // Tagline
            VStack(spacing: 6) {
                Text("Find parking")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("before you arrive")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                CurbyGlass.primaryTint,
                                CurbyGlass.primaryTint.opacity(0.7)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
    }

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        VStack(spacing: 0) {
            // Location row
            permissionRow(
                icon: .crosshairSimple,
                tint: CurbyGlass.primaryTint,
                title: "Location",
                isGranted: state.locationGranted,
                isDenied: state.locationDenied,
                isRequired: true
            ) {
                state.requestLocationPermission()
            }
        }
        .curbyGlassSurface(cornerRadius: CurbyGlass.cardCornerRadius)
    }

    private func permissionRow(
        icon: Ph,
        tint: Color,
        title: String,
        isGranted: Bool,
        isDenied: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            icon.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Title + badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    if isRequired {
                        Text("Required")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }

                if isDenied {
                    Text("Denied — tap to open Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            // Status / action
            if isGranted {
                Ph.checkCircle.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(CurbyGlass.successTint)
                    .frame(width: 24, height: 24)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: action) {
                    Text(isDenied ? "Settings" : "Allow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(tint.opacity(0.25))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(tint.opacity(0.4), lineWidth: 0.75)
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.spring(response: 0.3), value: isGranted)
    }

    // MARK: - Walking Slider Row

    private var walkingSliderRow: some View {
        VStack(spacing: 12) {
            HStack {
                Ph.personSimpleWalk.bold
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(CurbyGlass.successTint)
                    .frame(width: 18, height: 18)

                Text("Walking distance")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Text(String(format: "%.2f mi", state.walkingCircumference))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(CurbyGlass.successTint)
                    .contentTransition(.numericText())
            }

            Slider(
                value: $state.walkingCircumference,
                in: CurbyConstants.walkingCircumferenceMin...CurbyConstants.walkingCircumferenceMax,
                step: CurbyConstants.walkingCircumferenceStep
            )
            .tint(CurbyGlass.successTint)
        }
        .padding(16)
        .curbyGlassSurface(tint: CurbyGlass.successTint, cornerRadius: CurbyGlass.cardCornerRadius)
    }

    // MARK: - Get Started Button

    private var getStartedButton: some View {
        Button {
            CurbyHaptics.medium()
            state.completeOnboarding()
            withAnimation(.spring(response: 0.4)) {
                hasCompletedOnboarding = true
            }
        } label: {
            HStack(spacing: 8) {
                Text("Get Started")
                    .font(.system(size: 17, weight: .semibold))

                Ph.arrowRight.bold
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.glassProminent)
        .tint(CurbyGlass.primaryTint)
        .disabled(!state.locationGranted)
        .opacity(state.locationGranted ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.3), value: state.locationGranted)
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.03, green: 0.06, blue: 0.14),
                Color(red: 0.06, green: 0.12, blue: 0.22),
                Color(red: 0.02, green: 0.04, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var backgroundOrbs: some View {
        ZStack {
            Circle()
                .fill(CurbyGlass.primaryTint.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -80, y: -240)

            Circle()
                .fill(CurbyGlass.warningTint.opacity(0.06))
                .frame(width: 220, height: 220)
                .blur(radius: 60)
                .offset(x: 140, y: 280)

            Circle()
                .fill(CurbyGlass.successTint.opacity(0.05))
                .frame(width: 180, height: 180)
                .blur(radius: 50)
                .offset(x: -120, y: 200)
        }
        .ignoresSafeArea()
    }

    // MARK: - Entrance Animation

    private func runEntrance() {
        withAnimation(.easeOut(duration: 0.7).delay(0.1)) {
            showHero = true
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.35)) {
            showPermissions = true
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) {
            showSlider = true
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.65)) {
            showCTA = true
        }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(0.8)) {
            pulseGlow = true
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
