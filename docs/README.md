# Documentation

| Document | Contents |
| --- | --- |
| [Python tools](../python/README.md) | Setup, portable launchers, commands and Python tests |
| [Architecture](ARCHITECTURE.md) | DE0-CV, Raspberry Pi and browser responsibilities |
| [Engine](ENGINE.md) | Search, evaluation, ordering and cache |
| [Advanced pipeline](ADVANCED_ENGINE.md) | Datapath, PVS and timing contract |
| [Parallel operations](PARALLEL_ARCHITECTURE.md) | Lane widths and scalar reference configurations |
| [SPI mailbox](SPI_PROTOCOL.md) | Wiring-compatible register transport and CRC |
| [Engine protocol](ENGINE_PROTOCOL.md) | Status, controls, bounds and telemetry |
| [Build results](build-results.txt) | This port's device fit and timing |
| [Machine-readable results](port-results.json) | Timing corners, profile and bitstream hash |
| [Validation](VALIDATION.md) | Checks performed and physical-board status |
| [Port maintenance](PORTING.md) | Source baseline, adaptation details and refresh guidance |

`advancement-results.json` and `advanced-strength-results.json` are retained
algorithm comparisons from the source engine. They are provenance, not
DE0-CV hardware measurements. `history/ENGINE_ROADMAP.md` is the original
design proposal. Current port validation is recorded separately.
