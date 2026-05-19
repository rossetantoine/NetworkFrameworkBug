# NetworkFrameworkBug
Minimal Swift command-line server meant to reproduce HTTP transfer throughput issues with two server implementations:  - `Network.framework` (`NWListener` + `NWConnection.send`) (default) - Legacy `CFStream` (`CFWriteStreamWrite`) (`--legacyFramework`)
