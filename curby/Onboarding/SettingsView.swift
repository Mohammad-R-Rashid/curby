//
//  SettingsView.swift
//  curby
//
//  Re-entry settings — adjust permissions and walking distance.
//

import CoreLocation
import PhosphorSwift
import SwiftUI

/// Settings sheet accessible from the main map.
///
/// Lets the user adjust walking distance and review/change
/// location permission status at any time after onboarding.
struct SettingsView: View {

    @State private var state = OnboardingState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Location Permission
                Section {
                    locationRow
                } header: {
                    Text("Location")
                } footer: {
                    Text("Curby needs your location to find parking near you.")
                        .font(.footnote)
                }

                // MARK: - Walking Distance
                Section {
                    walkingRow
                    sliderRow
                } header: {
                    Text("Walking Distance")
                } footer: {
                    Text("Only parking within this distance will be shown.")
                        .font(.footnote)
                }

                // MARK: - About
                Section {
                    aboutRow
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            state.refreshPermissions()
        }
    }

    // MARK: - Location Row

    private var locationRow: some View {
        HStack(spacing: 14) {
            Ph.crosshairSimple.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background(CurbyGlass.primaryTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Location Access")
                    .font(.body)

                Text(locationStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.locationGranted {
                Ph.checkCircle.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(CurbyGlass.successTint)
                    .frame(width: 22, height: 22)
            } else {
                Button {
                    state.requestLocationPermission()
                } label: {
                    Text(state.locationDenied ? "Open Settings" : "Enable")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .animation(.spring(response: 0.3), value: state.locationGranted)
    }

    private var locationStatusLabel: String {
        switch state.locationStatus {
        case .authorizedAlways:
            return "Always"
        case .authorizedWhenInUse:
            return "While Using App"
        case .denied, .restricted:
            return "Denied"
        default:
            return "Not Determined"
        }
    }

    // MARK: - Walking Distance

    private var walkingRow: some View {
        HStack {
            Ph.personSimpleWalk.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background(CurbyGlass.successTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("Max Distance")
                .font(.body)

            Spacer()

            Text(String(format: "%.2f mi", state.walkingCircumference))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(CurbyGlass.successTint)
                .contentTransition(.numericText())
        }
    }

    private var sliderRow: some View {
        VStack(spacing: 6) {
            Slider(
                value: $state.walkingCircumference,
                in: CurbyConstants.walkingCircumferenceMin...CurbyConstants.walkingCircumferenceMax,
                step: CurbyConstants.walkingCircumferenceStep
            )
            .tint(CurbyGlass.successTint)

            HStack {
                Text(String(format: "%.1f mi", CurbyConstants.walkingCircumferenceMin))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(String(format: "%.1f mi", CurbyConstants.walkingCircumferenceMax))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - About

    private var aboutRow: some View {
        HStack {
            Ph.car.fill
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background(Color.gray, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("Curby")
                .font(.body)

            Spacer()

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
