import Darwin
import Foundation
import Network
import Security

private let maxRequestSize = 65_536
private let headerTerminator = Data("\r\n\r\n".utf8)

// Multiline literals omit their final newline; append it to complete CRLFCRLF.
private let networkFrameworkOKHeaders = """
HTTP/1.0 200 OK\r
Content-Type: application/octet-stream\r
Cache-Control: no-store\r
X-Repro-Server: nw-throughput-repro\r
Connection: close\r
\r
""" + "\n"

private let legacyFrameworkOKHeaders = """
HTTP/1.0 200 OK\r
Content-Type: application/octet-stream\r
Cache-Control: no-store\r
X-Repro-Server: cfstream-throughput-repro\r
Connection: close\r
\r
""" + "\n"

private final class StreamSession: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    private let configuration: Configuration
    private var reusablePayload: Data?
    private var requestBuffer = Data()
    private var isClosed = false

    init(connection: NWConnection, configuration: Configuration, onClose: @escaping @Sendable (UUID) -> Void) {
        self.connection = connection
        self.configuration = configuration
        self.onClose = onClose
        self.queue = DispatchQueue(label: "repro.stream.session.\(UUID().uuidString)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveRequest()
            case .failed(let error):
                print("Connection failed: \(error)")
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestSize) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("Receive error: \(error)")
                self.close()
                return
            }

            if let content, !content.isEmpty {
                self.requestBuffer.append(content)

                if self.requestBuffer.range(of: headerTerminator) != nil {
                    self.handleRequest(self.requestBuffer)
                    return
                }
            }

            if isComplete {
                self.close()
                return
            }

            self.receiveRequest()
        }
    }

    private func handleRequest(_ data: Data) {
        guard let requestText = String(data: data, encoding: .utf8),
              let firstLine = requestText.split(separator: "\n", maxSplits: 1).first
        else {
            sendAndClose("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            return
        }

        if firstLine.hasPrefix("GET ") {
            sendHeadersAndStream()
        } else {
            sendAndClose("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
        }
    }

    private var streamingContentContext: NWConnection.ContentContext {
        configuration.streamContext ? .defaultStream : .defaultMessage
    }

    private func sendHeadersAndStream() {
        let headerData = Data(networkFrameworkOKHeaders.utf8)
        connection.send(content: headerData, contentContext: streamingContentContext,
                        isComplete: !configuration.streamContext, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                print("Header send error: \(error)")
                self.close()
                return
            }
            // Seed a bounded pipeline. Each completion replenishes exactly one send.
            for _ in 0..<self.configuration.sendDepth {
                self.sendPayloadLoop()
            }
        })
    }

    private func sendPayloadLoop() {
        if isClosed {
            return
        }

        let payload: Data
        do {
            if let reusablePayload {
                payload = reusablePayload
            } else {
                payload = try makeRandomPayload(size: configuration.payloadSize)
                if configuration.reusePayload {
                    reusablePayload = payload
                }
            }
        } catch {
            print("Random generation failed: \(error)")
            close()
            return
        }

        connection.send(content: payload, contentContext: streamingContentContext,
                        isComplete: !configuration.streamContext, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                print("Payload send error: \(error)")
                self.close()
                return
            }
            self.sendPayloadLoop()
        })
    }

    private func sendAndClose(_ response: String) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        if isClosed {
            return
        }
        isClosed = true
        connection.cancel()
        onClose(id)
    }
}

private final class SessionRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "repro.session.registry")
    private var sessions: [UUID: StreamSession] = [:]

    func insert(_ session: StreamSession) {
        queue.async {
            self.sessions[session.id] = session
        }
    }

    func remove(id: UUID) {
        queue.async {
            self.sessions.removeValue(forKey: id)
        }
    }
}

private func runNetworkFrameworkServer(configuration: Configuration) {
    do {
        let port = NWEndpoint.Port(rawValue: configuration.port)!
        let tcp = NWProtocolTCP.Options()
        if configuration.noDelay { tcp.noDelay = true }
        if let mss = configuration.maximumSegmentSize { tcp.maximumSegmentSize = mss }
        if configuration.disableECN { tcp.disableECN = true }
        if configuration.noOptions { tcp.noOptions = true }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        switch configuration.serviceClass {
        case .bestEffort: parameters.serviceClass = .bestEffort
        case .responsiveData: parameters.serviceClass = .responsiveData
        case .background: parameters.serviceClass = .background
        case nil: break
        }
        let listener = try NWListener(using: parameters, on: port)
        let sessionRegistry = SessionRegistry()

        listener.newConnectionHandler = { connection in
            let endpoint = connection.endpoint
            print("Accepted NW connection from \(endpoint)")
            let session = StreamSession(connection: connection, configuration: configuration) { id in
                sessionRegistry.remove(id: id)
            }
            sessionRegistry.insert(session)
            session.start()
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Network.framework server listening on port \(configuration.port)")
            case .failed(let error):
                print("Listener failed: \(error)")
                exit(EXIT_FAILURE)
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        dispatchMain()
    } catch {
        print("Failed to start NW listener: \(error)")
        exit(EXIT_FAILURE)
    }
}

private func receiveHTTPRequest(on socketFD: Int32) -> Data? {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while request.count < maxRequestSize {
        let count = recv(socketFD, &buffer, buffer.count, 0)
        if count > 0 {
            request.append(contentsOf: buffer.prefix(count))
            if request.range(of: headerTerminator) != nil {
                return request
            }
            continue
        }

        if count == 0 {
            return nil
        }

        if errno == EINTR {
            continue
        }

        return nil
    }

    return nil
}

private func requestIsGET(_ data: Data) -> Bool {
    guard let requestText = String(data: data, encoding: .utf8),
          let firstLine = requestText.split(separator: "\n", maxSplits: 1).first
    else {
        return false
    }
    return firstLine.hasPrefix("GET ")
}

private func writeAll(_ stream: CFWriteStream, data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return true
        }

        var totalWritten = 0
        while totalWritten < data.count {
            let written = CFWriteStreamWrite(stream, base.advanced(by: totalWritten), data.count - totalWritten)
            if written <= 0 {
                return false
            }
            totalWritten += written
        }
        return true
    }
}

private func makeRandomPayload(size: Int) throws -> Data {
    var payload = Data(count: size)
    let status = payload.withUnsafeMutableBytes { bytes in
        SecRandomCopyBytes(kSecRandomDefault, size, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return payload
}

private func streamRandomBytesForever(over stream: CFWriteStream, configuration: Configuration) {
    do {
        let reusablePayload = configuration.reusePayload ? try makeRandomPayload(size: configuration.payloadSize) : nil
        while true {
            let payload = try reusablePayload ?? makeRandomPayload(size: configuration.payloadSize)
            if !writeAll(stream, data: payload) {
                return
            }
        }
    } catch {
        print("Random generation failed: \(error)")
    }
}

private func handleLegacyClient(socketFD: Int32, configuration: Configuration) {
    guard let requestData = receiveHTTPRequest(on: socketFD) else {
        _ = Darwin.close(socketFD)
        return
    }

    var unmanagedWriteStream: Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFD, nil, &unmanagedWriteStream)

    guard let writeStream = unmanagedWriteStream?.takeRetainedValue() else {
        _ = Darwin.close(socketFD)
        return
    }

    CFWriteStreamSetProperty(
        writeStream,
        CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket),
        kCFBooleanTrue
    )

    guard CFWriteStreamOpen(writeStream) else {
        CFWriteStreamClose(writeStream)
        return
    }

    defer {
        CFWriteStreamClose(writeStream)
    }

    if !requestIsGET(requestData) {
        _ = writeAll(writeStream, data: Data("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n".utf8))
        return
    }

    let headers = Data(legacyFrameworkOKHeaders.utf8)
    guard writeAll(writeStream, data: headers) else {
        return
    }

    streamRandomBytesForever(over: writeStream, configuration: configuration)
}

private func runLegacyFrameworkServer(configuration: Configuration) {
    let listenerFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listenerFD >= 0 else {
        perror("socket")
        exit(EXIT_FAILURE)
    }

    var reuseAddr: Int32 = 1
    if setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        perror("setsockopt")
        _ = Darwin.close(listenerFD)
        exit(EXIT_FAILURE)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = configuration.port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    guard bindResult == 0 else {
        perror("bind")
        _ = Darwin.close(listenerFD)
        exit(EXIT_FAILURE)
    }

    guard Darwin.listen(listenerFD, SOMAXCONN) == 0 else {
        perror("listen")
        _ = Darwin.close(listenerFD)
        exit(EXIT_FAILURE)
    }

    print("Legacy CFStream server listening on port \(configuration.port)")

    while true {
        var clientAddress = sockaddr_in()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenerFD, $0, &clientAddressLength)
            }
        }

        if clientFD < 0 {
            if errno == EINTR {
                continue
            }
            perror("accept")
            continue
        }

        DispatchQueue.global(qos: .userInitiated).async {
            handleLegacyClient(socketFD: clientFD, configuration: configuration)
        }
    }
}

private func printUsage() {
    print("""
    Usage: NetworkFrameworkThroughputRepro [options]
      --legacyFramework     Use CFStream instead of Network.framework
      --port N              Listen port (default: 9090)
      --payload-size N      Bytes per send, 1...16777216 (default: 65536)
      --reuse-payload       Generate random data once per connection and reuse it

    Network.framework only (TCP options otherwise keep system defaults):
      --no-delay            Disable Nagle's algorithm
      --mss N               Maximum TCP segment size, 216...65535 bytes
      --disable-ecn         Disable ECN negotiation
      --no-options          Enable TCP no-options mode (diagnostic)
      --send-depth N        Outstanding payload sends, 1...64 (default: 1)
      --stream-context      Send headers/body as one open stream (isComplete=false)
      --service-class NAME  best-effort, responsive-data, or background (default: system)

    Payload size times send depth must not exceed 256 MiB per connection.
    MSS and small writes do not disable TSO. No system settings are changed.
      --help, -h            Show this help
    """)
}

@main
enum NetworkFrameworkThroughputRepro {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }
        do {
            let configuration = try Configuration.parse(args)
            print(configuration.summary)
            if configuration.legacyFramework {
                runLegacyFrameworkServer(configuration: configuration)
            } else {
                runNetworkFrameworkServer(configuration: configuration)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\nUse --help for usage.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
