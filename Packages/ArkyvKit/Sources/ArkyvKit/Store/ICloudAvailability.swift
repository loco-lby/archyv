import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Core Loop Hardening 02 §8-9: the smallest honest iCloud surface Cherries
/// can show — whether the device currently has a usable iCloud account for
/// `ArkyvStore.cloudKitContainerID`, nothing more. This is deliberately NOT
/// sync telemetry: SwiftData's CloudKit mirroring exposes no per-record
/// completion signal, no last-sync timestamp, and no queue depth, so there
/// is no honest way to report "synced" or show progress. Before this,
/// Settings hardcoded "Local only" under a "Sync" row — stale copy from
/// before CloudKit mirroring existed at all, and actively misleading (the
/// store has mirrored to a CloudKit private database since Technical
/// Identity Cutover 01). This does not fix that lie by inventing a new one
/// ("Synced") — it replaces it with the one thing Cherries can actually
/// verify: is an iCloud account available right now.
public enum ICloudAvailability: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    /// Short phrase for a Settings row. Never claims data has synced —
    /// only that an iCloud account is (or isn't) currently usable.
    public var description: String {
        switch self {
        case .available: return "iCloud available"
        case .noAccount: return "Signed out of iCloud"
        case .restricted: return "iCloud restricted"
        case .temporarilyUnavailable: return "iCloud temporarily unavailable"
        case .couldNotDetermine: return "iCloud status unknown"
        }
    }

    #if canImport(CloudKit)
    /// Single async account-status check — no polling, no observer, no
    /// retry loop. Callers decide when to ask (Settings asks once on
    /// appear); this deliberately adds no background work of its own.
    public static func current(containerID: String = ArkyvStore.cloudKitContainerID) async -> ICloudAvailability {
        let container = CKContainer(identifier: containerID)
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }
    #else
    public static func current(containerID: String = ArkyvStore.cloudKitContainerID) async -> ICloudAvailability {
        .couldNotDetermine
    }
    #endif
}
