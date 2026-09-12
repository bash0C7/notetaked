import Foundation
import Testing
@testable import NotetakeCore

@Test func normalizedRemovesPunctuationAndWidth() {
    #expect(TextSimilarity.normalized("こんにちは、世界！　ＡＢＣ 123") == "こんにちは世界ABC123")
}

@Test func identicalIsOne() {
    #expect(TextSimilarity.bigramDice("今日は晴れです", "今日は晴れです") == 1.0)
}

@Test func disjointIsZero() {
    #expect(TextSimilarity.bigramDice("あいうえお", "かきくけこ") == 0.0)
}

@Test func similarAboveHalf() {
    #expect(TextSimilarity.bigramDice("明日の会議は十時からです", "明日の会議は10時からです") > 0.5)
}

@Test func dissimilarBelowHalf() {
    #expect(TextSimilarity.bigramDice("明日の会議は十時からです", "資料を送っておきますね") < 0.5)
}

@Test func shortStrings() {
    #expect(TextSimilarity.bigramDice("あ", "あ") == 1.0)
    #expect(TextSimilarity.bigramDice("あ", "い") == 0.0)
    #expect(TextSimilarity.bigramDice("", "") == 1.0)
}
