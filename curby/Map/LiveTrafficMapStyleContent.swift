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
    /// Map zoom below which the traffic overlay is hidden. Lowered to 12
    /// while we verify the layer is actually rendering on Standard v3 —
    /// can be tightened back up once we're happy with how it looks.
    static let minimumZoom: Double = 12.0

    private let sourceID = "curby-live-traffic-source"
    private let lineLayerID = "curby-live-traffic-line-layer"

    // Free-flow ("low") and "unknown" segments are deliberately drawn as
    // clear — painting every road green/gray was visual noise. The base-
    // map style already conveys "normal road" on its own, so we only
    // surface segments that are actually problematic.
    private let moderateColor = UIColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 1.0)   // yellow
    private let heavyColor = UIColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0)      // orange
    private let severeColor = UIColor(red: 0.96, green: 0.34, blue: 0.28, alpha: 1.0)     // red

    var body: some MapStyleContent {
        VectorSource(id: sourceID)
            .url("mapbox://mapbox.mapbox-traffic-v1")

        LineLayer(id: lineLayerID, source: sourceID)
            .sourceLayer("traffic")
            .minZoom(Self.minimumZoom)
            .lineCap(.round)
            .lineJoin(.round)
            // `.top` (not `.middle`) so we render above all base-map road
            // sub-layers in the Standard style. `.middle` was placing the
            // layer between two of Standard's road passes, so the upper
            // road fill was painting over our colored ribbons.
            .slot(.top)
            .lineColor(
                Exp(.match) {
                    Exp(.get) { "congestion" }
                    "moderate"
                    moderateColor
                    "heavy"
                    heavyColor
                    "severe"
                    severeColor
                    UIColor.clear
                }
            )
            .lineOpacity(
                Exp(.interpolate) {
                    Exp(.linear)
                    Exp(.zoom)
                    12.0
                    0.0
                    13.0
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
                    12.0
                    2.0
                    14.0
                    3.5
                    16.0
                    5.0
                    18.0
                    7.0
                    20.0
                    10.0
                }
            )
    }
}
