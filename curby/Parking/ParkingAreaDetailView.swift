//
//  ParkingAreaDetailView.swift
//  curby
//
//  Detail sheet for a real parking area pin.
//

import SwiftUI

struct ParkingAreaDetailView: View {
    let area: LiveParkingArea
    let recommendation: CurbyParkingRecommendation?
    let isParkedHere: Bool
    let onNavigate: () -> Void
    let onMarkAsParked: () -> Void
    var parkSaveState: ParkSaveState = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header (Name + Type)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(area.displayName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.primary)

                        if let subtitle = area.subtitleText ?? (area.detailSubtitle.isEmpty ? nil : area.detailSubtitle) {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 12)

                    Text(kindLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(kindTint))
                }

                // Action Row
                MinimalActionButtonRow(
                    onNavigate: onNavigate,
                    onMarkAsParked: onMarkAsParked,
                    parkSaveState: parkSaveState
                )

                // Recommendation or Walk info
                if let recommendation {
                    CompactMetricRow(
                        walkMinutes: max(1, Int(round(recommendation.route.walkTimeSec / 60))),
                        driveMinutes: max(1, Int(round(recommendation.route.travelTimeSec / 60))),
                        trafficScore: recommendation.score.breakdown.congestion,
                        customLabel: recommendation.matchQualityShortLabel
                    )
                } else if let walk = area.estimatedWalkMinutesFromDestination {
                    CompactMetricRow(
                        walkMinutes: walk,
                        driveMinutes: nil,
                        trafficScore: nil,
                        customLabel: nil
                    )
                }

                // Facts
                factsCard

                if !area.openHoursText.isEmpty {
                    hoursCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
    }

    private var factsCard: some View {
        VStack(spacing: 8) {
            if !area.fullAddress.isEmpty {
                MinimalStatusCard(
                    title: "Address",
                    systemImage: "mappin",
                    tint: .primary,
                    detail: area.fullAddress
                )
            }
            if let phone = area.phone, !phone.isEmpty {
                MinimalStatusCard(
                    title: "Phone",
                    systemImage: "phone.fill",
                    tint: .primary,
                    detail: phone
                )
            }
            if let website = area.website, !website.isEmpty {
                MinimalStatusCard(
                    title: "Website",
                    systemImage: "globe",
                    tint: .primary,
                    detail: website
                )
            }
        }
    }

    private var hoursCard: some View {
        VStack(spacing: 8) {
            MinimalStatusCard(
                title: "Hours",
                systemImage: "clock",
                tint: .primary,
                detail: area.openHoursText.joined(separator: "\n")
            )
        }
    }

    private var kindLabel: String {
        switch area.kind {
        case .garage: return "Garage"
        case .lot: return "Lot"
        case .street: return "Street"
        case .general: return "Parking"
        }
    }

    private var kindTint: Color {
        switch area.kind {
        case .garage:
            return CurbyGlass.primaryTint
        case .lot:
            return CurbyGlass.warningTint
        case .street:
            return CurbyGlass.successTint
        case .general:
            return CurbyGlass.destinationTint
        }
    }
}
