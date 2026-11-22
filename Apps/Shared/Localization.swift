import AlbumWinnowCore
import Foundation

enum L10n {
    static func cleanupFailure(_ reason: CleanupFailureReason) -> String {
        switch reason {
        case .cleanup(let failure): error(failure)
        case .cancelled: text("operation_cancelled")
        case .inaccessible: text("cleanup_error_inaccessible")
        }
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    static func format(_ key: String, arguments: [CVarArg] = [], bundle: Bundle = .main, locale: Locale = .current) -> String {
        let template = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return String(format: template, locale: locale, arguments: arguments)
    }

    static func error(_ error: Error) -> String {
        switch error {
        case let error as CleanupError:
            switch error {
            case .invalidSelection: return text("cleanup_error_invalid_selection")
            case .operationInProgress: return text("cleanup_error_in_progress")
            case .unavailableSource: return text("cleanup_error_unavailable_source")
            case .readOnlySource: return text("cleanup_error_read_only_source")
            case .userProtected: return text("cleanup_error_locked")
            case .unavailableProtection: return text("cleanup_error_unavailable_protection")
            case .protectedResources: return text("cleanup_error_associated_resources")
            case .changedAsset: return text("cleanup_error_changed_asset")
            case .noLongerDuplicate: return text("cleanup_error_no_longer_duplicate")
            case .sameFile: return text("cleanup_error_same_file")
            case .unsupportedSource: return text("cleanup_error_unsupported_source")
            }
        case let error as ScopeError:
            switch error {
            case .invalidDateRange: return text("scope_error_invalid_date_range")
            case .unavailableAlbum: return text("scope_error_unavailable_album")
            case .invalidComparison: return text("scope_error_invalid_comparison")
            }
        case let error as AssetAccessError:
            switch error {
            case .inaccessible: return text("asset_error_inaccessible")
            case .changedDuringScan: return text("asset_error_changed")
            case .cloudDownloadRequired: return text("asset_error_cloud_required")
            case .cloudDownloadFailed: return text("asset_error_cloud_failed")
            }
        case let error as ScanError:
            switch error {
            case .scanInProgress: return text("scan_error_in_progress")
            case .duplicateSourceID: return text("scan_error_duplicate_source")
            case .invalidSourceSnapshot: return text("scan_error_invalid_snapshot")
            }
        case let error as ImageReadError:
            switch error {
            case .unreadableImage: return text("image_error_unreadable")
            case .multipleImages: return text("image_error_multiple_images")
            case .unsupportedDimensions: return text("image_error_dimensions")
            }
        case is PhotoLibraryReadError: return text("photos_error_authorization")
        case is PhotoDifferenceError: return text("difference_error_invalid_pair")
        case is CancellationError: return text("operation_cancelled")
        default: return text("operation_error_detail", error.localizedDescription)
        }
    }
}
