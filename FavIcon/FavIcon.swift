//
// FavIcon
// Copyright © 2016 Leon Breedt
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

#if os(iOS)
    import UIKit
    /// Alias for the iOS image type (`UIImage`).
    public typealias ImageType = UIImage
#elseif os(OSX)
    import Cocoa
    /// Alias for the OS X image type (`NSImage`).
    public typealias ImageType = NSImage
#endif

/// Represents the result of attempting to download an icon.
public enum IconDownloadResult {
    /// Download successful.
    ///
    /// - parameters:
    ///   - image: The `ImageType` for the downloaded icon.
    case Success(image: ImageType)
    /// Download failed for some reason.
    ///
    /// - parameters:
    ///   - error: The error which can be consulted to determine the root cause.
    case Failure(error: ErrorProtocol)
}

/// Responsible for detecting all of the different icons supported by a given site.
public class FavIcon {

    // swiftlint:disable function_body_length
    /// Scans a base URL, attempting to determine all of the supported icons that can
    /// be used for favicon purposes.
    ///
    /// It will do the following to determine possible icons that can be used:
    ///
    /// - Check whether or not `/favicon.ico` exists.
    /// - If the base URL returns an HTML page, parse the `<head>` section and check for `<link>`
    ///   and `<meta>` tags that reference icons using Apple, Microsoft and Google
    ///   conventions.
    /// - If _Web Application Manifest JSON_ (`manifest.json`) files are referenced, or
    ///   _Microsoft browser configuration XML_ (`browserconfig.xml`) files
    ///   are referenced, download and parse them to check if they reference icons.
    ///
    ///  All of this work is performed in a background queue.
    ///
    /// - parameters:
    ///   - url: The base URL to scan.
    ///   - completion: A callback to invoke when the scan has completed. The callback will be invoked
    ///                 on the main queue.
    public static func scan(url: URL, completion: ([DetectedIcon]) -> Void) {
        let queue = DispatchQueue(label: "org.bitserf.FavIcon", attributes: .serial)
        var icons: [DetectedIcon] = []
        var additionalDownloads: [URLRequestWithCallback] = []
        let urlSession = urlSessionProvider()

        let downloadHTMLOperation = DownloadTextOperation(url: url, session: urlSession)
        let downloadHTML = urlRequestOperation(operation: downloadHTMLOperation) { result in
            // swiftlint:disable conditional_binding_cascade
            if case .TextDownloaded(let actualURL, let text, let contentType) = result {
            // swiftlint:enable conditional_binding_cascade
                if contentType == "text/html" {
                    let document = HTMLDocument(string: text)

                    let htmlIcons = extractHTMLHeadIcons(document: document, baseURL: actualURL)
                    queue.sync {
                        icons.append(contentsOf: htmlIcons)
                    }

                    for manifestURL in extractWebAppManifestURLs(document: document, baseURL: url) {
                        let downloadOperation = DownloadTextOperation(url: manifestURL,
                                                                              session: urlSession)
                        let download = urlRequestOperation(operation: downloadOperation) { result in
                            if case .TextDownloaded(_, let manifestJSON, _) = result {
                                let jsonIcons = extractManifestJSONIcons(
                                    jsonString: manifestJSON,
                                    baseURL: actualURL
                                )
                                queue.sync {
                                    icons.append(contentsOf: jsonIcons)
                                }
                            }
                        }
                        additionalDownloads.append(download)
                    }

                    let browserConfigResult = extractBrowserConfigURL(document: document, baseURL: url)
                    if let browserConfigURL = browserConfigResult.url where !browserConfigResult.disabled {
                        let downloadOperation = DownloadTextOperation(url: browserConfigURL,
                                                                      session: urlSession)
                        let download = urlRequestOperation(operation: downloadOperation) { result in
                            if case .TextDownloaded(_, let browserConfigXML, _) = result {
                                let document = LBXMLDocument(string: browserConfigXML)
                                let xmlIcons = extractBrowserConfigXMLIcons(
                                    document: document,
                                    baseURL: actualURL
                                )
                                queue.sync {
                                    icons.append(contentsOf: xmlIcons)
                                }
                            }
                        }
                        additionalDownloads.append(download)
                    }
                }
            }
        }


        let favIconURL = URL(string: "/favicon.ico", relativeTo: url as URL)!.absoluteURL
        let checkFavIconOperation = CheckURLExistsOperation(url: favIconURL!, session: urlSession)
        let checkFavIcon = urlRequestOperation(operation: checkFavIconOperation) { result in
            if case .Success(let actualURL) = result {
                queue.sync {
                    icons.append(DetectedIcon(url: actualURL, type: .Classic))
                }
            }
        }

        executeURLOperations(operations: [downloadHTML, checkFavIcon]) {
            if additionalDownloads.count > 0 {
                executeURLOperations(operations: additionalDownloads) {
                    DispatchQueue.main.async {
                        completion(icons)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(icons)
                }
            }
        }
    }
    // swiftlint:enable function_body_length

    /// Downloads an array of detected icons in the background.
    /// - parameters:
    ///   - icons: The icons to download.
    ///   - completion: A callback to invoke when all download tasks have
    ///                 results available (successful or otherwise). The callback
    ///                 will be invoked on the main queue.
    public static func download(icons: [DetectedIcon], completion: ([IconDownloadResult]) -> Void) {
        let urlSession = urlSessionProvider()
        let operations: [DownloadImageOperation] =
            icons.map { DownloadImageOperation(url: $0.url, session: urlSession) }

        executeURLOperations(operations: operations) { results in
            let downloadResults: [IconDownloadResult] = results.map { result in
                switch result {
                case .ImageDownloaded(_, let image):
                    return IconDownloadResult.Success(image: image)
                case .Failed(let error):
                    return IconDownloadResult.Failure(error: error)
                default:
                    return IconDownloadResult.Failure(error: IconError.InvalidDownloadResponse)
                }
            }

            DispatchQueue.main.async {
                completion(downloadResults)
            }
        }
    }

    /// Downloads all available icons by calling `scan()` to discover the available icons, and then
    /// performing background downloads of each icon.
    ///
    /// - parameters:
    ///   - url: The URL to scan for icons.
    ///   - completion: A callback to invoke when all download tasks have results available
    ///                 (successful or otherwise). The callback will be invoked on the main queue.
    public static func downloadAll(url: URL, completion: ([IconDownloadResult]) -> Void) {
        scan(url: url) { icons in
            download(icons: icons, completion: completion)
        }
    }

    /// Downloads the most preferred icon, by calling `scan()` to discover available icons, and then choosing
    /// the most preferable icon found. If both `width` and `height` are supplied, the icon closest to the
    /// preferred size is chosen. Otherwise, the largest icon is chosen, if dimensions are known. If no icon
    /// has dimensions, the icons are chosen by order of their `DetectedIconType` enumeration raw value.
    ///
    /// - parameters:
    ///   - url: The URL to scan for icons.
    ///   - width: The preferred icon width, in pixels, or `nil`.
    ///   - height: The preferred icon height, in pixels, or `nil`.
    ///   - completion: A callback to invoke when the download task has produced a result. The callback will
    ///                 be invoked on the main queue.
    /// - throws: An appropriate `IconError` if downloading failed for some reason.
    public static func downloadPreferred(url: URL,
                                         width: Int? = nil,
                                         height: Int? = nil,
                                         completion: (IconDownloadResult) -> Void) throws {
        scan(url: url) { icons in
            guard let icon = chooseIcon(icons: icons, width: width, height: height) else {
                DispatchQueue.main.async {
                    completion(IconDownloadResult.Failure(error: IconError.NoIconsDetected))
                }
                return
            }

            let urlSession = urlSessionProvider()

            let operations = [DownloadImageOperation(url: icon.url, session: urlSession)]
            executeURLOperations(operations: operations) { results in
                let downloadResults: [IconDownloadResult] = results.map { result in
                    switch result {
                    case .ImageDownloaded(_, let image):
                        return IconDownloadResult.Success(image: image)
                    case .Failed(let error):
                        return IconDownloadResult.Failure(error: error)
                    default:
                        return IconDownloadResult.Failure(error: IconError.InvalidDownloadResponse)
                    }
                }

                assert(downloadResults.count > 0)

                DispatchQueue.main.async {
                    completion(downloadResults.first!)
                }
            }
        }
    }

    // MARK: - Test hooks
    typealias URLSessionProvider = (Void) -> URLSession
    static var urlSessionProvider: URLSessionProvider = FavIcon.createDefaultURLSession

    // MARK: - Internal

    // Creates the default `NSURLSession` to use for background requests.
    static func createDefaultURLSession() -> URLSession {
        return URLSession.shared()
    }

    /// Helper function to choose an icon to use out of a set of available icons. If preferred
    /// width or height is supplied, the icon closest to the preferred size is chosen. If no
    /// preferred width or height is supplied, the largest icon (if known) is chosen.
    ///
    /// - parameters:
    ///   - icons: The icons to choose from.
    ///   - width: The preferred icon width.
    ///   - height: The preferred icon height.
    /// - returns: The chosen icon, or `nil`, if `icons` is empty.
    static func chooseIcon(icons: [DetectedIcon], width: Int? = nil, height: Int? = nil) -> DetectedIcon? {
        guard icons.count > 0 else { return nil }

        let iconsInPreferredOrder = icons.sorted { left, right in
            if let preferredWidth = width, preferredHeight = height,
                   widthLeft = left.width, heightLeft = left.height,
                   widthRight = right.width, heightRight = right.height {
                // Which is closest to preferred size?
                let deltaA = abs(widthLeft - preferredWidth) * abs(heightLeft - preferredHeight)
                let deltaB = abs(widthRight - preferredWidth) * abs(heightRight - preferredHeight)
                return deltaA < deltaB
            } else {
                if let areaLeft = left.area, areaRight = right.area {
                    // Which is larger?
                    return areaRight < areaLeft
                }
            }

            if left.area != nil {
                // Only A has dimensions, prefer it.
                return true
            }
            if right.area != nil {
                // Only B has dimensions, prefer it.
                return false
            }

            // Neither has dimensions, order by enum value
            return left.type.rawValue < right.type.rawValue
        }

        return iconsInPreferredOrder.first!
    }

    private init () {
    }
}

/// Enumerates errors that can be thrown while detecting or downloading icons.
enum IconError: ErrorProtocol {
    /// The base URL specified is not a valid URL.
    case InvalidBaseURL
    /// At least one icon to must be specified for downloading.
    case AtLeastOneOneIconRequired
    /// Unexpected response when downloading
    case InvalidDownloadResponse
    /// No icons were detected, so nothing could be downloaded.
    case NoIconsDetected
}

// MARK: - Extensions

extension FavIcon {
    /// Convenience overload for `scan(_:completion:)` that takes a `String`
    /// instead of an `NSURL` as the URL parameter. Throws an error if the URL is not a valid URL.
    ///
    /// - parameters:
    ///   - url: The base URL to scan.
    ///   - completion: A callback to invoke when the scan has completed. The callback will be invoked
    ///                 on the main queue.
    /// - throws: An `IconError` if the scan failed for some reason.
    public static func scan(url: String, completion: ([DetectedIcon]) -> Void) throws {
        guard let url = URL(string: url) else { throw IconError.InvalidBaseURL }
        scan(url: url, completion: completion)
    }

    /// Convenience overload for `downloadAll(_:completion:)` that takes a `String`
    /// instead of an `NSURL` as the URL parameter. Throws an error if the URL is not a valid URL.
    ///
    /// - parameters:
    ///   - url: The URL to scan for icons.
    ///   - completion: A callback to invoke when all download tasks have results available
    ///                 (successful or otherwise). The callback will be invoked on the main queue.
    /// - throws: An `IconError` if the scan or download failed for some reason.
    public static func downloadAll(url: String, completion: ([IconDownloadResult]) -> Void) throws {
        guard let url = URL(string: url) else { throw IconError.InvalidBaseURL }
        downloadAll(url: url, completion: completion)
    }

    /// Convenience overload for `downloadPreferred(_:width:height:completion:)` that takes a `String`
    /// instead of an `NSURL` as the URL parameter. Throws an error if the URL is not a valid URL.
    ///
    /// - parameters:
    ///   - url: The URL to scan for icons.
    ///   - width: The preferred icon width, in pixels, or `nil`.
    ///   - height: The preferred icon height, in pixels, or `nil`.
    ///   - completion: A callback to invoke when the download task has produced a result. The callback will
    ///                 be invoked on the main queue.
    /// - throws: An appropriate `IconError` if downloading failed for some reason.
    public static func downloadPreferred(url: String,
                                         width: Int? = nil,
                                         height: Int? = nil,
                                         completion: (IconDownloadResult) -> Void) throws {
        guard let url = URL(string: url) else { throw IconError.InvalidBaseURL }
        try downloadPreferred(url: url, width: width, height: height, completion: completion)
    }
}

extension DetectedIcon {
    /// The area of a detected icon, if known.
    var area: Int? {
        if let width = width, height = height {
            return width * height
        }
        return nil
    }
}
