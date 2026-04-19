//
//  DeveloperDebugMapStyleContent.swift
//  curby
//
//  Extra map layers for Developer Mode: candidate fan lines, session radii, accuracy.
//

import CoreLocation
import MapboxMaps
import UIKit

/// Mapbox layers drawn only in Developer Mode — spatial context for routing and load decisions.
struct DeveloperDebugMapStyleContent: MapStyleContent {
    let userLocation: CLLocation?
    let destinationCoordinate: CLLocationCoordinate2D?
    let parkingAreas: [LiveParkingArea]
    let activeRecommendation: CurbyParkingRecommendation?
    let socketOriginCoordinate: CLLocationCoordinate2D?

    private static let wsRefreshRadiusMeters: Double = 45
    private static let autoArrivalRadiusMeters: Double = 120

    var body: some MapStyleContent {
        fanLinesFromDestination
        baseToNavigationLines
        userVectorLines
        parkingPOICentroidDots
        debugCircles
    }

    // MARK: - Fan lines (destination → each POI)

    @MapStyleContentBuilder
    private var fanLinesFromDestination: some MapStyleContent {
        let features = fanLineFeatures
        if !features.isEmpty {
            let sourceID = "curby-dev-fan-lines"
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(FeatureCollection(features: features)))

            dashedLineLayer(
                id: "curby-dev-fan-lines-layer",
                sourceID: sourceID,
                color: UIColor.white.withAlphaComponent(0.55),
                opacity: 0.4,
                width: 1.25,
                dash: [1.2, 1.8]
            )
        }
    }

    private func dashedLineLayer(
        id: String,
        sourceID: String,
        color: UIColor,
        opacity: Double,
        width: Double,
        dash: [Double]
    ) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(color))
            .lineOpacity(opacity)
            .lineWidth(width)
            .lineCap(.round)
            .lineJoin(.round)
        layer.lineDasharray = .constant(dash)
        return layer
    }

    private var fanLineFeatures: [Feature] {
        guard let destinationCoordinate else { return [] }
        return parkingAreas.map { area in
            Feature(geometry: .lineString(LineString([destinationCoordinate, area.coordinate])))
        }
    }

    // MARK: - POI centroid → routable nav point

    @MapStyleContentBuilder
    private var baseToNavigationLines: some MapStyleContent {
        let features = navOffsetFeatures
        if !features.isEmpty {
            let sourceID = "curby-dev-nav-offset-lines"
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(FeatureCollection(features: features)))

            LineLayer(id: "curby-dev-nav-offset-lines-layer", source: sourceID)
                .lineColor(StyleColor(UIColor.systemPink.withAlphaComponent(0.95)))
                .lineOpacity(0.75)
                .lineWidth(2.0)
                .lineCap(.round)
        }
    }

    private var navOffsetFeatures: [Feature] {
        parkingAreas.compactMap { area -> Feature? in
            let base = CLLocation(latitude: area.coordinate.latitude, longitude: area.coordinate.longitude)
            let nav = CLLocation(latitude: area.navigationCoordinate.latitude, longitude: area.navigationCoordinate.longitude)
            guard base.distance(from: nav) >= 12 else { return nil }
            return Feature(geometry: .lineString(LineString([area.coordinate, area.navigationCoordinate])))
        }
    }

    // MARK: - POI centroids (every candidate `parkingAreas` entry)

    @MapStyleContentBuilder
    private var parkingPOICentroidDots: some MapStyleContent {
        let features = parkingAreas.map { area in
            Feature(geometry: .point(Point(area.coordinate)))
        }
        if !features.isEmpty {
            let sourceID = "curby-dev-parking-poi-dots"
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(FeatureCollection(features: features)))

            CircleLayer(id: "curby-dev-parking-poi-dots-layer", source: sourceID)
                .circleRadius(5)
                .circleColor(UIColor.systemYellow)
                .circleOpacity(0.92)
                .circleStrokeColor(UIColor.black)
                .circleStrokeWidth(1.25)
                .circleStrokeOpacity(0.85)
        }
    }

    // MARK: - User → destination / active pick

    @MapStyleContentBuilder
    private var userVectorLines: some MapStyleContent {
        if let user = userLocation?.coordinate, let destinationCoordinate {
            let sourceID = "curby-dev-user-dest"
            GeoJSONSource(id: sourceID)
                .data(.feature(Feature(geometry: .lineString(LineString([user, destinationCoordinate])))))

            LineLayer(id: "curby-dev-user-dest-layer", source: sourceID)
                .lineColor(StyleColor(UIColor.cyan))
                .lineOpacity(0.72)
                .lineWidth(2.5)
                .lineCap(.round)
        }

        if let user = userLocation?.coordinate, let activeRecommendation {
            let destCoord = activeRecommendation.area.coordinate
            let sourceID = "curby-dev-user-active"
            GeoJSONSource(id: sourceID)
                .data(.feature(Feature(geometry: .lineString(LineString([user, destCoord])))))

            LineLayer(id: "curby-dev-user-active-layer", source: sourceID)
                .lineColor(StyleColor(UIColor.systemYellow))
                .lineOpacity(0.78)
                .lineWidth(3.0)
                .lineCap(.round)
        }
    }

    // MARK: - Circles (accuracy, WS refresh ring, auto-arrival)

    @MapStyleContentBuilder
    private var debugCircles: some MapStyleContent {
        accuracyCircle
        wsRefreshCircle
        arrivalAroundActiveRecommendation
        arrivalAroundDestination
    }

    @MapStyleContentBuilder
    private var accuracyCircle: some MapStyleContent {
        if let user = userLocation,
           user.horizontalAccuracy > 0,
           user.horizontalAccuracy < 250
        {
        let sourceID = "curby-dev-accuracy-circle"
        let fillID = "curby-dev-accuracy-fill"
        let lineID = "curby-dev-accuracy-line"

        GeoJSONSource(id: sourceID)
            .data(.feature(Feature(
                geometry: .polygon(
                    HeatZoneGeometry.circlePolygon(
                        center: user.coordinate,
                        radiusMeters: user.horizontalAccuracy
                    )
                )
            )))

        FillLayer(id: fillID, source: sourceID)
            .fillColor(StyleColor(UIColor.systemOrange))
            .fillOpacity(0.14)

        dashedLineLayer(
            id: lineID,
            sourceID: sourceID,
            color: UIColor.systemOrange,
            opacity: 0.55,
            width: 1.5,
            dash: [3, 2]
        )
        }
    }

    @MapStyleContentBuilder
    private var wsRefreshCircle: some MapStyleContent {
        if let socketOriginCoordinate {
        let sourceID = "curby-dev-ws-refresh-circle"
        let fillID = "curby-dev-ws-refresh-fill"
        let lineID = "curby-dev-ws-refresh-line"

        GeoJSONSource(id: sourceID)
            .data(.feature(Feature(
                geometry: .polygon(
                    HeatZoneGeometry.circlePolygon(
                        center: socketOriginCoordinate,
                        radiusMeters: Self.wsRefreshRadiusMeters
                    )
                )
            )))

        FillLayer(id: fillID, source: sourceID)
            .fillColor(StyleColor(UIColor.systemPurple))
            .fillOpacity(0.10)

        dashedLineLayer(
            id: lineID,
            sourceID: sourceID,
            color: UIColor.systemPurple,
            opacity: 0.65,
            width: 1.8,
            dash: [2, 2.5]
        )
        }
    }

    @MapStyleContentBuilder
    private var arrivalAroundActiveRecommendation: some MapStyleContent {
        if let activeRecommendation {
        let center = activeRecommendation.area.coordinate
        let sourceID = "curby-dev-arrival-active-circle"
        let fillID = "curby-dev-arrival-active-fill"
        let lineID = "curby-dev-arrival-active-line"

        GeoJSONSource(id: sourceID)
            .data(.feature(Feature(
                geometry: .polygon(
                    HeatZoneGeometry.circlePolygon(center: center, radiusMeters: Self.autoArrivalRadiusMeters)
                )
            )))

        FillLayer(id: fillID, source: sourceID)
            .fillColor(StyleColor(UIColor.systemGreen))
            .fillOpacity(0.07)

        LineLayer(id: lineID, source: sourceID)
            .lineColor(StyleColor(UIColor.systemGreen))
            .lineOpacity(0.5)
            .lineWidth(1.5)
        }
    }

    @MapStyleContentBuilder
    private var arrivalAroundDestination: some MapStyleContent {
        if let destinationCoordinate {
        let sourceID = "curby-dev-arrival-dest-circle"
        let fillID = "curby-dev-arrival-dest-fill"
        let lineID = "curby-dev-arrival-dest-line"

        GeoJSONSource(id: sourceID)
            .data(.feature(Feature(
                geometry: .polygon(
                    HeatZoneGeometry.circlePolygon(
                        center: destinationCoordinate,
                        radiusMeters: Self.autoArrivalRadiusMeters
                    )
                )
            )))

        FillLayer(id: fillID, source: sourceID)
            .fillColor(StyleColor(UIColor.systemTeal))
            .fillOpacity(0.07)

        dashedLineLayer(
            id: lineID,
            sourceID: sourceID,
            color: UIColor.systemTeal,
            opacity: 0.48,
            width: 1.5,
            dash: [4, 3]
        )
        }
    }
}
