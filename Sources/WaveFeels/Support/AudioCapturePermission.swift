import Darwin
import Foundation

/// Доступ «Запись системного аудио» через системную библиотеку TCC (загружается через `dlopen`).
/// Если библиотеки или функций нет, статус неизвестен.
nonisolated enum AudioCapturePermission {
    enum Status: Sendable, Equatable {
        case authorized, denied, unknown
    }

    private static let libraryPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    private static let service = "kTCCServiceAudioCapture"

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (
        CFString,
        CFDictionary?,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    /// `TCCAccessPreflight`: 0 разрешено, 1 запрещено, иначе неизвестно.
    static func preflight() -> Status {
        guard let preflight = symbol("TCCAccessPreflight", as: PreflightFunction.self) else {
            return .unknown
        }
        switch preflight(service as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// `TCCAccessRequest`: показывает системный запрос. `completion` вызывается на любом потоке.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let request = symbol("TCCAccessRequest", as: RequestFunction.self) else {
            completion(false)
            return
        }
        request(service as CFString, nil) { granted in
            completion(granted)
        }
    }

    /// Дескриптор библиотеки как число: `static let` инициализируется один раз и потокобезопасно,
    /// а `Int`, в отличие от указателя, `Sendable`. Библиотека не выгружается.
    private static let libraryHandle = Int(bitPattern: dlopen(libraryPath, RTLD_NOW))

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = UnsafeMutableRawPointer(bitPattern: libraryHandle),
              let pointer = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }
}
