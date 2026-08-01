/// Cross-client fragmentation limits and overflow-safe plan sizing.
public enum FragmentationLimits {
    /// Android receivers reject fragment sets above this deployed ceiling.
    public static let crossPlatformMaxFragments = 256

    /// Returns the number of chunks required without allocating or copying the
    /// payload. Empty payloads and non-positive chunk sizes are invalid plans.
    public static func requiredFragmentCount(
        byteCount: Int,
        chunkSize: Int
    ) -> Int? {
        guard byteCount > 0, chunkSize > 0 else { return nil }
        let quotient = byteCount / chunkSize
        return quotient + (byteCount % chunkSize == 0 ? 0 : 1)
    }
}
