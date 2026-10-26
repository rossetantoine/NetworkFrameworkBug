import Foundation

struct Configuration: Sendable {
    enum ServiceClass: String, Sendable {
        case bestEffort = "best-effort"
        case responsiveData = "responsive-data"
        case background
    }

    var streamContext = false
    var serviceClass: ServiceClass?
    var legacyFramework = false
    var port: UInt16 = 9090
    var payloadSize = 64 * 1024
    var sendDepth = 1
    var reusePayload = false
    var noDelay = false
    var maximumSegmentSize: Int?
    var disableECN = false
    var noOptions = false

    struct ArgumentError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ arguments: [String]) throws -> Configuration {
        var configuration = Configuration()
        var index = 0
        var networkOnlyOptions = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            func integer(in range: ClosedRange<Int>) throws -> Int {
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]), range.contains(value) else {
                    throw ArgumentError(description: "\(option) requires an integer in \(range.lowerBound)...\(range.upperBound)")
                }
                index += 1
                return value
            }
            switch option {
            case "--legacyFramework": configuration.legacyFramework = true
            case "--port": configuration.port = UInt16(try integer(in: 1...65535))
            case "--payload-size": configuration.payloadSize = try integer(in: 1...(16 * 1024 * 1024))
            case "--reuse-payload": configuration.reusePayload = true
            case "--send-depth":
                configuration.sendDepth = try integer(in: 1...64)
                networkOnlyOptions.insert(option)
            case "--mss":
                configuration.maximumSegmentSize = try integer(in: 216...65535)
                networkOnlyOptions.insert(option)
            case "--stream-context":
                configuration.streamContext = true
                networkOnlyOptions.insert(option)
            case "--service-class":
                guard index + 1 < arguments.count,
                      let value = ServiceClass(rawValue: arguments[index + 1]) else {
                    throw ArgumentError(description: "--service-class requires best-effort, responsive-data, or background")
                }
                configuration.serviceClass = value
                index += 1
                networkOnlyOptions.insert(option)
            case "--no-delay":
                configuration.noDelay = true
                networkOnlyOptions.insert(option)
            case "--disable-ecn":
                configuration.disableECN = true
                networkOnlyOptions.insert(option)
            case "--no-options":
                configuration.noOptions = true
                networkOnlyOptions.insert(option)
            default: throw ArgumentError(description: "Unknown argument: \(option)")
            }
            index += 1
        }
        if configuration.legacyFramework && !networkOnlyOptions.isEmpty {
            throw ArgumentError(description: "Network.framework-only options cannot be used with --legacyFramework: \(networkOnlyOptions.sorted().joined(separator: ", "))")
        }
        guard configuration.payloadSize * configuration.sendDepth <= 256 * 1024 * 1024 else {
            throw ArgumentError(description: "--payload-size multiplied by --send-depth must not exceed 256 MiB")
        }
        return configuration
    }

    var summary: String {
        "mode=\(legacyFramework ? "CFStream" : "Network.framework") port=\(port) payload-size=\(payloadSize) send-depth=\(sendDepth) reuse-payload=\(reusePayload) no-delay=\(noDelay ? "true" : "default") mss=\(maximumSegmentSize.map(String.init) ?? "default") disable-ecn=\(disableECN ? "true" : "default") no-options=\(noOptions ? "true" : "default") context=\(streamContext ? "stream" : "message") service-class=\(serviceClass?.rawValue ?? "default")"
    }
}
