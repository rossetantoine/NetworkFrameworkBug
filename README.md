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

## Expected Result
Throughput with Network.framework should be in the same range as CFStream for equivalent workload and environment (or at least not regress by an order of magnitude).

## Actual Result
Network.framework path shows severe throughput degradation on macOS 26 (M4), independent of application chunk size (64 KB or 512 KB), while CFStream path is fast.

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
cd NetworkFrameworkBug
swift build -c release --build-path NetworkFrameworkBug/build-artifacts/swift-build
```

### Run (Network.framework)
```bash
./NetworkFrameworkBug/build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
```

### Run (Legacy CFStream)
```bash
./NetworkFrameworkBug/build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --legacyFramework
```

### Run (Network.framework)
```bash
sudo sysctl net.inet.tcp.tso=0
./NetworkFrameworkBug/build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
```

### Quick Client Check
```bash
curl http://<server-ip>:9090/ -o /dev/null
```

### Open in Xcode
Open `Package.swift` in Xcode.

# Results

##Test A : Network Framework
Server side: ./NetworkFrameworkThroughputRepro
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 7682k    0 7682k    0     0  1011k      0 --:--:--  0:00:07 --:--:--  989k

--> 989 kB/s : very low throughput, not saturating the 1 Gbps link (theoretical max ~125 MB/s)

##Test B : CFStream (legacy framework)
Server side: ./NetworkFrameworkThroughputRepro --legacyFramework
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null --legacyframework                                                                               
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  905M    0  905M    0     0   103M      0 --:--:--  0:00:08 --:--:--  106M

--> 106 MB/s : much higher throughput, saturating the 1 Gbps link (theoretical max ~125 MB/s)


##Test C : Network Framework with TSO disabled
Server side: sudo sysctl net.inet.tcp.tso=0, then ./NetworkFrameworkThroughputRepro
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  623M    0  623M    0     0   101M      0 --:--:--  0:00:06 --:--:--  105M

--> 105 MB/s : much higher throughput, saturating the 1 Gbps link (theoretical max ~125 MB/s)
