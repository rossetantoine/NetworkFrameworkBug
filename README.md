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
swift build -c release --scratch-path build-artifacts/swift-build
```

### Run (Network.framework)
```bash
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
```

### Run (Legacy CFStream)
```bash
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --legacyFramework
```

### Run (Network.framework) with TSO disabled
```bash
sudo sysctl net.inet.tcp.tso=0
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
```

### Quick Client Check
```bash
curl http://<server-ip>:9090/ -o /dev/null
```

### CLI experiments

Run `./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --help`
for all options. With no arguments, the original defaults are preserved: port
9090, fresh random 64 KiB payloads, one outstanding send, and default TCP options.
The server prints its configuration at startup. Restart it between experiments.
Both response header constants explicitly append their final newline so that the
HTTP header terminator is a complete CRLFCRLF sequence.

| Option | Values / default | Applies to |
| --- | --- | --- |
| `--port N` | 1–65535; default 9090 | Both modes |
| `--payload-size N` | Bytes, 1–16777216; default 65536 | Both modes |
| `--reuse-payload` | Generate one random payload per connection and reuse it | Both modes |
| `--no-delay` | Set TCP no-delay to true | Network.framework |
| `--mss N` | 216–65535 bytes; omitted means system default | Network.framework |
| `--send-depth N` | 1–64 outstanding body sends; default 1 | Network.framework |
| `--disable-ecn` | Disable ECN negotiation | Network.framework |
| `--no-options` | Enable TCP no-options mode; broad diagnostic | Network.framework |
| `--stream-context` | Send headers and body in `.defaultStream` with `isComplete: false` | Network.framework |
| `--service-class NAME` | `best-effort`, `responsive-data`, or `background`; omitted means system default | Network.framework |

Network.framework-only flags are rejected in legacy mode rather than silently
ignored. Payload size times send depth is limited to 256 MiB per connection.
The send pipeline is seeded with N writes and replenishes one write per completion.
TCP flags omitted from the command line retain system defaults. MSS values are
requests to the networking stack; actual segment sizes also depend on the path
and peer. Neither MSS nor small application writes guarantee TSO is disabled.
The CLI does not change sysctls or interface settings.

Suggested sequence, with TSO enabled and one change per run:

```bash
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --no-delay
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --mss 1400
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --send-depth 4
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --disable-ecn
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --payload-size 1400
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --no-options
```

Also compare MSS 1440/1200, send depth 2/8, and payload size 4096/16384/524288.
For payload reuse, compare both server modes with `--reuse-payload` enabled.
Use the same explicit IPv4 server address because the legacy listener is IPv4-only.

On a separate LAN client, repeat each run three times:

```bash
curl --max-time 30 --output /dev/null --silent --show-error \
  --write-out 'bytes=%{size_download} speed_Bps=%{speed_download} total=%{time_total}\n' \
  http://<server-ip>:9090/
```

Curl exit code 28 is expected: the response is indefinite and the client stops it
after 30 seconds. Localhost is useful for smoke checks but does not exercise the
reported physical-interface/TSO failure.

### Stream context and scheduling experiments

Keep TSO enabled and run these separately, restarting the server each time:

```bash
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --stream-context
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --service-class best-effort
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --service-class responsive-data
./build-artifacts/swift-build/release/NetworkFrameworkThroughputRepro --service-class background
```

Use the same remote 30-second curl measurement above. Stream context keeps both
headers and all body writes in the same open TCP stream context; it does not send
a FIN after each payload. The default message context also does not send a FIN
per payload. Both modes remain indefinite until the client disconnects.
Service class changes scheduling/traffic priority and is a diagnostic experiment,
not a confirmed offload workaround. Test it independently before combining flags.

### Open in Xcode
Open `Package.swift` in Xcode.

# Results

##Test A : Network Framework
```bash
Server side: ./NetworkFrameworkThroughputRepro
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 7682k    0 7682k    0     0  1011k      0 --:--:--  0:00:07 --:--:--  989k
```
--> 989 kB/s : very low throughput, not saturating the 1 Gbps link (theoretical max ~125 MB/s)

##Test B : CFStream (legacy framework)
```bash
Server side: ./NetworkFrameworkThroughputRepro --legacyFramework
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  905M    0  905M    0     0   103M      0 --:--:--  0:00:08 --:--:--  106M
```
--> 106 MB/s : much higher throughput, saturating the 1 Gbps link (theoretical max ~125 MB/s)


##Test C : Network Framework with TSO disabled
```bash
Server side: sudo sysctl net.inet.tcp.tso=0, then ./NetworkFrameworkThroughputRepro
Client side:
admin@iMac ~ % curl http://10.17.18.119:9090/ -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  623M    0  623M    0     0   101M      0 --:--:--  0:00:06 --:--:--  105M
```
--> 105 MB/s : much higher throughput, saturating the 1 Gbps link (theoretical max ~125 MB/s)
