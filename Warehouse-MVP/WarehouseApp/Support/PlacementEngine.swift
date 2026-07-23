import Foundation

enum PlacementEngine {
    /// Buffer for LiDAR noise, packaging bulge, and worker handling clearance.
    static let fitClearanceCM = 2.0

    struct Weights {
        let space: Double
        let distance: Double
        let affinity: Double
        let capacity: Double

        static func forScale(_ scale: WarehouseScale) -> Weights {
            switch scale {
            case .small:
                return Weights(space: 0.30, distance: 0.35, affinity: 0.15, capacity: 0.20)
            case .growing:
                return Weights(space: 0.30, distance: 0.25, affinity: 0.25, capacity: 0.20)
            case .enterprise:
                return Weights(space: 0.25, distance: 0.15, affinity: 0.40, capacity: 0.20)
            }
        }
    }

    static func recommend(
        package: PackagePlacementProfile,
        locations: [StorageLocation],
        scale: WarehouseScale
    ) -> [PlacementRecommendation] {
        let weights = Weights.forScale(scale)
        let maxDistance = max(locations.map(\.walkingDistanceM).max() ?? 1, 1)

        return locations.compactMap { location in
            guard package.weightKG <= location.remainingWeightKG,
                  let orientation = bestOrientation(for: package.dimensions, in: location)
            else { return nil }

            let spaceEfficiency = min(package.dimensions.volumeCM3 / max(location.freeVolumeCM3, 1), 1)
            let distanceScore = max(0, 1 - location.walkingDistanceM / maxDistance)
            let affinityScore = min(max(location.orderAffinity, 0), 1)
            let capacityScore = min(package.weightKG / max(location.remainingWeightKG, 1), 1)
            let velocityBoost = 0.75 + min(max(package.demandVelocity, 0), 1) * 0.25

            let score = (
                weights.space * spaceEfficiency
                    + weights.distance * distanceScore * velocityBoost
                    + weights.affinity * affinityScore
                    + weights.capacity * capacityScore
            )

            return PlacementRecommendation(
                location: location,
                orientation: orientation,
                score: score,
                spaceEfficiency: spaceEfficiency,
                distanceScore: distanceScore,
                affinityScore: affinityScore,
                capacityScore: capacityScore
            )
        }
        .sorted {
            if $0.score == $1.score { return $0.location.label < $1.location.label }
            return $0.score > $1.score
        }
    }

    private static func bestOrientation(
        for package: PackageDimensions,
        in location: StorageLocation
    ) -> PackageDimensions? {
        package.orientations
            .filter {
                $0.widthCM + fitClearanceCM <= location.freeWidthCM
                    && $0.heightCM + fitClearanceCM <= location.freeHeightCM
                    && $0.depthCM + fitClearanceCM <= location.freeDepthCM
            }
            .max {
                footprintEfficiency($0, location) < footprintEfficiency($1, location)
            }
    }

    private static func footprintEfficiency(
        _ dimensions: PackageDimensions,
        _ location: StorageLocation
    ) -> Double {
        let packageArea = dimensions.widthCM * dimensions.depthCM
        let locationArea = max(location.freeWidthCM * location.freeDepthCM, 1)
        return packageArea / locationArea
    }
}
