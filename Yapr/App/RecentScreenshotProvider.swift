//
//  RecentScreenshotProvider.swift
//  Yapr
//
//  Reads the user's most recent iPhone screenshot from the Photos library.
//  Used when the user opens Yapr (via the Home Screen icon or the Control
//  Center button) so we can ask Claude about whatever they were just
//  looking at without requiring them to manually pick an image.
//
//  Privacy posture:
//    • We request `.readWrite` access to the Photos library, but only ever
//      read — we never write, edit, or delete photos.
//    • We filter strictly to assets with the `.photoScreenshot` mediaSubtype,
//      so non-screenshot photos are never enumerated.
//    • The image we load is held in memory for one Claude request and then
//      released. Nothing is persisted anywhere by Yapr.
//

import Foundation
import Photos
import UIKit

@MainActor
enum RecentScreenshotProvider {
    enum AccessStatus {
        case authorized
        case limited
        case notDetermined
        case denied
        case restricted
    }

    /// Snapshot of the user's current Photos authorization for read access.
    static func currentAuthorizationStatus() -> AccessStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .authorized
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// Triggers the system Photos permission prompt if not already determined.
    /// Returns the status that holds after the user responds.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> AccessStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard currentStatus == .notDetermined else {
            return currentAuthorizationStatus()
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor in
                    continuation.resume(returning: currentAuthorizationStatus())
                }
            }
        }
    }

    /// Result of a recent-screenshot fetch — both the rendered `UIImage`
    /// (for display in the preview) and JPEG data (ready to send to Claude),
    /// plus the natural pixel dimensions Claude should use as its coordinate
    /// space when returning a `[POINT:x,y]` tag.
    struct FetchedScreenshot {
        let image: UIImage
        let jpegData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let creationDate: Date?
    }

    /// Loads the user's most recent screenshot, downscaled if needed so the
    /// long edge is at most `maxLongEdgePixels`. Returns `nil` if there are
    /// no screenshots in the library or if access is denied.
    static func fetchMostRecentScreenshot(
        maxLongEdgePixels: CGFloat = 1280,
        jpegCompressionQuality: CGFloat = 0.8
    ) async -> FetchedScreenshot? {
        let authorizationStatus = currentAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            return nil
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        fetchOptions.fetchLimit = 1

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard let asset = fetchResult.firstObject else {
            return nil
        }

        let nativeWidth = CGFloat(asset.pixelWidth)
        let nativeHeight = CGFloat(asset.pixelHeight)
        let longEdge = max(nativeWidth, nativeHeight)
        let downscaleFactor = min(1.0, maxLongEdgePixels / longEdge)
        let targetSize = CGSize(
            width: nativeWidth * downscaleFactor,
            height: nativeHeight * downscaleFactor
        )

        let imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isNetworkAccessAllowed = true
        imageRequestOptions.deliveryMode = .highQualityFormat
        imageRequestOptions.resizeMode = .exact
        imageRequestOptions.isSynchronous = false

        let loadedImage: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: imageRequestOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }

        guard let loadedImage,
              let jpegData = loadedImage.jpegData(compressionQuality: jpegCompressionQuality) else {
            return nil
        }

        return FetchedScreenshot(
            image: loadedImage,
            jpegData: jpegData,
            pixelWidth: Int(loadedImage.size.width * loadedImage.scale),
            pixelHeight: Int(loadedImage.size.height * loadedImage.scale),
            creationDate: asset.creationDate
        )
    }
}
