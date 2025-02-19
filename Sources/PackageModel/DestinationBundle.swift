//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import TSCBasic

/// Represents an `.artifactbundle` on the filesystem that contains cross-compilation destinations.
public struct DestinationBundle {
    public struct Variant: Equatable {
        let metadata: ArtifactsArchiveMetadata.Variant
        let destinations: [Destination]
    }

    let path: AbsolutePath

    /// Mapping of artifact IDs to variants available for a corresponding artifact.
    public fileprivate(set) var artifacts = [String: [Variant]]()

    /// Lists all valid cross-compilation destination bundles in a given directory.
    /// - Parameters:
    ///   - destinationsDirectory: the directory to scan for destination bundles.
    ///   - fileSystem: the filesystem the directory is located on.
    ///   - observabilityScope: observability scope to report bundle validation errors.
    /// - Returns: an array of valid destination bundles.
    public static func getAllValidBundles(
        destinationsDirectory: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [Self] {
        // Get absolute paths to available destination bundles.
        try fileSystem.getDirectoryContents(destinationsDirectory).filter {
            $0.hasSuffix(BinaryTarget.Kind.artifactsArchive.fileExtension)
        }.map {
            destinationsDirectory.appending(components: [$0])
        }.compactMap {
            do {
                // Enumerate available bundles and parse manifests for each of them, then validate supplied
                // destinations.
                return try Self.parseAndValidate(
                    bundlePath: $0,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )
            } catch {
                observabilityScope.emit(
                    .warning(
                        "Couldn't parse `info.json` manifest of a destination bundle at \($0): \(error)"
                    )
                )
                return nil
            }
        }
    }

    /// Select destinations matching a given query and host triple from all destinations available in a directory.
    /// - Parameters:
    ///   - destinationsDirectory: the directory to scan for destination bundles.
    ///   - fileSystem: the filesystem the directory is located on.
    ///   - query: either an artifact ID or target triple to filter with.
    ///   - hostTriple: triple of the host building with these destinations.
    ///   - observabilityScope: observability scope to log warnings about multiple matches.
    /// - Returns: `Destination` value matching `query` either by artifact ID or target triple, `nil` if none found.
    public static func selectDestination(
        fromBundlesAt destinationsDirectory: AbsolutePath?,
        fileSystem: FileSystem,
        matching selector: String,
        hostTriple: Triple,
        observabilityScope: ObservabilityScope
    ) throws -> Destination {
        guard let destinationsDirectory = destinationsDirectory else {
            throw StringError(
                """
                No cross-compilation destinations directory found, specify one
                with `experimental-destinations-path` option.
                """
            )
        }

        let validBundles = try DestinationBundle.getAllValidBundles(
            destinationsDirectory: destinationsDirectory,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        guard !validBundles.isEmpty else {
            throw StringError(
                "No valid cross-compilation destination bundles found at \(destinationsDirectory)."
            )
        }

        guard var selectedDestination = validBundles.selectDestination(
            matching: selector,
            hostTriple: hostTriple,
            observabilityScope: observabilityScope
        ) else {
            throw StringError(
                """
                No cross-compilation destination found matching query `\(selector)` and host triple
                `\(hostTriple.tripleString)`. Use `swift package experimental-destination list` command to see
                available destinations.
                """
            )
        }

        selectedDestination.applyPathCLIOptions()

        return selectedDestination
    }

    /// Parses metadata of an `.artifactbundle` and validates it as a bundle containing
    /// cross-compilation destinations.
    /// - Parameters:
    ///   - bundlePath: path to the bundle root directory.
    ///   - fileSystem: filesystem containing the bundle.
    ///   - observabilityScope: observability scope to log validation warnings.
    /// - Returns: Validated `DestinationsBundle` containing validated `Destination` values for
    /// each artifact and its variants.
    private static func parseAndValidate(
        bundlePath: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> Self {
        let parsedManifest = try ArtifactsArchiveMetadata.parse(
            fileSystem: fileSystem,
            rootPath: bundlePath
        )

        return try parsedManifest.validateDestinationBundle(
            bundlePath: bundlePath,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }
}

extension ArtifactsArchiveMetadata {
    fileprivate func validateDestinationBundle(
        bundlePath: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> DestinationBundle {
        var result = DestinationBundle(path: bundlePath)

        for (artifactID, artifactMetadata) in artifacts
            where artifactMetadata.type == .crossCompilationDestination
        {
            var variants = [DestinationBundle.Variant]()

            for variantMetadata in artifactMetadata.variants {
                let destinationJSONPath = try bundlePath
                    .appending(RelativePath(validating: variantMetadata.path))
                    .appending("destination.json")

                guard fileSystem.exists(destinationJSONPath) else {
                    observabilityScope.emit(
                        .warning(
                            """
                            Destination metadata file not found at \(
                                destinationJSONPath
                            ) for a variant of artifact \(artifactID)
                            """
                        )
                    )

                    continue
                }

                do {
                    let destinations = try Destination.decode(
                        fromFile: destinationJSONPath, fileSystem: fileSystem, observabilityScope: observabilityScope
                    )

                    variants.append(.init(metadata: variantMetadata, destinations: destinations))
                } catch {
                    observabilityScope.emit(
                        .warning(
                            "Couldn't parse destination metadata at \(destinationJSONPath): \(error)"
                        )
                    )
                }
            }

            result.artifacts[artifactID] = variants
        }

        return result
    }
}

extension Array where Element == DestinationBundle {
    /// Select a destination with a given artifact ID from a `self` array of available destinations.
    /// - Parameters:
    ///   - id: artifact ID of the destination to look up.
    ///   - hostTriple: triple of the machine on which the destination is building.
    ///   - targetTriple: triple of the machine for which the destination is building.
    /// - Returns: `Destination` value with a given artifact ID, `nil` if none found.
    public func selectDestination(id: String, hostTriple: Triple, targetTriple: Triple) -> Destination? {
        for bundle in self {
            for (artifactID, variants) in bundle.artifacts {
                guard artifactID == id else {
                    continue
                }

                for variant in variants {
                    guard variant.metadata.supportedTriples.contains(hostTriple) else {
                        continue
                    }

                    return variant.destinations.first { $0.targetTriple == targetTriple }
                }
            }
        }

        return nil
    }

    /// Select destinations matching a given selector and host triple from a `self` array of available destinations.
    /// - Parameters:
    ///   - selector: either an artifact ID or target triple to filter with.
    ///   - hostTriple: triple of the host building with these destinations.
    ///   - observabilityScope: observability scope to log warnings about multiple matches.
    /// - Returns: `Destination` value matching `query` either by artifact ID or target triple, `nil` if none found.
    public func selectDestination(
        matching selector: String,
        hostTriple: Triple,
        observabilityScope: ObservabilityScope
    ) -> Destination? {
        var matchedByID: (path: AbsolutePath, variant: DestinationBundle.Variant, destination: Destination)?
        var matchedByTriple: (path: AbsolutePath, variant: DestinationBundle.Variant, destination: Destination)?

        for bundle in self {
            for (artifactID, variants) in bundle.artifacts {
                for variant in variants {
                    guard variant.metadata.supportedTriples.contains(hostTriple) else {
                        continue
                    }

                    for destination in variant.destinations {
                        if artifactID == selector {
                            if let matchedByID = matchedByID {
                                observabilityScope.emit(
                                    warning:
                                    """
                                    multiple destinations match ID `\(artifactID)` and host triple \(
                                        hostTriple.tripleString
                                    ), selected one at \(
                                        matchedByID.path.appending(component: matchedByID.variant.metadata.path)
                                    )
                                    """
                                )
                            } else {
                                matchedByID = (bundle.path, variant, destination)
                            }
                        }

                        if destination.targetTriple?.tripleString == selector {
                            if let matchedByTriple = matchedByTriple {
                                observabilityScope.emit(
                                    warning:
                                    """
                                    multiple destinations match target triple `\(selector)` and host triple \(
                                        hostTriple.tripleString
                                    ), selected one at \(
                                        matchedByTriple.path.appending(component: matchedByTriple.variant.metadata.path)
                                    )
                                    """
                                )
                            } else {
                                matchedByTriple = (bundle.path, variant, destination)
                            }
                        }
                    }
                }
            }
        }

        if let matchedByID = matchedByID, let matchedByTriple = matchedByTriple, matchedByID != matchedByTriple {
            observabilityScope.emit(
                warning:
                """
                multiple destinations match the query `\(selector)` and host triple \(
                    hostTriple.tripleString
                ), selected one at \(matchedByID.path.appending(component: matchedByID.variant.metadata.path))
                """
            )
        }

        return matchedByID?.destination ?? matchedByTriple?.destination
    }
}
