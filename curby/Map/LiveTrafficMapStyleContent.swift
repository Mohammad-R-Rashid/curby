//
//  LiveTrafficMapStyleContent.swift
//  curby
//
//  Live traffic overlay drawn directly on top of road geometry. Uses
//  Mapbox's `mapbox.mapbox-traffic-v1` vector source — every road segment
//  is tagged with a `congestion` level (low / moderate / heavy / severe)
//  refreshed by Mapbox. We just paint those segments in a four-color ramp
//  so users can scan a neighborhood at a glance and see "this whole area
//  is jammed right now" without poking individual pins.
//
//  Hidden below `Self.minimumZoom` because at city zoom the colored
//  ribbons overdraw labels and turn the map into a smear.
//

import MapboxMaps
import UIKit

struct LiveTrafficMapStyleContent: MapStyleContent {
    /// Map zoom below which the traffic overlay is hidden. Tuned so the
    /// layer kicks in around neighborhood zoom — at city zoom every road
    /// gets a colored stripe and labels become unreadable.
    static let minimumZoom: Double = 13.5

    private let sourceID = "curby-live-traffic-source"
    private let lineLayerID = "curby-live-traffic-line-layer"

    private let lowColor = UIColor(red: 0.42, green: 0.82, blue: 0.45, alpha: 1.0)      // green
    private let moderateColor = UIColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 1.0)  // yellow
    private let heavyColor = UIColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0)     // orange
    private let severeColor = UIColor(red: 0.96, green: 0.34, blue: 0.28, alpha: 1.0)    // red

    var body: some MapStyleContent {
        VectorSource(id: sourceID)
            .url("mapbox://mapbox.mapbox-traffic-v1")

        LineLayer(id: lineLayerID, source: sourceID)
            .sourceLayer("traffic")
            .minZoom(Self.minimumZoom)
            .lineCap(.round)
            .lineJoin(.round)
            .slot(.middle)
            .lineColor(
                Exp(.match) {
                    Exp(.get) { "congestion" }
                    "low"
                    StyleColor(lowColor)
                    "moderate"
                    StyleColor(moderateColor)
                    "heavy"
                    StyleColor(heavyColor)
                    "severe"
                    StyleColor(severeColor)
                    StyleColor(UIColor.clear)
                }
            )
            // Fade the layer in as the user zooms past the threshold so it
            // doesn't pop into existence; fully on by zoom 14.
            .lineOpacity(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    13.5
                    0.0
                    14.0
                    0.85
                    18.0
                    0.9
                }
            )
            // Width grows with zoom — at neighborhood scale a thin trace,
            // at street level a fat enough ribbon to be read at a glance.
            .lineWidth(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    13.5
                    1.5
                    16.0
                    3.0
                    18.0
                    5.0
                    20.0
                    8.0
                }
            )
    }
}
