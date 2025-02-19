//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import Dispatch
import struct Foundation.Data

import Basics
import PackageModel
import PackageSigning

import struct TSCUtility.Version

protocol SignatureValidationDelegate {
    func onUnsigned(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
    func onUntrusted(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
}

struct SignatureValidation {
    typealias Delegate = SignatureValidationDelegate

    private let signingEntityTOFU: PackageSigningEntityTOFU
    private let versionMetadataProvider: (PackageIdentity.RegistryIdentity, Version) throws -> RegistryClient
        .PackageVersionMetadata
    private let delegate: Delegate

    init(
        signingEntityStorage: PackageSigningEntityStorage?,
        signingEntityCheckingMode: SigningEntityCheckingMode,
        versionMetadataProvider: @escaping (PackageIdentity.RegistryIdentity, Version) throws -> RegistryClient
            .PackageVersionMetadata,
        delegate: Delegate
    ) {
        self.signingEntityTOFU = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )
        self.versionMetadataProvider = versionMetadataProvider
        self.delegate = delegate
    }

    func validate(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        self.getAndValidateSignature(
            registry: registry,
            package: package,
            version: version,
            content: content,
            configuration: configuration,
            timeout: timeout,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue
        ) { result in
            switch result {
            case .success(let signingEntity):
                // Always do signing entity TOFU check at the end,
                // whether the package is signed or not.
                self.signingEntityTOFU.validate(
                    package: package,
                    version: version,
                    signingEntity: signingEntity,
                    observabilityScope: observabilityScope,
                    callbackQueue: callbackQueue
                ) { _ in
                    completion(.success(signingEntity))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getAndValidateSignature(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        timeout: DispatchTimeInterval?,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        do {
            let versionMetadata = try self.versionMetadataProvider(package, version)

            guard let sourceArchiveResource = versionMetadata.sourceArchive else {
                throw RegistryError.missingSourceArchive
            }
            guard let signatureBase64Encoded = sourceArchiveResource.signing?.signatureBase64Encoded else {
                throw RegistryError.sourceArchiveNotSigned(
                    registry: registry,
                    package: package.underlying,
                    version: version
                )
            }
            guard let signatureData = Data(base64Encoded: signatureBase64Encoded) else {
                throw RegistryError.failedLoadingSignature
            }
            guard let signatureFormatString = sourceArchiveResource.signing?.signatureFormat else {
                throw RegistryError.missingSignatureFormat
            }
            guard let signatureFormat = SignatureFormat(rawValue: signatureFormatString) else {
                throw RegistryError.unknownSignatureFormat(signatureFormatString)
            }

            self.validateSignature(
                registry: registry,
                package: package,
                version: version,
                signature: signatureData,
                signatureFormat: signatureFormat,
                content: content,
                configuration: configuration,
                observabilityScope: observabilityScope,
                completion: completion
            )
        } catch RegistryError.sourceArchiveNotSigned(let registry, let package, let version) {
            let sourceArchiveNotSignedError = RegistryError.sourceArchiveNotSigned(
                registry: registry,
                package: package,
                version: version
            )

            guard let onUnsigned = configuration.onUnsigned else {
                return completion(.failure(RegistryError.missingConfiguration(details: "security.signing.onUnsigned")))
            }

            switch onUnsigned {
            case .prompt:
                self.delegate.onUnsigned(registry: registry, package: package, version: version) { `continue` in
                    if `continue` {
                        completion(.success(.none))
                    } else {
                        completion(.failure(sourceArchiveNotSignedError))
                    }
                }
            case .error:
                completion(.failure(sourceArchiveNotSignedError))
            case .warn:
                observabilityScope.emit(warning: "\(sourceArchiveNotSignedError)")
                completion(.success(.none))
            case .silentAllow:
                // Continue without logging
                completion(.success(.none))
            }
        } catch RegistryError.signerNotTrusted {
            guard let onUntrusted = configuration.onUntrustedCertificate else {
                return completion(.failure(
                    RegistryError
                        .missingConfiguration(details: "security.signing.onUntrustedCertificate")
                ))
            }

            switch onUntrusted {
            case .prompt:
                self.delegate.onUntrusted(registry: registry, package: package.underlying, version: version) { `continue` in
                    if `continue` {
                        completion(.success(.none))
                    } else {
                        completion(.failure(RegistryError.signerNotTrusted))
                    }
                }
            case .error:
                // TODO: populate error with signer detail
                completion(.failure(RegistryError.signerNotTrusted))
            case .warn:
                // TODO: populate error with signer detail
                observabilityScope.emit(warning: "\(RegistryError.signerNotTrusted)")
                completion(.success(.none))
            case .silentAllow:
                // Continue without logging
                completion(.success(.none))
            }
        } catch RegistryError.failedRetrievingReleaseInfo(_, _, _, let error) {
            completion(.failure(RegistryError.failedRetrievingSourceArchiveSignature(
                registry: registry,
                package: package.underlying,
                version: version,
                error: error
            )))
        } catch {
            completion(.failure(RegistryError.failedRetrievingSourceArchiveSignature(
                registry: registry,
                package: package.underlying,
                version: version,
                error: error
            )))
        }
    }

    private func validateSignature(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        signature: Data,
        signatureFormat: SignatureFormat,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        Task {
            do {
                let signatureStatus = try await SignatureProvider.status(
                    signature: Array(signature),
                    content: Array(content),
                    format: signatureFormat,
                    // TODO: load trusted roots (trustedRootCertificatesPath, includeDefaultTrustedRootCertificates)
                    // TODO: build policy set (validationChecks)
                    verifierConfiguration: .init(),
                    observabilityScope: observabilityScope
                )

                switch signatureStatus {
                case .valid(let signingEntity):
                    completion(.success(signingEntity))
                case .invalid(let reason):
                    completion(.failure(RegistryError.invalidSignature(reason: reason)))
                case .certificateInvalid(let reason):
                    completion(.failure(RegistryError.invalidSigningCertificate(reason: reason)))
                case .certificateNotTrusted:
                    completion(.failure(RegistryError.signerNotTrusted))
                }
            } catch {
                completion(.failure(RegistryError.failedToValidateSignature(error)))
            }
        }
    }
}
