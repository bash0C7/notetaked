import Foundation

/// `<prefix>.context.md`。`signals.jsonl`のバケットを時間帯ごとの要約として並べる
public enum ContextRenderer {
    public static func url(prefix: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(prefix).context.md")
    }

    public static func markdown(_ document: SignalsDocument, timeZone: TimeZone) -> String {
        let dayTime = formatter("yyyy-MM-dd HH:mm", timeZone: timeZone)
        let clock = formatter("HH:mm", timeZone: timeZone)
        var lines = [
            "# \(dayTime.string(from: date(document.header.start)))〜\(dayTime.string(from: date(document.header.end)))の体の状態と地点",
            "",
            "心拍はヘルスケアに記録された値（主にWatchのパッシブ計測）で、数分〜数十分おきの粒度。HRVは数時間に1回程度。",
            "",
        ]
        for bucket in document.buckets {
            var line = "- \(clock.string(from: date(bucket.start)))〜\(clock.string(from: date(bucket.end)))"
            if let place = bucket.place {
                line += "　地点: \(place)"
            }
            if let hr = bucket.hr {
                if let min = hr.min, let max = hr.max {
                    line += "　心拍: 平均\(whole(hr.mean))（\(whole(min))〜\(whole(max))、\(hr.n)件）"
                } else {
                    line += "　心拍: 平均\(whole(hr.mean))（\(hr.n)件）"
                }
            } else {
                line += "　心拍: データなし"
            }
            if let hrv = bucket.hrv {
                line += "　HRV: \(whole(hrv.meanSDNNMS))ms（\(hrv.n)件）"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
