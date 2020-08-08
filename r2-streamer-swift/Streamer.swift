//
//  Streamer.swift
//  r2-streamer-swift
//
//  Created by Mickaël Menu on 14/07/2020.
//
//  Copyright 2020 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import R2Shared

/// Opens a `Publication` using a list of parsers.
public final class Streamer: Loggable {
    
    /// Creates the default parsers provided by Readium.
    public static func makeDefaultParsers() -> [PublicationParser] {
        return [
            EPUBParser(),
            PDFParser(parserType: PDFFileCGParser.self),
            ReadiumWebPubParser(),
            ImageParser(),
            AudioParser()
        ]
    }
    
    /// `Streamer` is configured to use Readium's default parsers, which you can bypass using
    /// `ignoreDefaultParsers`. However, you can provide additional `parsers` which will take
    /// precedence over the default ones. This can also be used to provide an alternative
    /// configuration of a default parser.
    ///
    /// - Parameters:
    ///   - parsers: Parsers used to open a publication, in addition to the default parsers.
    ///   - ignoreDefaultParsers: When true, only parsers provided in parsers will be used.
    ///   - contentProtections: List of `ContentProtection` used to unlock publications. Each
    ///     `ContentProtection` is tested in the given order.
    ///   - openArchive: Opens an archive (e.g. ZIP, RAR), optionally protected by credentials.
    ///   - openPDF: Parses a PDF document, optionally protected by password.
    ///   - onCreatePublication: Transformation which will be applied on every parsed Publication
    ///     Builder. It can be used to modify the `Manifest`, the root `Fetcher` or the list of
    ///     service factories of a `Publication`.
    public init(
        parsers: [PublicationParser] = [],
        ignoreDefaultParsers: Bool = false,
        contentProtections: [ContentProtection] = [],
        openArchive: @escaping ArchiveFactory = DefaultArchiveFactory,
        onCreatePublication: Publication.Builder.Transform? = nil
    ) {
        self.parsers = parsers + (ignoreDefaultParsers ? [] : Streamer.makeDefaultParsers())
        self.contentProtections = contentProtections
        self.openArchive = openArchive
        self.onCreatePublication = onCreatePublication
    }
    
    private let parsers: [PublicationParser]
    private let contentProtections: [ContentProtection]
    private let openArchive: ArchiveFactory
    private let onCreatePublication: Publication.Builder.Transform?

    /// Parses a `Publication` from the given file.
    ///
    /// If you are opening the publication to render it in a Navigator, you must set
    /// `allowUserInteraction`to true to prompt the user for its credentials when the publication is
    /// protected. However, set it to false if you just want to import the `Publication` without
    /// reading its content, to avoid prompting the user.
    ///
    /// When using Content Protections, you can use `sender` to provide a free object which can be
    /// used to give some context. For example, it could be the source `UIViewController` which
    /// would be used to present a credentials dialog.
    ///
    /// The `warnings` logger can be used to observe non-fatal parsing warnings, caused by
    /// publication authoring mistakes. This can be useful to warn users of potential rendering
    /// issues.
    ///
    /// - Parameters:
    ///   - file: Path to the publication file.
    ///   - allowUserInteraction: Indicates whether the user can be prompted during opening, for
    ///     example to ask their credentials.
    ///   - fallbackTitle: The Publication's title is mandatory, but some formats might not have a
    ///     way of declaring a title (e.g. CBZ). In which case, `fallbackTitle` will be used.
    ///   - credentials: Credentials that Content Protections can use to attempt to unlock a
    ///     publication, for example a password.
    ///   - sender: Free object that can be used by reading apps to give some UX context when
    ///     presenting dialogs.
    ///   - warnings: Logger used to broadcast non-fatal parsing warnings.
    public func open(file: File, allowUserInteraction: Bool, fallbackTitle: String? = nil, credentials: String? = nil, sender: Any? = nil, warnings: WarningLogger? = nil, completion: @escaping (CancellableResult<Publication, Publication.OpeningError>) -> Void) {
        let fallbackTitle = fallbackTitle ?? file.name
        
        log(.info, "Open \(file.url.lastPathComponent)")

        return createFetcher(for: file, allowUserInteraction: allowUserInteraction, password: credentials, sender: sender)
            .flatMap { fetcher in
                // Unlocks any protected file with the Content Protections.
                self.openFile(at: file, with: fetcher, allowUserInteraction: allowUserInteraction, credentials: credentials, sender: sender)
            }
            .flatMap { file in
                // Parses the Publication using the parsers.
                self.parsePublication(from: file, fallbackTitle: fallbackTitle, warnings: warnings)
            }
            .resolve(on: .main, completion)
    }
    
    /// Creates the leaf fetcher which will be passed to the content protections and parsers.
    ///
    /// We attempt to open an `ArchiveFetcher`, and fall back on a `FileFetcher` if the file is not
    /// an archive.
    private func createFetcher(for file: File, allowUserInteraction: Bool, password: String?, sender: Any?) -> Deferred<Fetcher, Publication.OpeningError> {
        return deferred(on: .global(qos: .userInitiated)) {
            guard (try? file.url.checkResourceIsReachable()) == true else {
                return .failure(.notFound)
            }
            
            do {
                let fetcher = try ArchiveFetcher(url: file.url, password: password, openArchive: self.openArchive)
                return .success(fetcher)
                
            } catch ArchiveError.invalidPassword {
                return .failure(.incorrectCredentials)

            } catch {
                return .success(FileFetcher(href: "/\(file.name)", path: file.url))
            }
        }
    }
    
    /// Unlocks any protected file with the provided Content Protections.
    private func openFile(at file: File, with fetcher: Fetcher, allowUserInteraction: Bool, credentials: String?, sender: Any?) -> Deferred<PublicationFile, Publication.OpeningError> {
        func unlock(using protections: [ContentProtection]) -> Deferred<ProtectedFile?, Publication.OpeningError> {
            return deferred {
                var protections = protections
                guard let protection = protections.popFirst() else {
                    // No Content Protection applied, this file is probably not protected.
                    return .success(nil)
                }
    
                return protection
                    .open(file: file, fetcher: fetcher, allowUserInteraction: allowUserInteraction, credentials: credentials, sender: sender)
                    .flatMap {
                        if let protectedFile = $0 {
                            return .success(protectedFile)
                        } else {
                            return unlock(using: protections)
                        }
                    }
            }
        }
        
        return unlock(using: contentProtections)
            .map { protectedFile in
                protectedFile ?? PublicationFile(file, fetcher, nil)
            }
    }
    
    /// Parses the `Publication` from the provided file and the `parsers`.
    private func parsePublication(from file: PublicationFile, fallbackTitle: String, warnings: WarningLogger?) -> Deferred<Publication, Publication.OpeningError> {
        return deferred(on: .global(qos: .userInitiated)) {
            var parsers = self.parsers
            var parsedBuilder: Publication.Builder?
            while parsedBuilder == nil, let parser = parsers.popFirst() {
                do {
                    parsedBuilder = try parser.parse(file: file.file, fetcher: file.fetcher, fallbackTitle: fallbackTitle, warnings: warnings)
                } catch {
                    return .failure(.parsingFailed(error))
                }
            }
            
            guard var builder = parsedBuilder else {
                return .failure(.unsupportedFormat)
            }
            
            // Transform from the Content Protection.
            builder.apply(file.onCreatePublication)
            // Transform provided by the reading app.
            builder.apply(self.onCreatePublication)

            return .success(builder.build())
        }
    }

}

private typealias PublicationFile = (file: File, fetcher: Fetcher, onCreatePublication: Publication.Builder.Transform?)

private extension ContentProtection {
    
    /// Wrapper to use `Deferred` with `ContentProtection.open()`.
    func open(file: File, fetcher: Fetcher, allowUserInteraction: Bool, credentials: String?, sender: Any?) -> Deferred<ProtectedFile?, Publication.OpeningError> {
        return deferred { completion in
            self.open(file: file, fetcher: fetcher, allowUserInteraction: allowUserInteraction, credentials: credentials, sender: sender, completion: completion)
        }
    }

}
