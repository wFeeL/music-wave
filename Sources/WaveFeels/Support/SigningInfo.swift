import Foundation
import Security

/// Чем подписан запущенный процесс: общее имя сертификата, «ad-hoc» или «не подписано».
enum SigningInfo {
    /// Флаг `kSecCodeSignatureAdhoc` в `kSecCodeInfoFlags`.
    private static let adhocFlag: UInt32 = 0x0002

    static func current() -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return unsigned
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return unsigned
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return unsigned
        }

        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) {
            return summary as String
        }
        let signatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        // Подписанный код без сертификатов тоже ad-hoc, даже если флаги не пришли.
        if signatureFlags & adhocFlag != 0 || info[kSecCodeInfoIdentifier as String] != nil {
            return "ad-hoc"
        }
        return unsigned
    }

    private static let unsigned = "не подписано"
}
