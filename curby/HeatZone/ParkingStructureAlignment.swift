//
//  ParkingStructureAlignment.swift
//  curby
//
//  Aligns garage and lot surfaces to real building footprints from Mapbox Streets.
//

import CoreLocation
import MapboxMaps

struct ParkingBuildingFeature {
    let boundary: [CLLocationCoordinate2D]
    let anchor: CLLocationCoordinate2D
    let area: Double
}

enum ParkingStructureAlignment {

    static func buildingFeatures(from queriedFeatures: [QueriedSourceFeature]) -> [ParkingBuildingFeature] {
        queriedFeatures.flatMap { queriedFeature in
            let feature = queriedFeature.queriedFeature.feature
            let properties = feature.properties

            guard isUsableBuilding(properties) else {
                return [ParkingBuildingFeature]()
            }

            switch feature.geometry {
            case .polygon(let polygon):
                return buildingFeature(from: polygon).map { [$0] } ?? []
            case .multiPolygon(let multiPolygon):
                return multiPolygon.coordinates.compactMap { coordinates in
                    buildingFeature(from: Polygon(coordinates))
                }
            default:
                return [ParkingBuildingFeature]()
            }
        }
    }

    static func alignedBoundary(
        for spot: ParkingSpot,
        using buildings: [ParkingBuildingFeature]
    ) -> [CLLocationCoordinate2D]? {
        bestMatch(for: spot, in: buildings)?.boundary
    }

    private static func buildingFeature(from polygon: Polygon) -> ParkingBuildingFeature? {
        let boundary = cleanedBoundary(from: polygon.outerRing.coordinates)
        guard boundary.count >= 4 else {
            return nil
        }

        let normalizedPolygon = Polygon([boundary])
        let area = normalizedPolygon.area

        guard
            area >= 70.0,
            area <= 50_000.0,
            let anchor = normalizedPolygon.centerOfMass
                ?? normalizedPolygon.centroid
                ?? normalizedPolygon.center
        else {
            return nil
        }

        return ParkingBuildingFeature(
            boundary: boundary,
            anchor: anchor,
            area: area
        )
    }

    private static func bestMatch(
        for spot: ParkingSpot,
        in buildings: [ParkingBuildingFeature]
    ) -> ParkingBuildingFeature? {
        var bestBuilding: ParkingBuildingFeature?
        var bestScore = Double.greatestFiniteMagnitude

        for building in buildings {
            let distance = building.anchor.distance(to: spot.coordinate)
            guard distance <= CurbyConstants.parkingStructureSnapDistanceMeters else {
                continue
            }

            let score = distance + areaPenalty(for: building.area, spotType: spot.type)
            if score < bestScore {
                bestScore = score
                bestBuilding = building
            }
        }

        return bestBuilding
    }

    private static func areaPenalty(for area: Double, spotType: ParkingType) -> Double {
        switch spotType {
        case .garage:
            switch area {
            case ..<140:
                return 24
            case 140...12_000:
                return 0
            default:
                return min(36, (area - 12_000) / 900)
            }
        case .lot:
            switch area {
            case ..<90:
                return 18
            case 90...25_000:
                return 0
            default:
                return min(32, (area - 25_000) / 1_200)
            }
        case .streetCurbside, .metered:
            return 0
        }
    }

    private static func cleanedBoundary(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []

        for coordinate in coordinates {
            guard let last = result.last else {
                result.append(coordinate)
                continue
            }

            if last.distance(to: coordinate) > 0.5 {
                result.append(coordinate)
            }
        }

        if
            let first = result.first,
            let last = result.last,
            last.distance(to: first) > 0.5
        {
            result.append(first)
        }

        return result
    }

    private static func isUsableBuilding(_ properties: JSONObject?) -> Bool {
        guard !booleanValue(for: "underground", in: properties) else {
            return false
        }

        // Prefer the full footprint outline over tiny `building:part` slices.
        guard !booleanValue(for: "extrude", in: properties) else {
            return false
        }

        return true
    }

    private static func booleanValue(
        for key: String,
        in properties: JSONObject?
    ) -> Bool {
        if let value = properties?[key]??.boolean {
            return value
        }

        return properties?[key]??.string?.lowercased() == "true"
    }
}
