import Testing
@testable import TurboFieldfareAppCore

@Suite struct AppContextUsageTests {
    @Test func reportsRemainingCapacityBelowTheLimit() {
        let usage = AppContextUsage(promptTokens: 3_000, maximumTokens: 4_096)

        #expect(usage.remainingTokens == 1_096)
        #expect(usage.overflowingTokens == 0)
        #expect(usage.overLimitTokens == 0)
        #expect(!usage.isOverflowing)
        #expect(!usage.requiresHistoryCompression)
        #expect(usage.fraction > 0.73 && usage.fraction < 0.74)
    }

    @Test func reportsOverflowWithoutGrowingTheProgressFractionPastOne() {
        let usage = AppContextUsage(promptTokens: 4_500, maximumTokens: 4_096)

        #expect(usage.remainingTokens == 0)
        #expect(usage.overflowingTokens == 404)
        #expect(usage.overLimitTokens == 404)
        #expect(usage.isOverflowing)
        #expect(!usage.requiresHistoryCompression)
        #expect(usage.fraction == 1)
    }

    @Test func exactLimitCountsAsOverflowBecauseDecodeNeedsCapacity() {
        let usage = AppContextUsage(promptTokens: 4_096, maximumTokens: 4_096)

        #expect(usage.isOverflowing)
        #expect(usage.overflowingTokens == 0)
    }

    @Test func distinguishesCompressibleHistoryFromAnOversizedCurrentTurn() {
        let usage = AppContextUsage(
            promptTokens: 4_500,
            maximumTokens: 4_096,
            currentTurnTokens: 900)

        #expect(!usage.isOverflowing)
        #expect(usage.requiresHistoryCompression)
        #expect(usage.overLimitTokens == 404)
        #expect(usage.overflowingTokens == 0)
    }
}
