# Network.framework Throughput Regression Repro (macOS 26 / Apple Silicon M4)

## Product / Component
macOS -> Networking -> Network.framework (TCP/TLS performance)

## Type
Performance

## Summary
On macOS 26, server-side file transfer throughput is dramatically lower when using Network.framework (`nw_listener` + `nw_connection_send`) versus legacy CFStream (`CFWriteStreamWrite`) in the same application and environment.

Issue reproduces with both 64 KB and 512 KB application chunk sizes on Apple Silicon M4 systems (Mac mini M4 Pro and Mac Studio M4 Max).

The issue does not reproduce on Apple Silicon M1 running the same macOS version.

The legacy path (CFStream) does not show this slowdown on any tested computers.

## Environment
- OS: macOS 26.4.1
- Hardware where issue reproduces: Apple Silicon M4
  - Mac mini M4 Pro
  - Mac Studio M4 Max
- Hardware where issue does not reproduce: Apple Silicon M1 (same OS)
- Network setup: client and server on same LAN
- Note: not reproducible on same machine via `localhost`

## Repro Steps
1. Start server implementation A (legacy CFStream / `CFWriteStreamWrite`).
2. From a client machine, download a static binary and measure throughput:
   ```bash
   curl -L -k -o /dev/null http://<server-ip>:9090/random_250mb.bin
   ```
3. Start server implementation B (Network.framework / `nw_listener` + `nw_connection_send`) serving the same file/data.
4. From a client machine, download and measure throughput:
   ```bash
   curl -L -k -o /dev/null https://<server-ip>:8080/public/random_250mb.bin
   ```
5. Repeat with application write chunk sizes set to:
   - 64 KB
   - 512 KB

## Expected Result
Throughput with Network.framework should be in the same range as CFStream for equivalent workload and environment (or at least not regress by an order of magnitude).

## Actual Result
Network.framework path shows severe throughput degradation on macOS 26 (M4), independent of application chunk size (64 KB or 512 KB), while CFStream path is fast.

## Measured Example
- Legacy (CFStream path): ~`15.1 MB/s`
- Network.framework path: ~`340 KB/s`

## Notes
- Chunk-size tuning did not resolve the issue.
- Same application logic, same content, same machine/network.

## Regression
Appears specific to macOS 26 behavior on M4.

## Workaround
```bash
sudo sysctl net.inet.tcp.tso=0
```

After this change, throughput returns to normal levels.

---

## This Repository: Minimal Repro Project
This Swift command-line project provides two server modes for A/B comparison in one binary:

- Default mode: Network.framework (`NWListener` + `NWConnection.send`)
- `--legacyFramework` mode: legacy CFStream (`CFWriteStreamWrite`)

Behavior in both modes:
- listens on port `9090`
- accepts HTTP `GET`
- streams random bytes indefinitely

### Build
```bash
cd /Users/admin/NetworkFrameworkBug
swift build -c release --build-path /Users/admin/NetworkFrameworkBug/build-artifacts/swift-build
```

### Run (Network.framework)
```bash
/Users/admin/NetworkFrameworkBug/build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
```

### Run (Legacy CFStream)
```bash
/Users/admin/NetworkFrameworkBug/build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --legacyFramework
```

### Quick Client Check
```bash
curl http://<server-ip>:9090/ -o /dev/null
```

### Open in Xcode
Open `Package.swift` in Xcode.
