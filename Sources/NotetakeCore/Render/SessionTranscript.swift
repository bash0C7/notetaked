import Foundation

/// `timed.jsonl`から`final.md`を作る唯一の経路。serve、`notetaked render`、整形が同じ関数を通る
public enum SessionTranscript {
    public static func records(timedText: String) -> [Record] {
        NDJSON.decodeAll(timedText)
    }

    public static func utterances(timedText: String) -> [Utterance] {
        Reconciler.fold(records(timedText: timedText))
    }

    public static func markdown(timedText: String, timeZone: TimeZone) -> String {
        TranscriptRenderer.markdown(utterances(timedText: timedText), timeZone: timeZone)
    }
}
