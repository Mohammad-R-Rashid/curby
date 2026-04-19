//
//  ParkingRoadAlignment.swift
//  curby
//
//  Aligns street-level parking surfaces to real road centerlines from Mapbox Streets.
//

import CoreLocation
import MapboxMaps

enum ParkingRoadNetworkIDs {
    static let source = "parking-road-network-source"
    static let roadLoaderLayer = "parking-road-network-loader-layer"
    static let buildingLoaderLayer = "parking-building-network-loader-layer"
    static let roadSourceLayer = "road"
    static let buildingSourceLayer = "building"
}

struct ParkingRoadFeature {
    let name: String?
    let roadClass: String?
    let centerline: LineString
}

enum ParkingRoadAlignment {

    static func roadFeatures(from queriedFeatures: [QueriedSourceFeature]) -> [ParkingRoadFeature] {
        queriedFeatures.flatMap { queriedFeature in
            let feature = queriedFeature.queriedFeature.feature
            let properties = feature.properties
            let roadClass = stringValue(for: "class", in: properties)
            let structure = stringValue(for: "structure", in: properties)

            guard isStreetCandidateClass(roadClass), isAllowedStructure(structure) else {
                return [ParkingRoadFeature]()
            }

            let name = stringValue(for: "name", in: properties)

            switch feature.geometry {
            case .lineString(let lineString):
                return roadFeatures(from: lineString, name: name, roadClass: roadClass)
            case .multiLineString(let multiLineString):
                return multiLineString.coordinates.flatMap { coordinates in
                    roadFeatures(
                        from: LineString(coordinates),
                        name: name,
                        roadClass: roadClass
                    )
                }
            default:
                return [ParkingRoadFeature]()
            }
        }
    }

    static func alignedBoundaryAndName(
        for spot: ParkingSpot,
        using roads: [ParkingRoadFeature]
    ) -> (coordinates: [CLLocationCoordinate2D], name: String?)? {
        guard let match = bestMatch(for: spot, in: roads) else {
            return nil
        }

        let desiredLengthMeters = segmentLengthMeters(for: spot)

        guard let centerlineSlice = slicedCenterline(
            from: match.road.centerline,
            around: match.closestCoordinate,
            lengthMeters: desiredLengthMeters
        ) else {
            return nil
        }

        return (centerlineSlice.coordinates, match.road.name)
    }

    private static func roadFeatures(
        from lineString: LineString,
        name: String?,
        roadClass: String?
    ) -> [ParkingRoadFeature] {
        guard cleanedCoordinates(from: lineString.coordinates).count >= 2 else {
            return [ParkingRoadFeature]()
        }

        return [
            ParkingRoadFeature(
                name: name,
                roadClass: roadClass,
                centerline: LineString(cleanedCoordinates(from: lineString.coordinates))
            )
        ]
    }

    private static func bestMatch(
        for spot: ParkingSpot,
        in roads: [ParkingRoadFeature]
    ) -> (road: ParkingRoadFeature, closestCoordinate: CLLocationCoordinate2D)? {
        var bestRoad: ParkingRoadFeature?
        var bestClosestCoordinate: CLLocationCoordinate2D?
        var bestScore = Double.greatestFiniteMagnitude

        for road in roads {
            guard let closestCoordinate = road.centerline.closestCoordinate(to: spot.coordinate)?.coordinate else {
                continue
            }

            let snapDistance = closestCoordinate.distance(to: spot.coordinate)
            guard snapDistance <= CurbyConstants.parkingRoadSnapDistanceMeters else {
                continue
            }

            let score = snapDistance
                + classPenalty(for: road.roadClass)
                + namePenalty(spotRoadName: spot.roadName, roadName: road.name)

            if score < bestScore {
                bestScore = score
                bestRoad = road
                bestClosestCoordinate = closestCoordinate
            }
        }

        guard let bestRoad, let bestClosestCoordinate else {
            return nil
        }

        return (bestRoad, bestClosestCoordinate)
    }

    private static func slicedCenterline(
        from lineString: LineString,
        around anchor: CLLocationCoordinate2D,
        lengthMeters: Double
    ) -> LineString? {
        let halfLength = max(12.0, lengthMeters / 2.0)
        let backwardSlice = lineString.trimmed(from: anchor, distance: -halfLength)?.coordinates ?? [anchor]
        let forwardSlice = lineString.trimmed(from: anchor, distance: halfLength)?.coordinates ?? [anchor]

        var coordinates = Array(backwardSlice.reversed())

        if coordinates.isEmpty {
            coordinates = [anchor]
        }

        if let last = coordinates.last, last.distance(to: anchor) > 0.5 {
            coordinates.append(anchor)
        }

        for coordinate in forwardSlice {
            guard let last = coordinates.last else {
                coordinates.append(coordinate)
                continue
            }

            if last.distance(to: coordinate) > 0.5 {
                coordinates.append(coordinate)
            }
        }

        let cleaned = cleanedCoordinates(from: coordinates)
        guard cleaned.count >= 2 else {
            return nil
        }

        return LineString(cleaned)
    }

    private static func cleanedCoordinates(
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

        return result
    }

    private static func segmentLengthMeters(for spot: ParkingSpot) -> Double {
        let segmentLengthFeet = spot.segmentLength ?? 180
        return max(26.0, min(segmentLengthFeet * 0.3048, 95.0))
    }



    private static func classPenalty(for roadClass: String?) -> Double {
        switch roadClass {
        case "street":
            return 0
        case "street_limited":
            return 2
        case "tertiary":
            return 5
        case "tertiary_link":
            return 7
        case "secondary":
            return 9
        case "secondary_link":
            return 11
        case "primary":
            return 14
        case "primary_link":
            return 16
        case "service":
            return 18
        default:
            return 24
        }
    }

    private static func namePenalty(
        spotRoadName: String?,
        roadName: String?
    ) -> Double {
        guard
            let spotRoadName = normalizedRoadName(spotRoadName),
            let roadName = normalizedRoadName(roadName)
        else {
            return 0
        }

        return spotRoadName == roadName ? -8.0 : 0
    }

    private static func normalizedRoadName(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isStreetCandidateClass(_ roadClass: String?) -> Bool {
        switch roadClass {
        case "street", "street_limited", "tertiary", "tertiary_link",
             "secondary", "secondary_link", "primary", "primary_link":
            return true
        default:
            return false
        }
    }

    private static func isAllowedStructure(_ structure: String?) -> Bool {
        switch structure {
        case nil, "none":
            return true
        default:
            return false
        }
    }

    private static func stringValue(
        for key: String,
        in properties: JSONObject?
    ) -> String? {
        properties?[key]??.string
    }
}
