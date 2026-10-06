import Testing
@testable import LoomCatalogUI

/// The footer chip and the Settings page share one number format (plans/STAGE-U.md design picks).
struct UsageFormatTests {
    @Test func tokensAreExactBelowOneThousandThenKMBWithThreeSignificantDigits() {
        let cases: [(Int64, String)] = [
            (0, "0"), (7, "7"), (999, "999"), (1_000, "1K"), (1_500, "1.5K"), (12_345, "12.3K"),
            (940_000, "940K"), (999_499, "999K"), (999_500, "1M"), (999_999, "1M"),
            (1_204_310, "1.2M"), (12_400_000, "12.4M"), (123_456_789, "123M"),
            (1_284_610_000, "1.28B"), (999_999_999, "1B"), (12_000_000_000, "12B"),
        ]
        for (value, expected) in cases { #expect(UsageFormat.tokens(value) == expected, "value \(value)") }
    }

    @Test func groupedIsExactWithCommas() {
        #expect(UsageFormat.grouped(0) == "0")
        #expect(UsageFormat.grouped(999) == "999")
        #expect(UsageFormat.grouped(1_204_310) == "1,204,310")
        #expect(UsageFormat.grouped(1_284_610_000) == "1,284,610,000")
    }

    @Test func costShowsCentsBelowOneThousandDollarsAndWholeDollarsAbove() {
        #expect(UsageFormat.cost(3.1) == "~$3.10")
        #expect(UsageFormat.cost(0) == "~$0.00")
        #expect(UsageFormat.cost(0.004) == "~$0.00")
        #expect(UsageFormat.cost(999.99) == "~$999.99")
        #expect(UsageFormat.cost(999.996) == "~$1,000")
        #expect(UsageFormat.cost(1_000) == "~$1,000")
        #expect(UsageFormat.cost(12_845.6) == "~$12,846")
    }

    @Test func fullCostKeepsCentsForTheTooltip() {
        #expect(UsageFormat.fullCost(3.1) == "$3.10")
        #expect(UsageFormat.fullCost(12_845.6) == "$12,845.60")
    }

    @Test func spokenTokensUseWords() {
        #expect(UsageFormat.spokenTokens(940) == "940")
        #expect(UsageFormat.spokenTokens(940_000) == "940 thousand")
        #expect(UsageFormat.spokenTokens(1_204_310) == "1.2 million")
        #expect(UsageFormat.spokenTokens(1_284_610_000) == "1.28 billion")
    }
}
