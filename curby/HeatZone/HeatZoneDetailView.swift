//
//  HeatZoneDetailView.swift
//  curby
//
//  In-depth view of a specific heat zone — area activity, street parking, garages.
//

import CoreLocation
import PhosphorSwift
import SwiftUI

/// Detail view for a single heat zone.
///
/// Shows how busy the zone is, street parking openness probabilities,
/// and nearby garages/lots with capacity.
struct HeatZoneDetailView: View {

    let zone: HeatZone

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var isDark: Bool { colorScheme == .dark }

    /// Walking circumference filter
    private var maxWalkingDistance: Double {
        OnboardingState.storedWalkingCircumference
    }

    /// Filtered parking spots within walking distance
    private var filteredSpots: [ParkingSpot] {
        zone.parkingSpots.filter { $0.walkingDistance <= maxWalkingDistance }
    }

    private var streetSpots: [ParkingSpot] {
        filteredSpots.filter { $0.type == .streetCurbside || $0.type == .metered }
            .sorted { ($0.opennessProbability ?? 0) > ($1.opennessProbability ?? 0) }
    }

    private var lotSpots: [ParkingSpot] {
        filteredSpots.filter { $0.type == .garage || $0.type == .lot }
            .sorted { $0.walkingDistance < $1.walkingDistance }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Header
                headerCard

                // MARK: - Street Parking
                if !streetSpots.isEmpty {
                    streetParkingSection
                }

                // MARK: - Garages & Lots
                if !lotSpots.isEmpty {
                    garagesSection
                }



                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(
            (isDark ? Color(red: 0.06, green: 0.06, blue: 0.10) : Color(red: 0.95, green: 0.95, blue: 0.97))
                .ignoresSafeArea()
        )
        .navigationTitle(zone.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // Area activity ring
                ZStack {
                    Circle()
                        .strokeBorder(busyColor(zone.busyLevel).opacity(0.3), lineWidth: 4)
                        .frame(width: 72, height: 72)

                    Circle()
                        .trim(from: 0, to: Double(zone.busyScore) / 100)
                        .stroke(
                            busyColor(zone.busyLevel),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 72, height: 72)
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(zone.busyScore)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(isDark ? .white : .primary)

                        Text("activity")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(zone.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isDark ? .white : .primary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(busyColor(zone.busyLevel))
                            .frame(width: 8, height: 8)

                        Text(zone.busyLevel.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(busyColor(zone.busyLevel))
                    }

                    Text("\(filteredSpots.count) parking options within \(String(format: "%.2f", maxWalkingDistance)) mi")
                        .font(.system(size: 12))
                        .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                }

                Spacer()
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    // MARK: - Street Parking Section

    private var streetParkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Street Parking", icon: .roadHorizon)

            VStack(spacing: 8) {
                ForEach(streetSpots) { spot in
                    streetParkingRow(spot: spot)
                }
            }
        }
    }

    private func streetParkingRow(spot: ParkingSpot) -> some View {
        HStack(spacing: 14) {
            // Openness bar
            RoundedRectangle(cornerRadius: 3)
                .fill(busyColor(spot.computedBusyLevel))
                .frame(width: 4, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(spot.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isDark ? .white : .primary)

                    if spot.type == .metered {
                        Text("Metered")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isDark ? .white.opacity(0.5) : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isDark ? .white.opacity(0.1) : .gray.opacity(0.1))
                            )
                    }
                }

                HStack(spacing: 12) {
                    if let openness = spot.computedScore {
                        HStack(spacing: 4) {
                            Text("\(openness)%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(busyColor(spot.computedBusyLevel))
                            Text("likely open")
                                .font(.system(size: 12))
                                .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                        }
                    }

                    HStack(spacing: 3) {
                        Ph.personSimpleWalk.regular
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                        Text(String(format: "%.2f mi", spot.walkingDistance))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                }
            }

            Spacer()

            // Openness probability gauge
            if let score = spot.computedScore {
                ZStack {
                    Circle()
                        .strokeBorder(busyColor(spot.computedBusyLevel).opacity(0.2), lineWidth: 3)
                        .frame(width: 40, height: 40)

                    Circle()
                        .trim(from: 0, to: Double(score) / 100.0)
                        .stroke(busyColor(spot.computedBusyLevel), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))

                    Text("\(score)%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isDark ? .white : .primary)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Garages Section

    private var garagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Garages & Lots", icon: .garage)

            VStack(spacing: 8) {
                ForEach(lotSpots) { spot in
                    garageLotRow(spot: spot)
                }
            }
        }
    }

    private func garageLotRow(spot: ParkingSpot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        spot.type == .garage
                            ? Color(red: 0.30, green: 0.50, blue: 0.85).opacity(0.15)
                            : Color(red: 0.55, green: 0.75, blue: 0.40).opacity(0.15)
                    )
                    .frame(width: 44, height: 44)

                spot.type.icon.regular
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(
                        spot.type == .garage
                            ? Color(red: 0.30, green: 0.50, blue: 0.85)
                            : Color(red: 0.55, green: 0.75, blue: 0.40)
                    )
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(spot.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isDark ? .white : .primary)

                HStack(spacing: 12) {
                    if let openness = spot.computedScore {
                        HStack(spacing: 4) {
                            Text("\(openness)%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(busyColor(spot.computedBusyLevel))
                            Text("likely open")
                                .font(.system(size: 12))
                                .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                        }
                    }

                    HStack(spacing: 3) {
                        Ph.personSimpleWalk.regular
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                        Text(String(format: "%.2f mi", spot.walkingDistance))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                }
            }

            Spacer()

            // Openness gauge
            if let score = spot.computedScore {
                ZStack {
                    Circle()
                        .strokeBorder(busyColor(spot.computedBusyLevel).opacity(0.2), lineWidth: 3)
                        .frame(width: 40, height: 40)

                    Circle()
                        .trim(from: 0, to: Double(score) / 100.0)
                        .stroke(busyColor(spot.computedBusyLevel), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))

                    Text("\(score)%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isDark ? .white : .primary)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }



    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isDark ? .white.opacity(0.05) : .white)
            .shadow(color: .black.opacity(isDark ? 0 : 0.05), radius: 6, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isDark ? .white.opacity(0.06) : .clear, lineWidth: 0.5)
            )
    }

    private func sectionHeader(title: String, icon: Ph) -> some View {
        HStack(spacing: 6) {
            icon.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                .frame(width: 13, height: 13)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDark ? .white.opacity(0.4) : .secondary)
                .textCase(.uppercase)
                .tracking(1.0)
        }
    }

    private func busyColor(_ level: BusyLevel) -> Color {
        HeatZoneGeometry.color(for: level)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HeatZoneDetailView(
            zone: HeatZone(
                id: UUID(),
                name: "West Campus — Core",
                coordinate: .init(latitude: 30.2849, longitude: -97.7514),
                radius: 200,
                busyScore: 52,
                parkingSpots: [
                    ParkingSpot(
                        id: UUID(),
                        coordinate: .init(latitude: 30.285, longitude: -97.751),
                        type: .streetCurbside,
                        walkingDistance: 0.12,
                        roadName: "Guadalupe St",
                        opennessProbability: 0.72,
                        segmentLength: 300,
                        lotName: nil,
                        spotsAvailable: nil,
                        totalSpots: nil
                    ),
                    ParkingSpot(
                        id: UUID(),
                        coordinate: .init(latitude: 30.284, longitude: -97.752),
                        type: .garage,
                        walkingDistance: 0.18,
                        roadName: nil,
                        opennessProbability: nil,
                        segmentLength: nil,
                        lotName: "Capitol Parking Garage",
                        spotsAvailable: 45,
                        totalSpots: 200
                    )
                ],
                boundaryCoords: []
            )
        )
    }
}
