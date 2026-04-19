import re

# Read SearchView.swift
with open('curby/Search/SearchView.swift', 'r') as f:
    content = f.read()

# Replace body contents
body_target = """                        if parkingSearchManager.activeRecommendation != nil {
                            markAsParkedButton
                        }
                        navigateButton(dest)
                        liveParkingSection

                        if parkingAreaManager.isLoading {
                            areaLoadingIndicator
                        } else if !parkingAreaManager.areas.isEmpty {
                            nearbyParkingSection
                        } else if parkingAreaManager.noParkingInGeofence {
                            noParkingInRadiusSection
                        } else if let error = parkingAreaManager.lastErrorMessage {
                            statusCard(
                                title: "Nearby parking unavailable",
                                detail: error,
                                tint: CurbyGlass.destinationTint
                            )
                        }"""
body_replacement = """                        MinimalActionButtonRow(
                            onNavigate: {
                                openInMaps(coordinate: dest.coordinate, name: dest.name)
                            },
                            onMarkAsParked: parkingSearchManager.activeRecommendation != nil ? { onMarkAsParked?() } : nil,
                            isParked: parkingEventDetector.presenceState == .parked
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                        liveParkingSection

                        if parkingAreaManager.isLoading {
                            areaLoadingIndicator
                        } else if !parkingAreaManager.areas.isEmpty {
                            nearbyParkingSection
                        } else if parkingAreaManager.noParkingInGeofence {
                            noParkingInRadiusSection
                        } else if let error = parkingAreaManager.lastErrorMessage {
                            MinimalStatusCard(
                                title: "Nearby parking unavailable",
                                icon: .warningCircle,
                                tint: CurbyGlass.destinationTint,
                                detail: error
                            )
                        }"""
content = content.replace(body_target, body_replacement)

# Remove markAsParkedButton and navigateButton
buttons_pattern = re.compile(r"    // MARK: - Mark as Parked.*?    // MARK: - Search Results", re.DOTALL)
content = buttons_pattern.sub("    // MARK: - Search Results", content)

no_parking_section = """    private var noParkingInRadiusSection: some View {
        let step = CurbyConstants.parkingSearchRadiusExpandStepMiles
        let canExpand = OnboardingState.canAddWalkingCircumferenceMiles(step)

        return VStack(alignment: .leading, spacing: 12) {
            statusCard(
                title: "No parking",
                detail:
                    "We didn’t find any parking options within \(parkingAreaManager.geofenceDistanceText) of this destination. Try widening your search area.",
                tint: CurbyGlass.destinationTint,
                actionTitle: canExpand ? "Expand search +\(String(format: "%.2f", step)) mi" : nil,
                action: canExpand
                    ? {
                        onExpandWalkingRadius?()
                    }
                    : nil
            )

            if !canExpand {
                Text("You’re already at the maximum walking search distance (\(String(format: "%.1f", CurbyConstants.walkingCircumferenceMax)) mi).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
    }"""
no_parking_replacement = """    private var noParkingInRadiusSection: some View {
        let step = CurbyConstants.parkingSearchRadiusExpandStepMiles
        let canExpand = OnboardingState.canAddWalkingCircumferenceMiles(step)

        return VStack(alignment: .leading, spacing: 12) {
            MinimalStatusCard(
                title: "No nearby parking",
                icon: .warningCircle,
                tint: CurbyGlass.destinationTint,
                actionTitle: canExpand ? "Expand search" : nil,
                action: canExpand ? { onExpandWalkingRadius?() } : nil
            )
        }
    }"""
content = content.replace(no_parking_section, no_parking_replacement)

geofence_section = """    private var geofenceSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Ph.circleDashed.bold
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(CurbyGlass.primaryTint)
                    .frame(width: 16, height: 16)

                Text("Walking geofence")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text(
                "Showing \(parkingAreaManager.areas.count) parking options inside \(parkingAreaManager.geofenceDistanceText) of your destination."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                metricPill(
                    title: "\(parkingAreaManager.streetAreas.count) street",
                    tint: CurbyGlass.successTint
                )
                metricPill(
                    title: "\(parkingAreaManager.structureAreas.count) garages/lots",
                    tint: CurbyGlass.primaryTint
                )
            }
        }
        .padding(16)
        .curbyGlassSurface(tint: CurbyGlass.primaryTint, cornerRadius: CurbyGlass.cardCornerRadius)
        .padding(.horizontal, 16)
    }"""
geofence_replacement = """    private var geofenceSummaryCard: some View {
        HStack {
            Ph.circleDashed.fill
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(CurbyGlass.primaryTint)
            Text("\(parkingAreaManager.areas.count) options inside \(parkingAreaManager.geofenceDistanceText)")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }"""
content = content.replace(geofence_section, geofence_replacement)

live_parking_section = """    private var liveParkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Live Parking", icon: .navigationArrow)

            if parkingSearchManager.isSearching {
                statusCard(
                    title: "Finding the best spot",
                    detail: "Curby is checking live parking and routing from your current location.",
                    tint: CurbyGlass.primaryTint
                )
            }

            if case let .noData(message) = parkingSearchManager.status {
                statusCard(
                    title: "No live recommendation yet",
                    detail: message,
                    tint: CurbyGlass.warningTint
                )
            }

            if case let .error(message) = parkingSearchManager.status {
                statusCard(
                    title: "Backend connection issue",
                    detail: message,
                    tint: CurbyGlass.destinationTint,
                    actionTitle: "Retry Search"
                ) {
                    Task { await parkingSearchManager.retryCurrentSearch() }
                }
            }

            if case .arrived = parkingSearchManager.status {
                statusCard(
                    title: "Arrival confirmed",
                    detail: "This parking session has been marked as arrived and synced to the backend.",
                    tint: CurbyGlass.successTint
                )
            }

            if let recommendation = parkingSearchManager.activeRecommendation {
                recommendationCard(recommendation)
            }

            if let pendingUpdate = parkingSearchManager.pendingRouteUpdate {
                routeUpdateCard(pendingUpdate)
            }
        }
    }"""
live_parking_replacement = """    private var liveParkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Live Parking", icon: .navigationArrow)

            if parkingSearchManager.isSearching {
                MinimalStatusCard(
                    title: "Searching...",
                    icon: .spinnerTarget,
                    tint: CurbyGlass.primaryTint
                )
            }

            if case .noData(_) = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "No route available",
                    icon: .warningCircle,
                    tint: CurbyGlass.warningTint
                )
            }

            if case .error(_) = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "Connection issue",
                    icon: .wifiX,
                    tint: CurbyGlass.destinationTint,
                    actionTitle: "Retry"
                ) {
                    Task { await parkingSearchManager.retryCurrentSearch() }
                }
            }
            
            if case .arrived = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "Arrived",
                    icon: .checkCircle,
                    tint: CurbyGlass.successTint
                )
            }

            if let recommendation = parkingSearchManager.activeRecommendation {
                UnifiedRecommendationCard(
                    recommendation: recommendation,
                    isParked: parkingEventDetector.presenceState == .parked,
                    onNavigate: {
                        openInMaps(
                            coordinate: recommendation.area.coordinate,
                            name: recommendation.area.name
                        )
                    },
                    onCancel: {
                        Task { await parkingSearchManager.cancelSearch() }
                    },
                    onRetry: {
                        Task { await parkingSearchManager.retryCurrentSearch() }
                    }
                )
            }

            if let pendingUpdate = parkingSearchManager.pendingRouteUpdate {
                VStack(spacing: 8) {
                    MinimalStatusCard(
                        title: "Better parking found",
                        icon: .sparkle,
                        tint: CurbyGlass.warningTint,
                        actionTitle: "Switch"
                    ) {
                        Task { await parkingSearchManager.acceptPendingUpdate() }
                    }
                }
            }
        }
    }"""
content = content.replace(live_parking_section, live_parking_replacement)

# Remove the multiple helper cards logic at the bottom
pattern = re.compile(r"    private func recommendationCard.*?private func nearbyParkingCard", re.DOTALL)
content = pattern.sub("    private func nearbyParkingCard", content)

# Remove old helper action buttons & metric pills methods
helper_pattern = re.compile(r"    private func metricPill.*?    private func sectionHeader", re.DOTALL)
content = helper_pattern.sub("    private func sectionHeader", content)

with open('curby/Search/SearchView.swift', 'w') as f:
    f.write(content)
