//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import Foundation
import PackageFingerprint
import PackageLoading
import PackageModel
import PackageSigning
import TSCBasic

import struct TSCUtility.Version

public protocol RegistryClientDelegate {
    func onUnsigned(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
    func onUntrusted(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
}

/// Package registry client.
/// API specification: https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md
public final class RegistryClient: Cancellable {
    public typealias Delegate = RegistryClientDelegate

    private static let apiVersion: APIVersion = .v1
    private static let availabilityCacheTTL: DispatchTimeInterval = .seconds(5 * 60)
    private static let metadataCacheTTL: DispatchTimeInterval = .seconds(60 * 60)

    private let configuration: RegistryConfiguration
    private let archiverProvider: (FileSystem) -> Archiver
    private let httpClient: LegacyHTTPClient
    private let authorizationProvider: LegacyHTTPClientConfiguration.AuthorizationProvider?
    private let fingerprintStorage: PackageFingerprintStorage?
    private let fingerprintCheckingMode: FingerprintCheckingMode
    private let signingEntityStorage: PackageSigningEntityStorage?
    private let signingEntityCheckingMode: SigningEntityCheckingMode
    private let jsonDecoder: JSONDecoder
    private let delegate: Delegate?

    private let availabilityCache = ThreadSafeKeyValueStore<
        URL,
        (status: Result<AvailabilityStatus, Error>, expires: DispatchTime)
    >()

    private let metadataCache = ThreadSafeKeyValueStore<
        MetadataCacheKey,
        (metadata: Serialization.VersionMetadata, expires: DispatchTime)
    >()

    public init(
        configuration: RegistryConfiguration,
        fingerprintStorage: PackageFingerprintStorage?,
        fingerprintCheckingMode: FingerprintCheckingMode,
        signingEntityStorage: PackageSigningEntityStorage?,
        signingEntityCheckingMode: SigningEntityCheckingMode,
        authorizationProvider: AuthorizationProvider? = .none,
        customHTTPClient: LegacyHTTPClient? = .none,
        customArchiverProvider: ((FileSystem) -> Archiver)? = .none,
        delegate: Delegate?
    ) {
        self.configuration = configuration

        if let authorizationProvider = authorizationProvider {
            self.authorizationProvider = { url in
                guard let registryAuthentication = configuration.authentication(for: url) else {
                    return .none
                }
                guard let (user, password) = authorizationProvider.authentication(for: url) else {
                    return .none
                }

                switch registryAuthentication.type {
                case .basic:
                    let authorizationString = "\(user):\(password)"
                    guard let authorizationData = authorizationString.data(using: .utf8) else {
                        return nil
                    }
                    return "Basic \(authorizationData.base64EncodedString())"
                case .token: // `user` value is irrelevant in this case
                    return "Bearer \(password)"
                }
            }
        } else {
            self.authorizationProvider = .none
        }

        self.httpClient = customHTTPClient ?? LegacyHTTPClient()
        self.archiverProvider = customArchiverProvider ?? { fileSystem in ZipArchiver(fileSystem: fileSystem) }
        self.fingerprintStorage = fingerprintStorage
        self.fingerprintCheckingMode = fingerprintCheckingMode
        self.signingEntityStorage = signingEntityStorage
        self.signingEntityCheckingMode = signingEntityCheckingMode
        self.jsonDecoder = JSONDecoder.makeWithDefaults()
        self.delegate = delegate
    }

    public var explicitlyConfigured: Bool {
        self.configuration.explicitlyConfigured
    }

    /// Cancel any outstanding requests
    public func cancel(deadline: DispatchTime) throws {
        try self.httpClient.cancel(deadline: deadline)
    }

    public func getPackageMetadata(
        package: PackageIdentity,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PackageMetadata, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = package.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(package)))
        }

        guard let registry = self.configuration.registry(for: registryIdentity.scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: registryIdentity.scope)))
        }

        let underlying = {
            self._getPackageMetadata(
                registry: registry,
                package: registryIdentity,
                timeout: timeout,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _getPackageMetadata(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PackageMetadata, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents("\(package.scope)", "\(package.name)")
        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ],
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        let packageMetadata = try response.parseJSON(
                            Serialization.PackageMetadata.self,
                            decoder: self.jsonDecoder
                        )

                        let versions = packageMetadata.releases.filter { $0.value.problem == nil }
                            .compactMap { Version($0.key) }
                            .sorted(by: >)

                        let alternateLocations = try response.headers.parseAlternativeLocationLinks()

                        return PackageMetadata(
                            registry: registry,
                            versions: versions,
                            alternateLocations: alternateLocations?.map(\.url)
                        )
                    case 404:
                        throw RegistryError.packageNotFound
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                    }
                }.mapError {
                    RegistryError.failedRetrievingReleases(registry: registry, package: package.underlying, error: $0)
                }
            )
        }
    }

    public func getPackageVersionMetadata(
        package: PackageIdentity,
        version: Version,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PackageVersionMetadata, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = package.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(package)))
        }

        guard let registry = self.configuration.registry(for: registryIdentity.scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: registryIdentity.scope)))
        }

        let underlying = {
            self._getPackageVersionMetadata(
                registry: registry,
                package: registryIdentity,
                version: version,
                timeout: timeout,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _getPackageVersionMetadata(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PackageVersionMetadata, Error>) -> Void
    ) {
        self._getRawPackageVersionMetadata(
            registry: registry,
            package: package,
            version: version,
            timeout: timeout,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue
        ) { result in
            completion(
                result.tryMap { versionMetadata in
                    PackageVersionMetadata(
                        registry: registry,
                        licenseURL: versionMetadata.metadata?.licenseURL.flatMap { URL(string: $0) },
                        readmeURL: versionMetadata.metadata?.readmeURL.flatMap { URL(string: $0) },
                        repositoryURLs: versionMetadata.metadata?.repositoryURLs?.compactMap { URL(string: $0) },
                        resources: versionMetadata.resources.map {
                            .init(
                                name: $0.name,
                                type: $0.type,
                                checksum: $0.checksum,
                                signing: $0.signing.flatMap {
                                    PackageVersionMetadata.Signing(
                                        signatureBase64Encoded: $0.signatureBase64Encoded,
                                        signatureFormat: $0.signatureFormat
                                    )
                                }
                            )
                        },
                        author: versionMetadata.metadata?.author.map {
                            .init(
                                name: $0.name,
                                email: $0.email,
                                description: $0.description,
                                organization: $0.organization.map {
                                    .init(
                                        name: $0.name,
                                        email: $0.email,
                                        description: $0.description,
                                        url: $0.url.flatMap { URL(string: $0) }
                                    )
                                },
                                url: $0.url.flatMap { URL(string: $0) }
                            )
                        },
                        description: versionMetadata.metadata?.description
                    )
                }
            )
        }
    }

    private func _getRawPackageVersionMetadata(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Serialization.VersionMetadata, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        let cacheKey = MetadataCacheKey(registry: registry, package: package)
        if let cached = self.metadataCache[cacheKey], cached.expires < .now() {
            return completion(.success(cached.metadata))
        }

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents("\(package.scope)", "\(package.name)", "\(version)")

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ],
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        let metadata = try response.parseJSON(
                            Serialization.VersionMetadata.self,
                            decoder: self.jsonDecoder
                        )
                        self.metadataCache[cacheKey] = (metadata: metadata, expires: .now() + Self.metadataCacheTTL)
                        return metadata
                    case 404:
                        throw RegistryError.packageVersionNotFound
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                    }
                }.mapError {
                    RegistryError.failedRetrievingReleaseInfo(
                        registry: registry,
                        package: package.underlying,
                        version: version,
                        error: $0
                    )
                }
            )
        }
    }

    public func getAvailableManifests(
        package: PackageIdentity,
        version: Version,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<[String: (toolsVersion: ToolsVersion, content: String?)], Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = package.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(package)))
        }

        guard let registry = self.configuration.registry(for: registryIdentity.scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: registryIdentity.scope)))
        }

        let underlying = {
            self._getAvailableManifests(
                registry: registry,
                package: registryIdentity,
                version: version,
                timeout: timeout,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _getAvailableManifests(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<[String: (toolsVersion: ToolsVersion, content: String?)], Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents(
            "\(package.scope)",
            "\(package.name)",
            "\(version)",
            Manifest.filename
        )

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .swift),
            ],
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        try response.validateAPIVersion()
                        try response.validateContentType(.swift)

                        guard let data = response.body else {
                            throw RegistryError.invalidResponse
                        }
                        guard let manifestContent = String(data: data, encoding: .utf8) else {
                            throw RegistryError.invalidResponse
                        }

                        var result = [String: (toolsVersion: ToolsVersion, content: String?)]()
                        let toolsVersion = try ToolsVersionParser.parse(utf8String: manifestContent)
                        result[Manifest.filename] = (toolsVersion: toolsVersion, content: manifestContent)

                        let alternativeManifests = try response.headers.parseManifestLinks()
                        for alternativeManifest in alternativeManifests {
                            result[alternativeManifest.filename] = (
                                toolsVersion: alternativeManifest.toolsVersion,
                                content: .none
                            )
                        }
                        return result
                    case 404:
                        throw RegistryError.packageVersionNotFound
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                    }
                }.mapError {
                    RegistryError.failedRetrievingManifest(
                        registry: registry,
                        package: package.underlying,
                        version: version,
                        error: $0
                    )
                }
            )
        }
    }

    public func getManifestContent(
        package: PackageIdentity,
        version: Version,
        customToolsVersion: ToolsVersion?,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = package.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(package)))
        }

        guard let registry = self.configuration.registry(for: registryIdentity.scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: registryIdentity.scope)))
        }

        let underlying = {
            self._getManifestContent(
                registry: registry,
                package: registryIdentity,
                version: version,
                customToolsVersion: customToolsVersion,
                timeout: timeout,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _getManifestContent(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        customToolsVersion: ToolsVersion?,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents(
            "\(package.scope)",
            "\(package.name)",
            "\(version)",
            "Package.swift"
        )

        if let toolsVersion = customToolsVersion {
            components.queryItems = [
                URLQueryItem(name: "swift-version", value: toolsVersion.description),
            ]
        }

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .swift),
            ],
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response -> String in
                    switch response.statusCode {
                    case 200:
                        try response.validateAPIVersion(isOptional: true)
                        try response.validateContentType(.swift)

                        guard let data = response.body else {
                            throw RegistryError.invalidResponse
                        }
                        guard let manifestContent = String(data: data, encoding: .utf8) else {
                            throw RegistryError.invalidResponse
                        }

                        return manifestContent
                    case 404:
                        throw RegistryError.packageVersionNotFound
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                    }
                }.mapError {
                    RegistryError.failedRetrievingManifest(
                        registry: registry,
                        package: package.underlying,
                        version: version,
                        error: $0
                    )
                }
            )
        }
    }

    public func downloadSourceArchive(
        package: PackageIdentity,
        version: Version,
        destinationPath: AbsolutePath,
        checksumAlgorithm: HashAlgorithm, // the same algorithm used by `package compute-checksum` tool
        progressHandler: ((_ bytesReceived: Int64, _ totalBytes: Int64?) -> Void)?,
        timeout: DispatchTimeInterval? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = package.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(package)))
        }

        guard let registry = self.configuration.registry(for: registryIdentity.scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: registryIdentity.scope)))
        }

        let underlying = {
            self._downloadSourceArchive(
                registry: registry,
                package: registryIdentity,
                version: version,
                destinationPath: destinationPath,
                checksumAlgorithm: checksumAlgorithm,
                progressHandler: progressHandler,
                timeout: timeout,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _downloadSourceArchive(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        destinationPath: AbsolutePath,
        checksumAlgorithm: HashAlgorithm, // the same algorithm used by `package compute-checksum` tool
        progressHandler: ((_ bytesReceived: Int64, _ totalBytes: Int64?) -> Void)?,
        timeout: DispatchTimeInterval?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        // first get the release metadata
        // TODO: this should be included in the archive to save the extra HTTP call
        self._getPackageVersionMetadata(
            registry: registry,
            package: package,
            version: version,
            timeout: timeout,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue
        ) { result in
            switch result {
            case .success(let versionMetadata):
                // download archive
                guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
                    return completion(.failure(RegistryError.invalidURL(registry.url)))
                }
                components.appendPathComponents("\(package.scope)", "\(package.name)", "\(version).zip")

                guard let url = components.url else {
                    return completion(.failure(RegistryError.invalidURL(registry.url)))
                }

                // prepare target download locations
                let downloadPath = destinationPath.appending(extension: "zip")
                do {
                    // prepare directories
                    if !fileSystem.exists(downloadPath.parentDirectory) {
                        try fileSystem.createDirectory(downloadPath.parentDirectory, recursive: true)
                    }
                    // clear out download path if exists
                    try fileSystem.removeFileTree(downloadPath)
                    // validate that the destination does not already exist
                    guard !fileSystem.exists(destinationPath) else {
                        throw RegistryError.pathAlreadyExists(destinationPath)
                    }
                } catch {
                    return completion(.failure(error))
                }

                // signature validation helper
                let signatureValidation = SignatureValidation(
                    signingEntityStorage: self.signingEntityStorage,
                    signingEntityCheckingMode: self.signingEntityCheckingMode,
                    versionMetadataProvider: { _, _ in versionMetadata },
                    delegate: RegistryClientSignatureValidationDelegate(underlying: self.delegate)
                )

                // checksum TOFU validation helper
                let checksumTOFU = PackageVersionChecksumTOFU(
                    fingerprintStorage: self.fingerprintStorage,
                    fingerprintCheckingMode: self.fingerprintCheckingMode,
                    versionMetadataProvider: { _, _ in versionMetadata }
                )

                let request = LegacyHTTPClient.Request.download(
                    url: url,
                    headers: [
                        "Accept": self.acceptHeader(mediaType: .zip),
                    ],
                    options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue),
                    fileSystem: fileSystem,
                    destination: downloadPath
                )

                self.httpClient
                    .execute(request, observabilityScope: observabilityScope, progress: progressHandler) { result in
                        switch result {
                        case .success(let response):
                            do {
                                switch response.statusCode {
                                case 200:
                                    try response.validateAPIVersion(isOptional: true)
                                    try response.validateContentType(.zip)

                                    do {
                                        let archiveContent: Data = try fileSystem.readFileContents(downloadPath)
                                        // TODO: expose Data based API on checksumAlgorithm
                                        let actualChecksum = checksumAlgorithm.hash(.init(archiveContent))
                                            .hexadecimalRepresentation

                                        signatureValidation.validate(
                                            registry: registry,
                                            package: package,
                                            version: version,
                                            content: archiveContent,
                                            configuration: self.configuration.signing(for: package, registry: registry),
                                            timeout: timeout,
                                            observabilityScope: observabilityScope,
                                            callbackQueue: callbackQueue
                                        ) { signatureResult in
                                            switch signatureResult {
                                            case .success(let signingEntity):
                                                checksumTOFU.validate(
                                                    registry: registry,
                                                    package: package,
                                                    version: version,
                                                    checksum: actualChecksum,
                                                    timeout: timeout,
                                                    observabilityScope: observabilityScope,
                                                    callbackQueue: callbackQueue
                                                ) { checksumResult in
                                                    switch checksumResult {
                                                    case .success:
                                                        do {
                                                            // validate that the destination does not already exist (again, as this
                                                            // is
                                                            // async)
                                                            guard !fileSystem.exists(destinationPath) else {
                                                                throw RegistryError.pathAlreadyExists(destinationPath)
                                                            }
                                                            try fileSystem.createDirectory(
                                                                destinationPath,
                                                                recursive: true
                                                            )
                                                            // extract the content
                                                            let archiver = self.archiverProvider(fileSystem)
                                                            // TODO: Bail if archive contains relative paths or overlapping files
                                                            archiver
                                                                .extract(
                                                                    from: downloadPath,
                                                                    to: destinationPath
                                                                ) { result in
                                                                    defer {
                                                                        try? fileSystem.removeFileTree(downloadPath)
                                                                    }
                                                                    completion(result.tryMap {
                                                                        // strip first level component
                                                                        try fileSystem
                                                                            .stripFirstLevel(of: destinationPath)
                                                                        // write down copy of version metadata
                                                                        let registryMetadataPath = destinationPath
                                                                            .appending(
                                                                                component: RegistryReleaseMetadataStorage
                                                                                    .fileName
                                                                            )
                                                                        try RegistryReleaseMetadataStorage.save(
                                                                            metadata: versionMetadata,
                                                                            signingEntity: signingEntity,
                                                                            to: registryMetadataPath,
                                                                            fileSystem: fileSystem
                                                                        )
                                                                    }.mapError { error in
                                                                        StringError(
                                                                            "failed extracting '\(downloadPath)' to '\(destinationPath)': \(error)"
                                                                        )
                                                                    })
                                                                }
                                                        } catch {
                                                            completion(.failure(
                                                                RegistryError
                                                                    .failedDownloadingSourceArchive(
                                                                        registry: registry,
                                                                        package: package.underlying,
                                                                        version: version,
                                                                        error: error
                                                                    )
                                                            ))
                                                        }
                                                    case .failure(let error):
                                                        completion(.failure(error))
                                                    }
                                                }
                                            case .failure(let error):
                                                completion(.failure(error))
                                            }
                                        }
                                    } catch {
                                        throw RegistryError.failedToComputeChecksum(error)
                                    }
                                case 404:
                                    throw RegistryError.packageVersionNotFound
                                default:
                                    throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                                }
                            } catch {
                                completion(.failure(RegistryError.failedDownloadingSourceArchive(
                                    registry: registry,
                                    package: package.underlying,
                                    version: version,
                                    error: error
                                )))
                            }
                        case .failure(let error):
                            completion(.failure(RegistryError.failedDownloadingSourceArchive(
                                registry: registry,
                                package: package.underlying,
                                version: version,
                                error: error
                            )))
                        }
                    }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func lookupIdentities(
        scmURL: URL,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Set<PackageIdentity>, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registry = self.configuration.defaultRegistry else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: nil)))
        }

        let underlying = {
            self._lookupIdentities(
                registry: registry,
                scmURL: scmURL,
                timeout: timeout,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }

        if registry.supportsAvailability {
            self.withAvailabilityCheck(
                registry: registry,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { error in
                if let error = error {
                    return completion(.failure(error))
                }
                underlying()
            }
        } else {
            underlying()
        }
    }

    // marked internal for testing
    func _lookupIdentities(
        registry: Registry,
        scmURL: URL,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Set<PackageIdentity>, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents("identifiers")

        components.queryItems = [
            URLQueryItem(name: "url", value: scmURL.absoluteString),
        ]

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ],
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        let packageIdentities = try response.parseJSON(
                            Serialization.PackageIdentifiers.self,
                            decoder: self.jsonDecoder
                        )
                        return Set(packageIdentities.identifiers.map {
                            PackageIdentity.plain($0)
                        })
                    case 404:
                        // 404 is valid, no identities mapped
                        return []
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200, 404])
                    }
                }.mapError {
                    RegistryError.failedIdentityLookup(registry: registry, scmURL: scmURL, error: $0)
                }
            )
        }
    }

    public func login(
        loginURL: URL,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        let request = LegacyHTTPClient.Request(
            method: .post,
            url: loginURL,
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        return ()
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [200])
                    }
                }
            )
        }
    }

    public func publish(
        registryURL: URL,
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageArchive: AbsolutePath,
        packageMetadata: AbsolutePath?,
        signature: [UInt8]?,
        signatureFormat: SignatureFormat?,
        timeout: DispatchTimeInterval? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PublishResult, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard let registryIdentity = packageIdentity.registry else {
            return completion(.failure(RegistryError.invalidPackageIdentity(packageIdentity)))
        }
        guard var components = URLComponents(url: registryURL, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registryURL)))
        }
        components.appendPathComponents(registryIdentity.scope.description)
        components.appendPathComponents(registryIdentity.name.description)
        components.appendPathComponents(packageVersion.description)

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registryURL)))
        }

        // TODO: don't load the entire file in memory
        guard let packageArchiveContent: Data = try? fileSystem.readFileContents(packageArchive) else {
            return completion(.failure(RegistryError.failedLoadingPackageArchive(packageArchive)))
        }
        var metadataContent: String? = .none
        if let packageMetadata = packageMetadata {
            do {
                metadataContent = try fileSystem.readFileContents(packageMetadata)
            } catch {
                return completion(.failure(RegistryError.failedLoadingPackageMetadata(packageMetadata)))
            }
        }

        // TODO: add generic support for upload requests in Basics
        let boundary = UUID().uuidString
        var body = Data()

        // archive field
        body.append(contentsOf: """
        --\(boundary)\r
        Content-Disposition: form-data; name=\"source-archive\"\r
        Content-Type: application/zip\r
        Content-Transfer-Encoding: binary\r
        \r\n
        """.utf8)
        body.append(packageArchiveContent)

        if let signature = signature {
            guard signatureFormat != nil else {
                return completion(.failure(RegistryError.missingSignatureFormat))
            }

            body.append(contentsOf: """
            Content-Disposition: form-data; name=\"source-archive-signature\"\r
            Content-Type: application/octet-stream\r
            Content-Transfer-Encoding: binary\r
            \r\n
            """.utf8)
            body.append(contentsOf: signature)
        }

        // metadata field
        if let metadataContent = metadataContent {
            body.append(contentsOf: """
            \r
            --\(boundary)\r
            Content-Disposition: form-data; name=\"metadata\"\r
            Content-Type: application/json\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            \(metadataContent)
            """.utf8)
        }

        // footer
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = LegacyHTTPClient.Request(
            method: .put,
            url: url,
            headers: [
                "Content-Type": "multipart/form-data;boundary=\"\(boundary)\"",
                "Accept": self.acceptHeader(mediaType: .json),
                "Expect": "100-continue",
                "Prefer": "respond-async",
            ],
            body: body,
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        if signature != nil, let signatureFormat = signatureFormat {
            request.headers.add(name: "X-Swift-Package-Signature-Format", value: signatureFormat.rawValue)
        }

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 201:
                        try response.validateAPIVersion()

                        let location = response.headers.get("Location").first.flatMap { URL(string: $0) }
                        return PublishResult.published(location)
                    case 202:
                        try response.validateAPIVersion()

                        guard let location = (response.headers.get("Location").first.flatMap { URL(string: $0) }) else {
                            throw RegistryError.missingPublishingLocation
                        }
                        let retryAfter = response.headers.get("Retry-After").first.flatMap { Int($0) }
                        return PublishResult.processing(statusURL: location, retryAfter: retryAfter)
                    default:
                        throw self.unexpectedStatusError(response, expectedStatus: [201, 202])
                    }
                }.mapError {
                    RegistryError.failedPublishing($0)
                }
            )
        }
    }

    // marked internal for testing
    func checkAvailability(
        registry: Registry,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<AvailabilityStatus, Error>) -> Void
    ) {
        let completion = self.makeAsync(completion, on: callbackQueue)

        guard registry.supportsAvailability else {
            return completion(.failure(StringError("registry \(registry.url) does not support availability checks.")))
        }

        guard var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true) else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }
        components.appendPathComponents("availability")

        guard let url = components.url else {
            return completion(.failure(RegistryError.invalidURL(registry.url)))
        }

        let request = LegacyHTTPClient.Request(
            method: .get,
            url: url,
            options: self.defaultRequestOptions(timeout: timeout, callbackQueue: callbackQueue)
        )

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(
                result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        return .available
                    case let value where AvailabilityStatus.unavailableStatusCodes.contains(value):
                        return .unavailable
                    default:
                        if let error = try? response.parseError(decoder: self.jsonDecoder) {
                            return .error(error.detail)
                        }
                        return .error("unknown server error (\(response.statusCode))")
                    }
                }
            )
        }
    }

    private func withAvailabilityCheck(
        registry: Registry,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        next: @escaping (Error?) -> Void
    ) {
        let availabilityHandler: (Result<AvailabilityStatus, Error>)
            -> Void = { (result: Result<AvailabilityStatus, Error>) in
                switch result {
                case .success(let status):
                    switch status {
                    case .available:
                        return next(.none)
                    case .unavailable:
                        return next(RegistryError.registryNotAvailable(registry))
                    case .error(let description):
                        return next(StringError(description))
                    }
                case .failure(let error):
                    return next(error)
                }
            }

        if let cached = self.availabilityCache[registry.url], cached.expires < .now() {
            return availabilityHandler(cached.status)
        }

        self.checkAvailability(
            registry: registry,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue
        ) { result in
            self.availabilityCache[registry.url] = (status: result, expires: .now() + Self.availabilityCacheTTL)
            availabilityHandler(result)
        }
    }

    private func unexpectedStatusError(
        _ response: HTTPClientResponse,
        expectedStatus: [Int]
    ) -> Error {
        if let error = try? response.parseError(decoder: self.jsonDecoder) {
            return RegistryError.serverError(code: response.statusCode, details: error.detail)
        }

        switch response.statusCode {
        case 401:
            return RegistryError.unauthorized
        case 403:
            return RegistryError.forbidden
        case 501:
            return RegistryError.authenticationMethodNotSupported
        case 500, 502, 503:
            return RegistryError.serverError(
                code: response.statusCode,
                details: response.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            )
        default:
            return RegistryError.invalidResponseStatus(expected: expectedStatus, actual: response.statusCode)
        }
    }

    private func makeAsync<T>(
        _ closure: @escaping (Result<T, Error>) -> Void,
        on queue: DispatchQueue
    ) -> (Result<T, Error>) -> Void {
        { result in queue.async { closure(result) } }
    }

    private func defaultRequestOptions(
        timeout: DispatchTimeInterval? = .none,
        callbackQueue: DispatchQueue
    ) -> LegacyHTTPClient.Request.Options {
        var options = LegacyHTTPClient.Request.Options()
        options.timeout = timeout
        options.callbackQueue = callbackQueue
        options.authorizationProvider = self.authorizationProvider
        return options
    }

    private struct MetadataCacheKey: Hashable {
        let registry: Registry
        let package: PackageIdentity.RegistryIdentity
    }
}

public enum RegistryError: Error, CustomStringConvertible {
    case registryNotConfigured(scope: PackageIdentity.Scope?)
    case invalidPackageIdentity(PackageIdentity)
    case invalidURL(URL)
    case invalidResponseStatus(expected: [Int], actual: Int)
    case invalidContentVersion(expected: String, actual: String?)
    case invalidContentType(expected: String, actual: String?)
    case invalidResponse
    case missingSourceArchive
    case invalidSourceArchive
    case unsupportedHashAlgorithm(String)
    case failedToComputeChecksum(Error)
    case checksumChanged(latest: String, previous: String)
    case invalidChecksum(expected: String, actual: String)
    case pathAlreadyExists(AbsolutePath)
    case failedRetrievingReleases(registry: Registry, package: PackageIdentity, error: Error)
    case failedRetrievingReleaseInfo(registry: Registry, package: PackageIdentity, version: Version, error: Error)
    case failedRetrievingReleaseChecksum(registry: Registry, package: PackageIdentity, version: Version, error: Error)
    case failedRetrievingManifest(registry: Registry, package: PackageIdentity, version: Version, error: Error)
    case failedDownloadingSourceArchive(registry: Registry, package: PackageIdentity, version: Version, error: Error)
    case failedIdentityLookup(registry: Registry, scmURL: URL, error: Error)
    case failedLoadingPackageArchive(AbsolutePath)
    case failedLoadingPackageMetadata(AbsolutePath)
    case failedPublishing(Error)
    case missingPublishingLocation
    case serverError(code: Int, details: String)
    case unauthorized
    case authenticationMethodNotSupported
    case forbidden
    case registryNotAvailable(Registry)
    case packageNotFound
    case packageVersionNotFound
    case sourceArchiveMissingChecksum(registry: Registry, package: PackageIdentity, version: Version)
    case sourceArchiveNotSigned(registry: Registry, package: PackageIdentity, version: Version)
    case failedLoadingSignature
    case failedRetrievingSourceArchiveSignature(
        registry: Registry,
        package: PackageIdentity,
        version: Version,
        error: Error
    )
    case missingConfiguration(details: String)
    case missingSignatureFormat
    case unknownSignatureFormat(String)
    case invalidSignature(reason: String)
    case invalidSigningCertificate(reason: String)
    case signerNotTrusted
    case failedToValidateSignature(Error)
    case signingEntityForReleaseChanged(
        package: PackageIdentity,
        version: Version,
        latest: SigningEntity?,
        previous: SigningEntity
    )
    case signingEntityForPackageChanged(package: PackageIdentity, latest: SigningEntity?, previous: SigningEntity)

    public var description: String {
        switch self {
        case .registryNotConfigured(let scope):
            if let scope = scope {
                return "no registry configured for '\(scope)' scope"
            } else {
                return "no registry configured'"
            }
        case .invalidPackageIdentity(let packageIdentity):
            return "invalid package identifier '\(packageIdentity)'"
        case .invalidURL(let url):
            return "invalid URL '\(url)'"
        case .invalidResponseStatus(let expected, let actual):
            return "invalid registry response status '\(actual)', expected '\(expected)'"
        case .invalidContentVersion(let expected, let actual):
            return "invalid registry response content version '\(actual ?? "")', expected '\(expected)'"
        case .invalidContentType(let expected, let actual):
            return "invalid registry response content type '\(actual ?? "")', expected '\(expected)'"
        case .invalidResponse:
            return "invalid registry response"
        case .missingSourceArchive:
            return "missing registry source archive"
        case .invalidSourceArchive:
            return "invalid registry source archive"
        case .unsupportedHashAlgorithm(let algorithm):
            return "unsupported hash algorithm '\(algorithm)'"
        case .failedToComputeChecksum(let error):
            return "failed computing registry source archive checksum: \(error)"
        case .checksumChanged(let latest, let previous):
            return "the latest checksum '\(latest)' is different from the previously recorded value '\(previous)'"
        case .invalidChecksum(let expected, let actual):
            return "invalid registry source archive checksum '\(actual)', expected '\(expected)'"
        case .pathAlreadyExists(let path):
            return "path already exists '\(path)'"
        case .failedRetrievingReleases(let registry, let packageIdentity, let error):
            return "failed fetching '\(packageIdentity)' releases list from '\(registry)': \(error)"
        case .failedRetrievingReleaseInfo(let registry, let packageIdentity, let version, let error):
            return "failed fetching '\(packageIdentity)@\(version)' release information from '\(registry)': \(error)"
        case .failedRetrievingReleaseChecksum(let registry, let packageIdentity, let version, let error):
            return "failed fetching '\(packageIdentity)@\(version)' release checksum from '\(registry)': \(error)"
        case .failedRetrievingManifest(let registry, let packageIdentity, let version, let error):
            return "failed retrieving '\(packageIdentity)@\(version)' manifest from '\(registry)': \(error)"
        case .failedDownloadingSourceArchive(let registry, let packageIdentity, let version, let error):
            return "failed downloading '\(packageIdentity)@\(version)' source archive from '\(registry)': \(error)"
        case .failedIdentityLookup(let registry, let scmURL, let error):
            return "failed looking up identity for '\(scmURL)' on '\(registry)': \(error)"
        case .failedLoadingPackageArchive(let path):
            return "failed loading package archive at '\(path)' for publishing"
        case .failedLoadingPackageMetadata(let path):
            return "failed loading package metadata at '\(path)' for publishing"
        case .failedPublishing(let error):
            return "failed publishing: \(error)"
        case .missingPublishingLocation:
            return "response missing registry source archive"
        case .serverError(let code, let details):
            return "server error \(code): \(details)"
        case .unauthorized:
            return "missing or invalid authentication credentials"
        case .authenticationMethodNotSupported:
            return "authentication method not supported"
        case .forbidden:
            return "forbidden"
        case .registryNotAvailable(let registry):
            return "registry at '\(registry.url)' is not available at this time, please try again later"
        case .packageNotFound:
            return "package not found on registry"
        case .packageVersionNotFound:
            return "package version not found on registry"
        case .sourceArchiveMissingChecksum(let registry, let packageIdentity, let version):
            return "'\(packageIdentity)@\(version)' source archive from '\(registry)' has no checksum"
        case .sourceArchiveNotSigned(let registry, let packageIdentity, let version):
            return "'\(packageIdentity)@\(version)' source archive from '\(registry)' is not signed"
        case .failedLoadingSignature:
            return "failed loading signature for validation"
        case .failedRetrievingSourceArchiveSignature(let registry, let packageIdentity, let version, let error):
            return "failed retrieving '\(packageIdentity)@\(version)' source archive signature from '\(registry)': \(error)"
        case .missingConfiguration(let details):
            return "unable to proceed because of missing configuration: \(details)"
        case .missingSignatureFormat:
            return "missing signature format"
        case .unknownSignatureFormat(let format):
            return "unknown signature format: \(format)"
        case .invalidSignature(let reason):
            return "signature is invalid: \(reason)"
        case .invalidSigningCertificate(let reason):
            return "the signing certificate is invalid: \(reason)"
        case .signerNotTrusted:
            return "the signer is not trusted"
        case .failedToValidateSignature(let error):
            return "failed to validate signature: \(error)"
        case .signingEntityForReleaseChanged(let package, let version, let latest, let previous):
            return "the signing entity '\(String(describing: latest))' for '\(package)@\(version)' is different from the previously recorded value '\(previous)'"
        case .signingEntityForPackageChanged(let package, let latest, let previous):
            return "the signing entity '\(String(describing: latest))' for '\(package)' is different from the previously recorded value '\(previous)'"
        }
    }
}

extension RegistryClient {
    fileprivate enum APIVersion: String {
        case v1 = "1"
    }
}

extension RegistryClient {
    fileprivate enum MediaType: String {
        case json
        case swift
        case zip
    }

    fileprivate enum ContentType: String, CaseIterable {
        case json = "application/json"
        case swift = "text/x-swift"
        case zip = "application/zip"
        case error = "application/problem+json"
    }

    private func acceptHeader(mediaType: MediaType) -> String {
        "application/vnd.swift.registry.v\(Self.apiVersion.rawValue)+\(mediaType)"
    }
}

extension RegistryClient {
    public struct PackageMetadata {
        public let registry: Registry
        public let versions: [Version]
        public let alternateLocations: [URL]?
    }

    public struct PackageVersionMetadata {
        public let registry: Registry
        public let licenseURL: URL?
        public let readmeURL: URL?
        public let repositoryURLs: [URL]?
        public let resources: [Resource]
        public let author: Author?
        public let description: String?

        public var sourceArchive: Resource? {
            self.resources.first(where: { $0.name == "source-archive" })
        }

        public struct Resource {
            public let name: String
            public let type: String
            public let checksum: String?
            public let signing: Signing?

            public init(name: String, type: String, checksum: String?, signing: Signing?) {
                self.name = name
                self.type = type
                self.checksum = checksum
                self.signing = signing
            }
        }

        public struct Signing {
            public let signatureBase64Encoded: String
            public let signatureFormat: String
        }

        public struct Author {
            public let name: String
            public let email: String?
            public let description: String?
            public let organization: Organization?
            public let url: URL?
        }

        public struct Organization {
            public let name: String
            public let email: String?
            public let description: String?
            public let url: URL?
        }
    }
}

extension RegistryClient {
    fileprivate struct AlternativeLocationLink {
        let url: URL
        let kind: Kind

        enum Kind: String {
            case canonical
            case alternate
        }
    }
}

extension RegistryClient {
    fileprivate struct ManifestLink {
        let url: URL
        let filename: String
        let toolsVersion: ToolsVersion
    }
}

extension RegistryClient {
    public enum PublishResult: Equatable {
        case published(URL?)
        case processing(statusURL: URL, retryAfter: Int?)
    }
}

extension RegistryClient {
    public enum AvailabilityStatus: Equatable {
        case available
        case unavailable
        case error(String)

        // marked internal for testing
        static var unavailableStatusCodes = [404, 501]
    }
}

extension RegistryClient {
    struct ServerError: Decodable {
        let detail: String
    }

    struct RatelimitError {
        let retryAfter: Int
    }
}

extension HTTPClientResponse {
    fileprivate func parseJSON<T>(_ type: T.Type, decoder: JSONDecoder) throws -> T where T: Decodable {
        try self.validateAPIVersion()
        try self.validateContentType(.json)

        guard let data = self.body else {
            throw RegistryError.invalidResponse
        }

        return try decoder.decode(type, from: data)
    }

    fileprivate func parseError(
        decoder: JSONDecoder
    ) throws -> RegistryClient.ServerError {
        try self.validateAPIVersion()
        try self.validateContentType(.error)

        guard let data = self.body else {
            throw RegistryError.invalidResponse
        }

        return try decoder.decode(RegistryClient.ServerError.self, from: data)
    }
}

extension HTTPClientResponse {
    private func validateStatusCode(_ expectedStatusCodes: [Int]) throws {
        guard expectedStatusCodes.contains(self.statusCode) else {
            throw RegistryError.invalidResponseStatus(expected: expectedStatusCodes, actual: self.statusCode)
        }
    }

    fileprivate func validateAPIVersion(
        _ expectedVersion: RegistryClient.APIVersion = .v1,
        isOptional: Bool = false
    ) throws {
        let apiVersion = self.apiVersion

        if isOptional, apiVersion == nil {
            return
        }

        // Check API version as long as `Content-Version` is set
        guard apiVersion == expectedVersion else {
            throw RegistryError.invalidContentVersion(
                expected: expectedVersion.rawValue,
                actual: self.apiVersion?.rawValue
            )
        }
    }

    fileprivate func validateContentType(_ expectedContentType: RegistryClient.ContentType) throws {
        guard self.contentType == expectedContentType else {
            throw RegistryError.invalidContentType(
                expected: expectedContentType.rawValue,
                actual: self.contentType?.rawValue
            )
        }
    }

    fileprivate var apiVersion: RegistryClient.APIVersion? {
        self.headers.get("Content-Version").first.flatMap { headerValue in
            RegistryClient.APIVersion(rawValue: headerValue)
        }
    }

    private var contentType: RegistryClient.ContentType? {
        self.headers.get("Content-Type").first.flatMap { headerValue in
            if let contentType = RegistryClient.ContentType(rawValue: headerValue) {
                return contentType
            }
            if let contentType = RegistryClient.ContentType.allCases.first(where: {
                headerValue.hasPrefix($0.rawValue + ";")
            }) {
                return contentType
            }
            return nil
        }
    }
}

extension HTTPClientHeaders {
    /*
     <https://github.com/mona/LinkedList>; rel="canonical",
     <ssh://git@github.com:mona/LinkedList.git>; rel="alternate",
      */
    fileprivate func parseAlternativeLocationLinks() throws -> [RegistryClient.AlternativeLocationLink]? {
        try self.get("Link").map { header -> [RegistryClient.AlternativeLocationLink] in
            let linkLines = header.split(separator: ",").map(String.init).map { $0.spm_chuzzle() ?? $0 }
            return try linkLines.compactMap { linkLine in
                try parseAlternativeLocationLine(linkLine)
            }
        }.flatMap { $0 }
    }

    private func parseAlternativeLocationLine(_ value: String) throws -> RegistryClient.AlternativeLocationLink? {
        let fields = value.split(separator: ";")
            .map(String.init)
            .map { $0.spm_chuzzle() ?? $0 }

        guard fields.count == 2 else {
            return nil
        }

        guard let link = fields.first(where: { $0.hasPrefix("<") }).map({ String($0.dropFirst().dropLast()) }),
              let url = URL(string: link)
        else {
            return nil
        }

        guard let rel = fields.first(where: { $0.hasPrefix("rel=") }).flatMap({ parseLinkFieldValue($0) }),
              let kind = RegistryClient.AlternativeLocationLink.Kind(rawValue: rel)
        else {
            return nil
        }

        return RegistryClient.AlternativeLocationLink(
            url: url,
            kind: kind
        )
    }
}

extension HTTPClientHeaders {
    /*
     <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0"
     */
    fileprivate func parseManifestLinks() throws -> [RegistryClient.ManifestLink] {
        try self.get("Link").map { header -> [RegistryClient.ManifestLink] in
            let linkLines = header.split(separator: ",").map(String.init).map { $0.spm_chuzzle() ?? $0 }
            return try linkLines.compactMap { linkLine in
                try parseManifestLinkLine(linkLine)
            }
        }.flatMap { $0 }
    }

    private func parseManifestLinkLine(_ value: String) throws -> RegistryClient.ManifestLink? {
        let fields = value.split(separator: ";")
            .map(String.init)
            .map { $0.spm_chuzzle() ?? $0 }

        guard fields.count == 4 else {
            return nil
        }

        guard let link = fields.first(where: { $0.hasPrefix("<") }).map({ String($0.dropFirst().dropLast()) }),
              let url = URL(string: link)
        else {
            return nil
        }

        guard let rel = fields.first(where: { $0.hasPrefix("rel=") }).flatMap({ parseLinkFieldValue($0) }),
              rel == "alternate"
        else {
            return nil
        }

        guard let filename = fields.first(where: { $0.hasPrefix("filename=") }).flatMap({ parseLinkFieldValue($0) })
        else {
            return nil
        }

        guard let toolsVersion = fields.first(where: { $0.hasPrefix("swift-tools-version=") })
            .flatMap({ parseLinkFieldValue($0) })
        else {
            return nil
        }

        guard let toolsVersion = ToolsVersion(string: toolsVersion) else {
            throw StringError("Invalid tools version in alternate manifest link '\(value)'")
        }

        return RegistryClient.ManifestLink(
            url: url,
            filename: filename,
            toolsVersion: toolsVersion
        )
    }
}

extension HTTPClientHeaders {
    private func parseLinkFieldValue(_ field: String) -> String? {
        let parts = field.split(separator: "=")
            .map(String.init)
            .map { $0.spm_chuzzle() ?? $0 }

        guard parts.count == 2 else {
            return nil
        }

        return parts[1].replacingOccurrences(of: "\"", with: "")
    }
}

// MARK: - Serialization

extension RegistryClient {
    // marked public for testing (cross module visibility)
    public enum Serialization {
        // marked public for testing (cross module visibility)
        public struct PackageMetadata: Codable {
            public let releases: [String: Release]

            public init(releases: [String: Release]) {
                self.releases = releases
            }

            public struct Release: Codable {
                public var url: String?
                public var problem: Problem?

                public init(url: String?, problem: Problem? = .none) {
                    self.url = url
                    self.problem = problem
                }
            }

            public struct Problem: Codable {
                public var status: Int?
                public var title: String?
                public var detail: String

                public init(status: Int, title: String, detail: String) {
                    self.status = status
                    self.title = title
                    self.detail = detail
                }
            }
        }

        // marked public for testing (cross module visibility)
        public struct VersionMetadata: Codable {
            public let id: String
            public let version: String
            public let resources: [Resource]
            public let metadata: AdditionalMetadata?

            var sourceArchive: Resource? {
                self.resources.first(where: { $0.name == "source-archive" })
            }

            public init(
                id: String,
                version: String,
                resources: [Resource],
                metadata: AdditionalMetadata?
            ) {
                self.id = id
                self.version = version
                self.resources = resources
                self.metadata = metadata
            }

            public struct Resource: Codable {
                public let name: String
                public let type: String
                public let checksum: String?
                public let signing: Signing?

                public init(name: String, type: String, checksum: String, signing: Signing?) {
                    self.name = name
                    self.type = type
                    self.checksum = checksum
                    self.signing = signing
                }
            }

            public struct Signing: Codable {
                public let signatureBase64Encoded: String
                public let signatureFormat: String
            }

            public struct AdditionalMetadata: Codable {
                public let author: Author?
                public let description: String?
                public let licenseURL: String?
                public let readmeURL: String?
                public let repositoryURLs: [String]?

                public init(
                    author: Author? = nil,
                    description: String,
                    licenseURL: String? = nil,
                    readmeURL: String? = nil,
                    repositoryURLs: [String]? = nil
                ) {
                    self.author = author
                    self.description = description
                    self.licenseURL = licenseURL
                    self.readmeURL = readmeURL
                    self.repositoryURLs = repositoryURLs
                }
            }

            public struct Author: Codable {
                public let name: String
                public let email: String?
                public let description: String?
                public let organization: Organization?
                public let url: String?
            }

            public struct Organization: Codable {
                public let name: String
                public let email: String?
                public let description: String?
                public let url: String?
            }
        }

        // marked public for testing (cross module visibility)
        public struct PackageIdentifiers: Codable {
            public let identifiers: [String]

            public init(identifiers: [String]) {
                self.identifiers = identifiers
            }
        }
    }
}

// MARK: - RegistryReleaseMetadata serialization helpers

extension RegistryReleaseMetadataStorage {
    fileprivate static func save(
        metadata: RegistryClient.PackageVersionMetadata,
        signingEntity: SigningEntity?,
        to path: AbsolutePath,
        fileSystem: FileSystem
    ) throws {
        let registryMetadata = try RegistryReleaseMetadata(
            metadata: metadata,
            signingEntity: signingEntity
        )
        try self.save(registryMetadata, to: path, fileSystem: fileSystem)
    }
}

extension RegistryReleaseMetadata {
    fileprivate init(
        metadata: RegistryClient.PackageVersionMetadata,
        signingEntity: PackageSigning.SigningEntity?
    ) throws {
        self.init(
            source: .registry(metadata.registry.url),
            metadata: .init(
                author: metadata.author.flatMap {
                    .init(
                        name: $0.name,
                        emailAddress: $0.email,
                        description: $0.description,
                        url: $0.url,
                        organization: $0.organization.flatMap {
                            .init(
                                name: $0.name,
                                emailAddress: $0.email,
                                description: $0.description,
                                url: $0.url
                            )
                        }
                    )
                },
                description: metadata.description,
                licenseURL: metadata.licenseURL,
                readmeURL: metadata.readmeURL,
                scmRepositoryURLs: metadata.repositoryURLs
            ),
            signature: try metadata.sourceArchive?.signing.flatMap {
                guard let signatureData = Data(base64Encoded: $0.signatureBase64Encoded) else {
                    throw StringError("invalid based64 encoded signature")
                }
                return RegistrySignature(
                    signedBy: signingEntity.flatMap {
                        switch $0.type {
                        case .adp:
                            return .recognized(
                                type: "adp",
                                commonName: $0.name,
                                organization: $0.organization,
                                identity: $0.organizationalUnit
                            )
                        case .none:
                            return .unrecognized(commonName: $0.name, organization: $0.organization)
                        }
                    },
                    format: $0.signatureFormat,
                    value: Array(signatureData)
                )
            }
        )
    }
}

private struct RegistryClientSignatureValidationDelegate: SignatureValidation.Delegate {
    let underlying: RegistryClient.Delegate?

    func onUnsigned(
        registry: Registry,
        package: PackageModel.PackageIdentity,
        version: TSCUtility.Version,
        completion: (Bool) -> Void
    ) {
        if let underlying = self.underlying {
            underlying.onUnsigned(registry: registry, package: package, version: version, completion: completion)
        } else {
            // true == continue resolution
            // false == stop dependency resolution
            completion(false)
        }
    }

    func onUntrusted(
        registry: Registry,
        package: PackageModel.PackageIdentity,
        version: TSCUtility.Version,
        completion: (Bool) -> Void
    ) {
        if let underlying = self.underlying {
            underlying.onUntrusted(registry: registry, package: package, version: version, completion: completion)
        } else {
            // true == continue resolution
            // false == stop dependency resolution
            completion(false)
        }
    }
}

// MARK: - Utilities

extension URLComponents {
    fileprivate mutating func appendPathComponents(_ components: String...) {
        path += (path.last == "/" ? "" : "/") + components.joined(separator: "/")
    }
}
