import Foundation

/// Name and capacity of the volume that holds a given path.
public struct VolumeCapacity: Equatable, Sendable {
    public var name: String?
    public var total: Int64?
    /// Bytes that can be written, per `effectiveAvailableCapacity`
    public var available: Int64?

    public init(name: String?, total: Int64?, available: Int64?) {
        self.name = name
        self.total = total
        self.available = available
    }
}

/// Picks the free-space figure to show and to check a sync against.
///
/// `volumeAvailableCapacityForImportantUsage` is only meaningful on the boot volume, where it also counts
/// purgeable space the system frees on demand (so it can exceed the plain figure). On other volumes
/// (mounted disk images, external APFS/HFS+/FAT drives) it comes back as 0 even with plenty of room,
/// so the larger of the two values is used. Returns nil only when neither value is known.
public func effectiveAvailableCapacity(importantUsage: Int64?, plain: Int?) -> Int64? {
    let candidates = [importantUsage, plain.map(Int64.init)].compactMap { $0 }.map { max(0, $0) }
    return candidates.max()
}

/// Reads name, total and effective free space of the volume containing `url`; nil if the lookup fails.
public func readVolumeCapacity(at url: URL) -> VolumeCapacity? {
    guard let values = try? url.resourceValues(forKeys: [
        .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]) else { return nil }
    return VolumeCapacity(
        name: values.volumeName,
        total: values.volumeTotalCapacity.map(Int64.init),
        available: effectiveAvailableCapacity(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            plain: values.volumeAvailableCapacity))
}
