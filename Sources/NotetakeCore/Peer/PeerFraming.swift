import Foundation

/// TCPストリームから届く断片的なbyte列を蓄積し、`\n`区切りの完成した行（UTF-8、末尾の`\n`は含まない）
/// へ切り出す純粋なbuffer。複数appendにまたがる行、1回のappendに複数行、を両方扱う。
/// 空行（連続する`\n`や先頭の`\n`）は結果から捨てる
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// `data`を蓄積し、これまでに溜まった分と合わせて完成した行をすべて返す。
    /// 未完成の末尾（次のappendへ持ち越す分）は内部に残す
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)

        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}
