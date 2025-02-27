//
//  Shared.swift
//  EduVPN
//
//  Copyright © 2021 The Commons Conservancy. All rights reserved.
//

import Foundation
import NetworkExtension

enum TunnelMessageCode: UInt8 {
    case getTransferredByteCount = 0 // Returns TransferredByteCount as Data
    case getNetworkAddresses = 1 // Returns [String] as JSON
    case getLog = 2 // Returns UTF-8 string

    var data: Data { Data([rawValue]) }
}

struct TransferredByteCount: Codable {
    let inbound: UInt64
    let outbound: UInt64

    var data: Data {
        var serialized = Data()
        for value in [inbound, outbound] {
            var localValue = value
            let buffer = withUnsafePointer(to: &localValue) {
                return UnsafeBufferPointer(start: $0, count: 1)
            }
            serialized.append(buffer)
        }
        return serialized
    }

    init(from data: Data) {
        self = data.withUnsafeBytes { pointer -> TransferredByteCount in
            // Data is 16 bytes: low 8 = received, high 8 = sent.
            let inbound = pointer.load(fromByteOffset: 0, as: UInt64.self)
            let outbound = pointer.load(fromByteOffset: 8, as: UInt64.self)
            return TransferredByteCount(inbound: inbound, outbound: outbound)
        }
    }

    init(inbound: UInt64, outbound: UInt64) {
        self.inbound = inbound
        self.outbound = outbound
    }
}

enum WireGuardProviderConfigurationKeys: String {
    case wireGuardConfig
    case appGroup
}

struct StartTunnelOptions {
    static let isStartedByAppKey = "isStartedByApp"

    private(set) var options: [String: Any]

    var isStartedByApp: Bool {
        get {
            if let boolNumber = options[Self.isStartedByAppKey] as? NSNumber {
                return boolNumber.boolValue
            }
            return false
        }
        set(value) {
            let boolNumber = NSNumber(value: value)
            options[Self.isStartedByAppKey] = boolNumber
        }
    }

    init(options: [String: Any]) {
        self.options = options
    }

    init(isStartedByApp: Bool) {
        self.options = [Self.isStartedByAppKey: NSNumber(value: isStartedByApp)]
    }
}

#if os(macOS)
extension NETunnelProviderProtocol {
    struct SharedKeys {
        // If set, the tunnel connects only when triggered from the app.
        // When TunnelKit tries to reconnect, or when the OS triggers a
        // connection because of on-demand, the connection fails early.
        static let shouldPreventAutomaticConnectionsKey = "shouldPreventAutomaticConnections"
    }

    var shouldPreventAutomaticConnections: Bool {
        get {
            if let boolNumber = providerConfiguration?[SharedKeys.shouldPreventAutomaticConnectionsKey] as? NSNumber {
                return boolNumber.boolValue
            }
            return false
        }
        set(value) {
            let boolNumber = NSNumber(value: value)
            providerConfiguration?[SharedKeys.shouldPreventAutomaticConnectionsKey] = boolNumber
        }
    }
}
#endif
