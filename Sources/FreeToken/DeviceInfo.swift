//
//  DeviceInfo.swift
//  FreeToken
//
//  Provides device hardware identifier and (when possible) a friendly model name.
//  The public API only exposes read-only values through FreeToken.
//
//  NOTE: Apple does not provide an official public API for marketing names.
//  We include a lightweight curated mapping for common iPhone/iPad identifiers.
//  Unknown identifiers fall back to the raw model identifier.
//

import Foundation

internal struct DeviceModelProvider {
    let modelIdentifier: String
    let modelName: String

    init() {
        let identifier = DeviceModelProvider.detectModelIdentifier()
        self.modelIdentifier = identifier
        self.modelName = DeviceModelProvider.friendlyName(for: identifier)
    }

    private static func detectModelIdentifier() -> String {
#if os(iOS)
        // uname() to fetch machine (e.g., iPhone16,1)
        var uts = utsname()
        uname(&uts)
        let mirror = Mirror(reflecting: uts.machine)
        let identifier = mirror.children.reduce("") { acc, elem in
            guard let v = elem.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
        return identifier.isEmpty ? "Unknown" : identifier
#elseif os(macOS)
        // sysctl hw.model (e.g., Mac15,7)
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        if result == 0 {
            let str: String = buffer.withUnsafeBufferPointer { ptr in
                // Determine length up to first null terminator
                let count = ptr.firstIndex(of: 0) ?? ptr.count
                // Reinterpret as unsigned bytes for decoding
                return ptr.withMemoryRebound(to: UInt8.self) { uptr in
                    return String(decoding: uptr[..<count], as: UTF8.self)
                }
            }
            return str.isEmpty ? "Unknown" : str
        }
        return "Unknown"
#else
        return "Unknown"
#endif
    }

    private static func friendlyName(for identifier: String) -> String {
        // Return raw identifier; server can map to marketing name if desired.
        return identifier
    }
}
