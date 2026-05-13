//
//  ParkingHeatMapMapStyleContent.swift
//  curby
//
//  Draws the parking-difficulty heat tiles (Easy / Medium / Hard polygons)
//  on the Mapbox map. The tiles arrive as GeoJSON polygons from the backend
//  /v1/parking-heat-map endpoint; here we convert each one into a Mapbox
//  `Feature`, attach a `label` property, and let a single match-expression
//  fill layer color the lot of them.
//
//  Sits in the `.bottom` slot so the base map's roads and labels still
//  draw on top — important so the live-traffic line overlay remains
//  legible on top of the heat tint.
//

import CoreLocation
import MapboxMaps
import UIKit

struct ParkingHeatMapMapStyleContent: MapStyleContent {
    let tiles: [CurbyHeatMapTile]

    /// Map zoom below which the heat tiles are hidden — at city zoom the
    /// fills overlap and turn the whole map into one big color blob.
    static let minimumZoom: Double = 11.0

    private let sourceID = "curby-parking-heat-map-source"
    private let fillLayerID = "curby-parking-heat-map-fill-layer"
    private let lineLayerID = "curby-parking-heat-map-line-layer"

    // Match the CurbyGlass / iOS palette exactly so the on-map fill
    // reads the same as the in-sheet labels and the match-score gradient.
    private let easyColor = UIColor(red: 0.42, green: 0.82, blue: 0.45, alpha: 1.0)
    private let mediumColor = UIColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0)
    private let hardColor = UIColor(red: 0.96, green: 0.34, blue: 0.28, alpha: 1.0)

    var body: some MapStyleContent {
        if !tiles.isEmpty {
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(makeFeatureCollection()))

            FillLayer(id: fillLayerID, source: sourceID)
                .minZoom(Self.minimumZoom)
                // Mapbox Standard v3 applies lighting to custom layers
                // in the lower slots — that was the reason the heat map
                // was rendering invisibly. `.middle` keeps us above the
                // road network so the user actually sees the fill, and
                // `fillEmissiveStrength(1.0)` opts the layer out of the
                // light-preset shader so our colors don't get darkened.
                .slot(.middle)
                .fillColor(
                    Exp(.match) {
                        Exp(.get) { "label" }
                        "easy"
                        easyColor
                        "medium"
                        mediumColor
                        "hard"
                        hardColor
                        UIColor.gray
                    }
                )
                .fillEmissiveStrength(1.0)
                // Translucent enough that the streets / labels remain
                // readable through the colored fill, but with a real
                // floor so the heat map is unambiguously visible.
                .fillOpacity(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.zoom)
                        10.5
                        0.0
                        11.5
                        0.45
                        16.0
                        0.45
                        19.0
                        0.38
                    }
                )

            LineLayer(id: lineLayerID, source: sourceID)
                .minZoom(Self.minimumZoom)
                .slot(.middle)
                .lineColor(
                    Exp(.match) {
                        Exp(.get) { "label" }
                        "easy"
                        easyColor
                        "medium"
                        mediumColor
                        "hard"
                        hardColor
                        UIColor.gray
                    }
                )
                .lineEmissiveStrength(1.0)
                .lineWidth(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.zoom)
                        11.0
                        1.5
                        14.0
                        2.5
                        18.0
                        4.0
                    }
                )
                .lineOpacity(0.9)
                .lineCap(.round)
                .lineJoin(.round)
        }
    }

    // MARK: - Feature building

    private func makeFeatureCollection() -> FeatureCollection {
        let features = tiles.flatMap { tile -> [Feature] in
            tile.geometry.polygons.compactMap { rings -> Feature? in
                guard !rings.isEmpty, !rings[0].isEmpty else { return nil }
                var feature = Feature(geometry: .polygon(Polygon(rings)))
                feature.properties = [
                    "id": .string(tile.id),
                    "label": .string(tile.label.rawValue),
                    "score": .number(tile.score),
                    "tint": .string(tile.tint),
                ]
                return feature
            }
        }
        return FeatureCollection(features: features)
    }
}
