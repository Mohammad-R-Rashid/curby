//
//  CurbyLiveParkingMapStyleContent.swift
//  curby
//
//  Renders the live backend parking route on the Mapbox map.
//

import CoreLocation
import MapboxMaps
import UIKit

struct CurbyLiveParkingMapStyleContent: MapStyleContent {
    let destinationCoordinate: CLLocationCoordinate2D?
    let walkingGeofenceRadiusMeters: Double?
    let activeRecommendation: CurbyParkingRecommendation?
    let pendingRecommendation: CurbyParkingRecommendation?
    var developerMode: Bool = false

    var body: some MapStyleContent {
        if
            let destinationCoordinate,
            let walkingGeofenceRadiusMeters,
            walkingGeofenceRadiusMeters > 0
        {
            destinationGeofenceLayers(
                center: destinationCoordinate,
                radiusMeters: walkingGeofenceRadiusMeters,
                developerMode: developerMode
            )
        }

        if let activeRecommendation {
            routeLayers(
                for: activeRecommendation,
                sourceID: "curby-live-route-source",
                casingLayerID: "curby-live-route-casing-layer",
                lineLayerID: "curby-live-route-line-layer",
                isPending: false
            )
        }

        if let pendingRecommendation {
            routeLayers(
                for: pendingRecommendation,
                sourceID: "curby-pending-route-source",
                casingLayerID: "curby-pending-route-casing-layer",
                lineLayerID: "curby-pending-route-line-layer",
                isPending: true
            )
        }
    }

    @MapStyleContentBuilder
    private func destinationGeofenceLayers(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        developerMode: Bool
    ) -> some MapStyleContent {
        let sourceID = "curby-destination-geofence-source"
        let fillLayerID = "curby-destination-geofence-fill-layer"
        let lineLayerID = "curby-destination-geofence-line-layer"

        GeoJSONSource(id: sourceID)
            .data(.feature(Feature(
                geometry: .polygon(
                    HeatZoneGeometry.circlePolygon(center: center, radiusMeters: radiusMeters)
                )
            )))

        // In developer mode the geofence fill reads as a large “box” on the map; keep the ring only.
        if !developerMode {
            FillLayer(id: fillLayerID, source: sourceID)
                .fillColor(StyleColor(UIColor(red: 46 / 255, green: 143 / 255, blue: 1.0, alpha: 1.0)))
                .fillOpacity(0.08)
        }

        destinationGeofenceLineLayer(id: lineLayerID, sourceID: sourceID, developerMode: developerMode)
    }

    @MapStyleContentBuilder
    private func routeLayers(
        for recommendation: CurbyParkingRecommendation,
        sourceID: String,
        casingLayerID: String,
        lineLayerID: String,
        isPending: Bool
    ) -> some MapStyleContent {
        if recommendation.route.coordinates.count >= 2 {
            GeoJSONSource(id: sourceID)
                .data(.feature(routeFeature(for: recommendation)))

            routeCasingLayer(id: casingLayerID, sourceID: sourceID, isPending: isPending)
            routeLineLayer(id: lineLayerID, sourceID: sourceID, isPending: isPending)
        }
    }

    private func routeFeature(for recommendation: CurbyParkingRecommendation) -> Feature {
        Feature(geometry: .lineString(LineString(recommendation.route.coordinates)))
    }

    private func destinationGeofenceLineLayer(id: String, sourceID: String, developerMode: Bool) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(UIColor(red: 46 / 255, green: 143 / 255, blue: 1.0, alpha: 1.0)))
            .lineOpacity(developerMode ? 0.88 : 0.62)
            .lineWidth(developerMode ? 2.8 : 2.0)
            .lineCap(.round)
            .lineJoin(.round)

        layer.lineDasharray = .constant([2.0, 1.5])
        return layer
    }

    private func routeCasingLayer(id: String, sourceID: String, isPending: Bool) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(UIColor.white))
            .lineOpacity(isPending ? 0.72 : 0.92)
            .lineWidth(isPending ? 8.0 : 9.0)
            .lineJoin(.round)
            .lineCap(.round)

        if isPending {
            layer.lineDasharray = .constant([1.0, 1.1])
        }

        return layer
    }

    private func routeLineLayer(id: String, sourceID: String, isPending: Bool) -> LineLayer {
        let primaryColor = UIColor(red: 46 / 255, green: 143 / 255, blue: 1.0, alpha: 1.0)
        let pendingColor = UIColor(red: 1.0, green: 158 / 255, blue: 76 / 255, alpha: 1.0)

        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(isPending ? pendingColor : primaryColor))
            .lineOpacity(isPending ? 0.88 : 1.0)
            .lineWidth(isPending ? 4.0 : 5.0)
            .lineJoin(.round)
            .lineCap(.round)

        if isPending {
            layer.lineDasharray = .constant([1.0, 1.1])
        }

        return layer
    }
}
