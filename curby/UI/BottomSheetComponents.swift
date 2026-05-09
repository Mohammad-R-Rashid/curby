//
//  BottomSheetComponents.swift
//  curby
//
//  Shared, minimal UI components for draggable bottom sheets.
//

import MapKit
import SwiftUI
import UIKit

// MARK: - Minimal Status Card

struct MinimalStatusCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 36, height: 36)

                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if let actionTitle, let action {
                    Button {
                        CurbyHaptics.medium()
                        action()
                    } label: {
                        Text(actionTitle)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(tint.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .curbyGlassSurface(tint: tint, cornerRadius: CurbyGlass.compactCornerRadius)
        .padding(.horizontal, 16)
    }
}

// MARK: - Compact Metric Row

struct CompactMetricRow: View {
    let walkMinutes: Int?
    let driveMinutes: Int?
    let trafficScore: Double?
    /// Kept for source compat — no longer rendered here. The Match score
    /// lives prominently in UnifiedRecommendationCard's header now, instead
    /// of being crammed into a fourth cell with a label that always
    /// truncated.
    var customLabel: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let walkMinutes {
                metricCell(
                    systemImage: "figure.walk",
                    value: "\(walkMinutes) min",
                    label: "Walk",
                    tint: CurbyGlass.successTint
                )
            }

            if let driveMinutes {
                metricCell(
                    systemImage: "car.fill",
                    value: "\(driveMinutes) min",
                    label: "Drive",
                    tint: CurbyGlass.primaryTint
                )
            }

            if let trafficScore {
                metricCell(
                    systemImage: "cone.fill",
                    value: "\(Int(((1 - trafficScore) * 100).rounded()))%",
                    label: "Traffic",
                    tint: CurbyGlass.destinationTint
                )
            }
        }
    }

    private func metricCell(systemImage: String, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)

                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        )
    }
}

// MARK: - Minimal Action Button Row

struct MinimalActionButtonRow: View {
    let onNavigate: () -> Void
    let onMarkAsParked: (() -> Void)?
    /// Kept for source compatibility but no longer used to disable / relabel
    /// the button. The global `parkingEventDetector.presenceState` flips to
    /// `.parked` whenever the phone sits still long enough — at the user's
    /// home, at a desk, anywhere — which made "Park here" appear disabled
    /// for trips where the user clearly hadn't actually parked yet. The
    /// orange "Your Car" pin on the map already conveys saved-park state;
    /// this button is for explicit user intent and stays tappable.
    let isParked: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let onMarkAsParked {
                Button {
                    CurbyHaptics.medium()
                    onMarkAsParked()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Park here")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(CurbyGlass.successTint)
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                CurbyHaptics.light()
                onNavigate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Navigate")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CurbyGlass.primaryTint)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Unified Recommendation Card

struct UnifiedRecommendationCard: View {
    let recommendation: CurbyParkingRecommendation
    let isParked: Bool
    let onNavigate: () -> Void
    /// Kept as optional callbacks for callers, but the card no longer renders
    /// Retry / Cancel buttons — they were confusing ("retry what?", "cancel
    /// what?") and clearing the destination via the search-bar X already
    /// does the right thing.
    let onCancel: (() -> Void)?
    let onRetry: (() -> Void)?

    private var matchPercent: Int {
        Int((recommendation.score.score * 100).rounded())
    }

    private var matchTint: Color {
        switch matchPercent {
        case 75...:    return CurbyGlass.successTint
        case 55..<75:  return CurbyGlass.primaryTint
        case 40..<55:  return CurbyGlass.warningTint
        default:       return CurbyGlass.destinationTint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — name on the left, big real % match on the right.
            // Replaces the previous fuzzy "Strong match / Okay option"
            // labels with an actual score the user asked for.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.area.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(recommendation.area.categoryLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(matchPercent)%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(matchTint)
                    Text("Match")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                }
            }

            CompactMetricRow(
                walkMinutes: max(1, Int(round(recommendation.route.walkTimeSec / 60))),
                driveMinutes: max(1, Int(round(recommendation.route.travelTimeSec / 60))),
                trafficScore: recommendation.score.breakdown.congestion
            )

            Button {
                CurbyHaptics.light()
                onNavigate()
            } label: {
                Text("Navigate")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .curbyGlassSurface(tint: CurbyGlass.primaryTint, cornerRadius: CurbyGlass.compactCornerRadius)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .curbyGlassSurface(tint: CurbyGlass.primaryTint, cornerRadius: CurbyGlass.cardCornerRadius)
        .padding(.horizontal, 16)
    }
}
