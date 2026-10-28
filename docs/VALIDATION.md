# DE0-CV port validation

Repository cleanup was verified on 2026-10-28 after consolidating every Python
source under `python/`. The current `tools/verify.ps1 -SkipSearch -Browser`
run passed: 29 Python tests (one additional Linux-only test skipped on Windows),
147 independent browser and production VHDL rule positions, arithmetic,
memory, exchange, SPI target, 1/5 MHz board-wrapper simulation, browser
protocol checks, and desktop/mobile browser smoke checks. Relocation tests
copy the sources into a renamed folder containing spaces and exercise the
PowerShell launcher, fixtures, web assets and systemd unit rendering from an
unrelated working directory.

The existing qualified SOF is retained unchanged, with SHA-256
`9d231ae8aa7685c4b3960887781fa52f28bbbcd605c7a53d31fe4a9c368341af`.
FPGA compilation and the extended search/strength suite were not repeated
for this file-layout change. The timing and search results below remain the
2026-10-25 qualification record.

Functional validation and all-corner FPGA timing qualification completed
on 2026-10-25 at the native 50 MHz clock. The physical FPGA and Raspberry Pi
have not been programmed or tested by this porting session.

| Check | Result |
| --- | --- |
| Self-contained Quartus inputs | Nine VHDL sources, one SDC, 61 unique DE0-CV pin assignments |
| Engine provenance | All six current engine modules match the baseline after M10K hint/comment and line-ending changes |
| Pi driver and HTTP service | 24 tests passed, including CRC retries, paging, serialization, reconnect, protocol-5 health and rejection of old status frames |
| Browser rules | Matched python-chess on 147 positions; perft, SAN, resulting FEN, metadata, checks, repetition, en passant and undo passed |
| Browser/engine verification | Version/depth/time controls, telemetry, bounds, continuation, legal-set comparison, commit guards, cancellation and disconnected hardware passed |
| Production VHDL rules | Complete legal sets and attack maps matched the same 147 independent positions |
| Arithmetic and memory | Exact reciprocal quotient and limits; all search RAM levels, cache/history endpoints, initial state and position-key metadata passed |
| Capture exchange | Exchange chains, x-rays, colors, en passant, promotion, king recapture and cancellation passed |
| SPI target | Reference target regression passed |
| Physical SPI pin simulation | Passed 1 MHz and 5 MHz mode-0 transfers through the board wrapper, including SCF2 status, 128-byte telemetry, eight-ply policy and think-budget upload/readback, CRC, retry, partial-frame rejection, complete opening legal set, guarded commit, IRQ and MISO release |
| Spatial model equivalence | Simulation accelerator matched production wired attack/reach planes for all 64 source squares in all 147 positions |
| Tactical search | Ten independent three-ply tactical fixtures passed |
| Cache and destination scanning | All 18 fixture scores and selected moves matched the reference configurations |
| Parallel datapath | Scores, moves, node counts and cache results matched; all 237 special-rule candidate scores matched between scalar and parallel configurations |
| Deadline publication | One-second scaled-clock budgets retained completed depth two/three results and permitted a valid guarded commit |
| Eight-ply behavior | Depth-eight draw fixtures and a live depth-eight stack traversal passed |
| PVS and lane comparison | 18 exact lane scores, 18 PVS bounds, 42 legal continuation prefixes, and special-rule bounds matched |
| Desktop/mobile browser | Gestures, themes, promotions, captures, console, offline pass-and-play, self-play, stop/resume, persistence and Spatial speed-round timeout passed against an explicitly simulated HTTP endpoint |
| Packaging inputs | Pi shell line endings, local documentation links and DE0-CV UI wording checked |
| Deployed profile | Native 50 MHz, one pawn-file lane; 1/5 MHz SPI pin regressions and targeted three-ply search fixtures passed |
| Routed FPGA timing | All corners passed at 50 MHz; worst setup +3.813 ns, minimum hold +0.104 ns; zero unconstrained clocks or ports |

The full search checks were run with `tools/verify_search.ps1`; base checks
with `tools/verify.ps1 -SkipSearch`. The final SPI bench additionally checks
the 50 MHz reported clock and eight-ply policy/budget upload at 1 MHz and
5 MHz. The main search suite also compares the existing single-pawn-lane
configuration with two lanes; a final deployed-profile search check is run
with `PAWN_LANES=1` and `TEST_CLOCK_HZ=50000000`. Browser smoke
checks use a test endpoint; they do not emulate the FPGA's search strength.

Test environment: Python 3.13.2, python-chess 1.999/chess 1.11.2, Flask 3.1.3,
GHDL 6.0.0, Node.js 22.18.0 via the installed Electron executable, and Chrome.
The optional `-Strength` five-ply proof suite was not repeated for this port;
the source engine's strength record remains labeled as source provenance.

The FPGA configuration uses Quartus area optimization for the 5CEBA4's logic
capacity. This changes mapping settings while retaining the engine RTL and
its four-lane datapath. Routed resource/timing results are recorded in
[build-results.txt](build-results.txt) and [port-results.json](port-results.json).

Remaining physical checks: load the new SOF, connect the documented 3.3 V SPI
wiring, install the matching Pi service, confirm `/healthz`, and play through
SPI on the actual boards. The 1 MHz default and optional higher bus speeds
need electrical validation with the user's wiring. Hotspot/systemd installation
was inspected but cannot be exercised on this Windows host.
