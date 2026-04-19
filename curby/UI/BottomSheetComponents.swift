//
//  BottomSheetComponents.swift
//  curby
//
//  Shared, minimal UI components for draggable bottom sheets.
//

import MapKit
import PhosphorSwift
import SwiftUI
import UIKit

// MARK: - Minimal Status Card

struct MinimalStatusCard: View {
    let title: String
    let icon: Ph
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

                    icon.fill
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(tint)
                        .frame(width: 16, height: 16)
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
    var customLabel: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let walkMinutes {
                metricCell(
                    icon: .personSimpleWalk,
                    value: "\(walkMinutes)m",
                    label: "Walk",
                    tint: CurbyGlass.successTint
                )
            }

            if let driveMinutes {
                metricCell(
                    icon: .carProfile,
                    value: "\(driveMinutes)m",
                    label: "Drive",
                    tint: CurbyGlass.primaryTint
                )
            }

            if let trafficScore {
                metricCell(
                    icon: .trafficCone,
                    value: "\(Int(((1 - trafficScore) * 100).rounded()))%",
                    label: "Traffic",
                    tint: CurbyGlass.destinationTint
                )
            }

            if let customLabel {
                metricCell(
                    icon: .info,
                    value: customLabel,
                    label: "Match",
                    tint: CurbyGlass.warningTint
                )
            }
        }
    }

    private func metricCell(icon: Ph, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                icon.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
                    .frame(width: 12, height: 12)

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
    let isParked: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let onMarkAsParked {
                Button {
                    if !isParked {
                        CurbyHaptics.medium()
                        onMarkAsParked()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Ph.park.fill
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                        Text(isParked ? "Parked" : "Park here")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(isParked ? Color.black.opacity(0.85) : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isParked ? CurbyGlass.warningTint : CurbyGlass.successTint)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isParked)
            }

            Button {
                CurbyHaptics.light()
                onNavigate()
            } label: {
                HStack(spacing: 6) {
                    Ph.navigationArrow.fill
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
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
    let onCancel: (() -> Void)?
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(recommendation.area.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(recommendation.area.categoryLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(CurbyGlass.primaryTint))
            }

            CompactMetricRow(
                walkMinutes: max(1, Int(round(recommendation.route.walkTimeSec / 60))),
                driveMinutes: max(1, Int(round(recommendation.route.travelTimeSec / 60))),
                trafficScore: recommendation.score.breakdown.congestion,
                customLabel: recommendation.matchQualityShortLabel
            )

            HStack(spacing: 8) {
                Button {
                    CurbyHaptics.light()
                    onNavigate()
                } label: {
                    Text("Open Spot")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .curbyGlassSurface(tint: CurbyGlass.primaryTint, cornerRadius: CurbyGlass.compactCornerRadius)
                }
                .buttonStyle(.plain)

                if let onRetry {
                    Button {
                        CurbyHaptics.medium()
                        onRetry()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .curbyGlassSurface(tint: nil, cornerRadius: CurbyGlass.compactCornerRadius)
                    }
                    .buttonStyle(.plain)
                }

                if let onCancel {
                    Button {
                        CurbyHaptics.light()
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .curbyGlassSurface(tint: CurbyGlass.destinationTint, cornerRadius: CurbyGlass.compactCornerRadius)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .curbyGlassSurface(tint: CurbyGlass.primaryTint, cornerRadius: CurbyGlass.cardCornerRadius)
        .padding(.horizontal, 16)
    }
}
