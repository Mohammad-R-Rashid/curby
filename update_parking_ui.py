import re

with open('curby/Parking/ParkingAreaDetailView.swift', 'r') as f:
    content = f.read()

# Replace body
body_target = """        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                if let recommendation {
                    recommendationSummaryCard(recommendation)
                } else if let walk = area.estimatedWalkMinutesFromDestination {
                    walkEstimateCard(minutes: walk)
                }
                factsCard
                if !area.openHoursText.isEmpty {
                    hoursCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }"""
body_replacement = """        ScrollView {
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
                    isParked: false
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
        }"""
content = content.replace(body_target, body_replacement)

# Remove headerCard through chip
to_remove_pattern = re.compile(r"    private var headerCard: some View \{.*?    private var factsCard: some View \{", re.DOTALL)
content = to_remove_pattern.sub("    private var factsCard: some View {", content)

# Replace factsCard and hoursCard and detailRow
facts_and_hours_pattern = re.compile(r"    private var factsCard: some View \{.*?    private func detailRow.*?\}", re.DOTALL)

new_facts_and_hours = """    private var factsCard: some View {
        VStack(spacing: 8) {
            if !area.fullAddress.isEmpty {
                MinimalStatusCard(
                    title: "Address",
                    icon: .mapPin,
                    tint: .primary,
                    detail: area.fullAddress
                )
            }
            if let phone = area.phone, !phone.isEmpty {
                MinimalStatusCard(
                    title: "Phone",
                    icon: .phone,
                    tint: .primary,
                    detail: phone
                )
            }
            if let website = area.website, !website.isEmpty {
                MinimalStatusCard(
                    title: "Website",
                    icon: .globe,
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
                icon: .clock,
                tint: .primary,
                detail: area.openHoursText.joined(separator: "\\n")
            )
        }
    }"""
content = facts_and_hours_pattern.sub(new_facts_and_hours, content)

with open('curby/Parking/ParkingAreaDetailView.swift', 'w') as f:
    f.write(content)
