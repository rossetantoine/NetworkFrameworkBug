import Testing
@testable import NetworkFrameworkThroughputRepro

@Test func defaultsPreserveOriginalRepro() throws {
    let configuration = try Configuration.parse([])
    #expect(configuration.port == 9090)
    #expect(configuration.payloadSize == 65536)
    #expect(configuration.sendDepth == 1)
    #expect(!configuration.reusePayload)
    #expect(!configuration.legacyFramework)
    #expect(!configuration.noDelay)
    #expect(configuration.maximumSegmentSize == nil)
    #expect(!configuration.disableECN)
    #expect(!configuration.noOptions)
    #expect(!configuration.streamContext)
    #expect(configuration.serviceClass == nil)
}

@Test func parsesExperiments() throws {
    let configuration = try Configuration.parse([
        "--port", "9091", "--payload-size", "16384", "--send-depth", "4",
        "--reuse-payload", "--no-delay", "--mss", "1400", "--disable-ecn", "--no-options"
    ])
    #expect(configuration.port == 9091)
    #expect(configuration.payloadSize == 16384)
    #expect(configuration.sendDepth == 4)
    #expect(configuration.reusePayload)
    #expect(configuration.noDelay)
    #expect(configuration.maximumSegmentSize == 1400)
    #expect(configuration.disableECN)
    #expect(configuration.noOptions)
}

@Test func legacyAcceptsSharedOptions() throws {
    let configuration = try Configuration.parse([
        "--legacyFramework", "--payload-size", "1400", "--reuse-payload", "--port", "9092"
    ])
    #expect(configuration.legacyFramework)
    #expect(configuration.payloadSize == 1400)
    #expect(configuration.reusePayload)
    #expect(configuration.port == 9092)
}

@Test(arguments: [
    ["--unknown"], ["--mss"], ["--mss", "abc"], ["--mss", "215"],
    ["--mss", "65536"], ["--port", "0"], ["--port", "65536"],
    ["--payload-size", "-1"], ["--payload-size", "0"],
    ["--payload-size", "16777217"], ["--send-depth", "0"], ["--send-depth", "65"],
    ["--payload-size", "16777216", "--send-depth", "64"],
    ["--legacyFramework", "--no-delay"], ["--no-options", "--legacyFramework"],
    ["--legacyFramework", "--mss", "1400"], ["--legacyFramework", "--disable-ecn"],
    ["--legacyFramework", "--send-depth", "1"],
    ["--service-class"], ["--service-class", "invalid"],
    ["--legacyFramework", "--stream-context"],
    ["--legacyFramework", "--service-class", "background"]
])
func rejectsInvalidArguments(arguments: [String]) {
    #expect(throws: Configuration.ArgumentError.self) {
        try Configuration.parse(arguments)
    }
}

@Test(arguments: ["best-effort", "responsive-data", "background"])
func parsesStreamAndServiceClass(serviceClass: String) throws {
    let configuration = try Configuration.parse([
        "--stream-context", "--service-class", serviceClass
    ])
    #expect(configuration.streamContext)
    #expect(configuration.serviceClass?.rawValue == serviceClass)
}
