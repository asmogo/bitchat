import Testing
@testable import BitFoundation

struct FragmentationLimitsTests {
    @Test
    func requiredCountHandlesExactAndPartialChunks() {
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: 256, chunkSize: 1) == 256)
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: 257, chunkSize: 1) == 257)
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: 513, chunkSize: 256) == 3)
    }

    @Test
    func invalidPlansAreRejected() {
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: 0, chunkSize: 1) == nil)
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: 1, chunkSize: 0) == nil)
        #expect(FragmentationLimits.requiredFragmentCount(byteCount: -1, chunkSize: 1) == nil)
    }
}
