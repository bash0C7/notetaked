import Foundation
import Security
import UIKit

/// iPhone appの設定値。名前・deviceIDはUserDefaults、ペアリングコードはKeychainへ永続化する。
@MainActor
@Observable
final class MobileSettings {
    private enum DefaultsKey {
        static let ownerName = "ownerName"
        static let deviceID = "deviceID"
    }

    private static let keychainService = "io.github.bash0c7.notetake"
    private static let keychainAccount = "pairing-code"

    /// 自分の名前（Segmentの`owner`に使う）。既定"私"
    var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: DefaultsKey.ownerName) }
    }

    /// Macの設定Windowに表示される6桁のペアリングコード。Keychainに保存
    var pairingCode: String {
        didSet {
            KeychainStore.set(
                pairingCode, service: Self.keychainService, account: Self.keychainAccount)
        }
    }

    /// このデバイスの永続id（UUID、初回生成しUserDefaultsに保存）
    let deviceID: String

    /// `UIDevice.current.name`（HelloMessageの`device_name`に使う）
    let deviceName: String

    init() {
        let defaults = UserDefaults.standard
        ownerName = defaults.string(forKey: DefaultsKey.ownerName) ?? "私"

        if let existing = defaults.string(forKey: DefaultsKey.deviceID), !existing.isEmpty {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: DefaultsKey.deviceID)
            deviceID = generated
        }

        deviceName = UIDevice.current.name
        pairingCode =
            KeychainStore.get(service: Self.keychainService, account: Self.keychainAccount) ?? ""
    }
}

/// Keychainへの文字列1件の保存・読み出し（service + accountで一意）
enum KeychainStore {
    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if get(service: service, account: account) != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        } else {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
