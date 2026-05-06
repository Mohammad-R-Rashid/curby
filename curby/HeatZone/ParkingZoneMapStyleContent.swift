//
//  ParkingZoneMapStyleContent.swift
//  curby
//
//  Zoom-aware style-layer rendering for parking zone geometry.
//

import MapboxMaps
import SwiftUI

enum ParkingZoneLayerIDs {
    static let overviewHitLayer = "parking-overview-hit-layer"
    static let streetHitLayer = "parking-street-hit-layer"
    static let garageHitLayer = "parking-garage-hit-layer"
    static let lotHitLayer = "parking-lot-hit-layer"
}

/// Renders parking zones using GeoJSON sources and style layers so backend GeoJSON
/// can later be swapped in without changing the view hierarchy.
struct ParkingZoneMapStyleContent: MapStyleContent {
    let zones: [HeatZone]
    let selectedZoneID: UUID?
    let zoom: Double

    var body: some MapStyleContent {
        let visibleSurfaces = zones.flatMap { $0.visibleSurfaces(at: zoom) }

        let overviewSurfaces = visibleSurfaces.filter { $0.kind == .overviewArea }
        let streetSurfaces = visibleSurfaces.filter { $0.kind == .curbSegment }
        let garageSurfaces = visibleSurfaces.filter { $0.kind == .garageFootprint }
        let lotSurfaces = visibleSurfaces.filter { $0.kind == .lotFootprint }

        // The road/building "loader layers" exist only so we can later query
        // the global mapbox-streets-v8 source for alignment. Loading that
        // source is extremely expensive (it's every road and building on
        // Earth), so only attach it when we actually have surfaces that need
        // alignment. Currently zones generate overview surfaces only; the
        // source stays unloaded until real street/structure geometry returns.
        let needsRoadSource = !streetSurfaces.isEmpty
        let needsBuildingSource = !garageSurfaces.isEmpty || !lotSurfaces.isEmpty

        if needsRoadSource || needsBuildingSource {
            VectorSource(id: ParkingRoadNetworkIDs.source)
                .url("mapbox://mapbox.mapbox-streets-v8")
        }
        if needsRoadSource {
            roadLoaderLayer
        }
        if needsBuildingSource {
            buildingLoaderLayer
        }

        if !overviewSurfaces.isEmpty {
            surfaceGroup(
                idPrefix: "parking-overview",
                surfaces: overviewSurfaces,
                style: .overview,
                interactionLayerID: ParkingZoneLayerIDs.overviewHitLayer
            )
        }

        if !streetSurfaces.isEmpty {
            surfaceGroup(
                idPrefix: "parking-street",
                surfaces: streetSurfaces,
                style: .street,
                interactionLayerID: ParkingZoneLayerIDs.streetHitLayer,
                isLine: true
            )
        }

        if !garageSurfaces.isEmpty {
            surfaceGroup(
                idPrefix: "parking-garage",
                surfaces: garageSurfaces,
                style: .garage,
                interactionLayerID: ParkingZoneLayerIDs.garageHitLayer
            )
        }

        if !lotSurfaces.isEmpty {
            surfaceGroup(
                idPrefix: "parking-lot",
                surfaces: lotSurfaces,
                style: .lot,
                interactionLayerID: ParkingZoneLayerIDs.lotHitLayer
            )
        }
    }

    private var roadLoaderLayer: LineLayer {
        LineLayer(id: ParkingRoadNetworkIDs.roadLoaderLayer, source: ParkingRoadNetworkIDs.source)
            .sourceLayer(ParkingRoadNetworkIDs.roadSourceLayer)
            .lineColor(StyleColor(.white))
            .lineOpacity(0.001)
            .lineWidth(0.5)
            .lineCap(.round)
            .lineJoin(.round)
            .slot(.bottom)
    }

    private var buildingLoaderLayer: FillLayer {
        FillLayer(id: ParkingRoadNetworkIDs.buildingLoaderLayer, source: ParkingRoadNetworkIDs.source)
            .sourceLayer(ParkingRoadNetworkIDs.buildingSourceLayer)
            .fillColor(StyleColor(.white))
            .fillOpacity(0.0)
            .slot(.bottom)
    }

    @MapStyleContentBuilder
    private func surfaceGroup(
        idPrefix: String,
        surfaces: [ParkingSurface],
        style: ParkingSurfaceVisualStyle,
        interactionLayerID: String,
        isLine: Bool = false
    ) -> some MapStyleContent {
        let sourceID = "\(idPrefix)-source"
        let selectedSourceID = "\(idPrefix)-selected-source"
        let selectedSurfaces = surfaces.filter { $0.zoneID == selectedZoneID }
        let openSurfaces = surfaces.filter { $0.busyLevel == .open }
        let busySurfaces = surfaces.filter { $0.busyLevel == .busy }
        let veryBusySurfaces = surfaces.filter { $0.busyLevel == .veryBusy }

        GeoJSONSource(id: sourceID)
            .data(.featureCollection(HeatZoneGeometry.featureCollection(for: surfaces)))

        if isLine {
            lineSourceAndLayer(
                sourceID: "\(idPrefix)-open-source",
                layerID: "\(idPrefix)-line-open",
                surfaces: openSurfaces,
                color: HeatZoneGeometry.styleColor(for: .open),
                style: style
            )
            lineSourceAndLayer(
                sourceID: "\(idPrefix)-busy-source",
                layerID: "\(idPrefix)-line-busy",
                surfaces: busySurfaces,
                color: HeatZoneGeometry.styleColor(for: .busy),
                style: style
            )
            lineSourceAndLayer(
                sourceID: "\(idPrefix)-veryBusy-source",
                layerID: "\(idPrefix)-line-veryBusy",
                surfaces: veryBusySurfaces,
                color: HeatZoneGeometry.styleColor(for: .veryBusy),
                style: style
            )

            LineLayer(id: interactionLayerID, source: sourceID)
                .lineColor(StyleColor(.white))
                .lineOpacity(0.01)
                .lineWidth(style.strokeWidth + 10.0) // Wide interaction area
                .lineCap(.round)
                .lineJoin(.round)
                .slot(style.slot ?? .middle)
        } else {
            fillSourceAndLayer(
                sourceID: "\(idPrefix)-open-source",
                layerID: "\(idPrefix)-fill-open",
                surfaces: openSurfaces,
                color: HeatZoneGeometry.styleColor(for: .open),
                style: style
            )

            fillSourceAndLayer(
                sourceID: "\(idPrefix)-busy-source",
                layerID: "\(idPrefix)-fill-busy",
                surfaces: busySurfaces,
                color: HeatZoneGeometry.styleColor(for: .busy),
                style: style
            )

            fillSourceAndLayer(
                sourceID: "\(idPrefix)-veryBusy-source",
                layerID: "\(idPrefix)-fill-veryBusy",
                surfaces: veryBusySurfaces,
                color: HeatZoneGeometry.styleColor(for: .veryBusy),
                style: style
            )

            strokeLayer(
                id: "\(idPrefix)-stroke",
                sourceID: sourceID,
                style: style
            )

            interactionLayer(
                id: interactionLayerID,
                sourceID: sourceID,
                style: style
            )
        }

        if !selectedSurfaces.isEmpty {
            GeoJSONSource(id: selectedSourceID)
                .data(.featureCollection(HeatZoneGeometry.featureCollection(for: selectedSurfaces)))

            if isLine {
                LineLayer(id: "\(idPrefix)-selected-stroke", source: selectedSourceID)
                    .lineColor(StyleColor(.white))
                    .lineOpacity(1.0)
                    .lineWidth(style.selectedStrokeWidth)
                    .lineJoin(.round)
                    .lineCap(.round)
                    .slot(style.slot ?? .middle)
            } else {
                selectedFillLayer(
                    id: "\(idPrefix)-selected-fill",
                    sourceID: selectedSourceID,
                    style: style
                )

                selectedStrokeLayer(
                    id: "\(idPrefix)-selected-stroke",
                    sourceID: selectedSourceID,
                    style: style
                )
            }
        }
    }

    @MapStyleContentBuilder
    private func lineSourceAndLayer(
        sourceID: String,
        layerID: String,
        surfaces: [ParkingSurface],
        color: StyleColor,
        style: ParkingSurfaceVisualStyle
    ) -> some MapStyleContent {
        if !surfaces.isEmpty {
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(HeatZoneGeometry.featureCollection(for: surfaces)))

            coloredLineLayer(
                id: layerID,
                sourceID: sourceID,
                color: color,
                style: style
            )
        }
    }

    private func coloredLineLayer(
        id: String,
        sourceID: String,
        color: StyleColor,
        style: ParkingSurfaceVisualStyle
    ) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(color)
            .lineOpacity(style.fillOpacity) // repurposing fillOpacity as line opacity
            .lineWidth(style.strokeWidth)   // repurposing strokeWidth as main line width
            .lineCap(.round)
            .lineJoin(.round)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }

    @MapStyleContentBuilder
    private func fillSourceAndLayer(
        sourceID: String,
        layerID: String,
        surfaces: [ParkingSurface],
        color: StyleColor,
        style: ParkingSurfaceVisualStyle
    ) -> some MapStyleContent {
        if !surfaces.isEmpty {
            GeoJSONSource(id: sourceID)
                .data(.featureCollection(HeatZoneGeometry.featureCollection(for: surfaces)))

            fillLayer(
                id: layerID,
                sourceID: sourceID,
                color: color,
                style: style
            )
        }
    }

    private func fillLayer(
        id: String,
        sourceID: String,
        color: StyleColor,
        style: ParkingSurfaceVisualStyle
    ) -> FillLayer {
        var layer: FillLayer = FillLayer(id: id, source: sourceID)
        layer = layer.fillColor(color)
        layer = layer.fillOpacity(style.fillOpacity)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }

    private func strokeLayer(
        id: String,
        sourceID: String,
        style: ParkingSurfaceVisualStyle
    ) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(.white))
            .lineOpacity(style.strokeOpacity)
            .lineWidth(style.strokeWidth)
            .lineJoin(.round)
            .lineCap(.round)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }

    private func interactionLayer(
        id: String,
        sourceID: String,
        style: ParkingSurfaceVisualStyle
    ) -> FillLayer {
        var layer = FillLayer(id: id, source: sourceID)
            .fillColor(StyleColor(.white))
            .fillOpacity(0.01)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }

    private func selectedFillLayer(
        id: String,
        sourceID: String,
        style: ParkingSurfaceVisualStyle
    ) -> FillLayer {
        var layer = FillLayer(id: id, source: sourceID)
            .fillColor(StyleColor(.white))
            .fillOpacity(style.selectedFillOpacity)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }

    private func selectedStrokeLayer(
        id: String,
        sourceID: String,
        style: ParkingSurfaceVisualStyle
    ) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceID)
            .lineColor(StyleColor(.white))
            .lineOpacity(1.0)
            .lineWidth(style.selectedStrokeWidth)
            .lineJoin(.round)
            .lineCap(.round)

        if let slot = style.slot {
            layer = layer.slot(slot)
        }

        return layer
    }
}

private struct ParkingSurfaceVisualStyle {
    let slot: Slot?
    let fillOpacity: Double
    let strokeOpacity: Double
    let strokeWidth: Double
    let selectedFillOpacity: Double
    let selectedStrokeWidth: Double

    static let overview = ParkingSurfaceVisualStyle(
        slot: .bottom,
        fillOpacity: 0.38,
        strokeOpacity: 0.55,
        strokeWidth: 1.5,
        selectedFillOpacity: 0.50,
        selectedStrokeWidth: 2.5
    )

    static let street = ParkingSurfaceVisualStyle(
        slot: .middle,
        fillOpacity: 0.62,
        strokeOpacity: 0.0,
        strokeWidth: 5.5,
        selectedFillOpacity: 0.78,
        selectedStrokeWidth: 8.5
    )

    static let garage = ParkingSurfaceVisualStyle(
        slot: nil,
        fillOpacity: 0.17,
        strokeOpacity: 1.0,
        strokeWidth: 2.4,
        selectedFillOpacity: 0.28,
        selectedStrokeWidth: 3.2
    )

    static let lot = ParkingSurfaceVisualStyle(
        slot: nil,
        fillOpacity: 0.16,
        strokeOpacity: 1.0,
        strokeWidth: 2.0,
        selectedFillOpacity: 0.26,
        selectedStrokeWidth: 3.0
    )
}
