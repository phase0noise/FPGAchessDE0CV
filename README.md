# Advanced FPGA Chess — DE0-CV + Raspberry Pi SPI

Open **`de0cv_chess.qpf`** in Quartus Prime Lite 23.1 with Cyclone V support.
This standalone project targets **DE0-CV / 5CEBA4F23C7** and contains the current
DE10-Lite chess engine, adapted to M10K memories and the Raspberry Pi SPI link.
All build inputs and runtime files are inside this folder.

The FPGA generates and verifies legal moves, runs the recurrent spatial field,
and chooses moves with iterative alpha-beta search up to **eight plies**.
The advanced engine retains four evaluation/hash lanes, four move-queue banks,
the 4,096-entry position cache, root PVS, capture exchange analysis, quiescence,
positional evaluation, completed-iteration deadlines and protocol-5 telemetry.
The default is five plies with a ten-second budget. The Raspberry Pi hosts the
web board; the browser independently checks hardware moves and board readback.

This port uses the DE0-CV's native **50 MHz** clock, with the controller enabled
every four clocks. SPI, RAM and the engine share this clock domain. Pawn-file
evaluation uses one lane to save duplicated arithmetic; the main four
evaluation/hash lanes and four move banks remain. Think budgets and displayed
timing use the reported clock.
The DE10-Lite's 75 MHz fit measurements do not describe this port. See
[build results](docs/build-results.txt) and [validation](docs/VALIDATION.md)
for this project's own checks and physical-board status.

The qualified 50 MHz build has **+3.813 ns** worst setup margin and **+0.104 ns**
minimum hold margin across all timing corners. It uses **18,037 / 18,480 ALMs**
(98%), **128 / 308 M10Ks**, and **51 / 66 DSP blocks**. The programming image,
Pi service and browser files are included together in the portable bundle.

## Python tools

All Python code and Python tests are in [python/](python/README.md). From this
project folder on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File python/run.ps1 setup --dev
powershell -ExecutionPolicy Bypass -File python/run.ps1 test
powershell -ExecutionPolicy Bypass -File python/run.ps1 web
```

On Linux, use `bash python/run.sh setup --dev`, then
`bash python/run.sh test` or `bash python/run.sh web`. The launcher finds
the project and its local environment automatically, including after renaming
or moving the folder. Use the Pi installer below for a complete hardware setup.

## Wiring and play

Keep the SPI0/CE0 wiring from the supplied `spirpi` example:

| Raspberry Pi physical pin | DE0-CV JP1 / GPIO_0 physical pin | Signal / FPGA pin |
| --- | --- | --- |
| 23 / GPIO11 | 1 / D0 | SCLK / N16 |
| 19 / GPIO10 | 2 / D1 | MOSI / B16 |
| 21 / GPIO9 | 3 / D2 | MISO / M16 |
| 24 / GPIO8 | 4 / D3 | CE0 / C16 |
| 6 / GND | 12 or 30 / GND | Common ground |

Use 3.3 V logic and power both boards normally. Optional IRQ connects Pi pin
11 / GPIO17 to JP1 pin 5 / D4 (D17), with a 3.3 V pull-up. The service polls
and does not require IRQ. SPI defaults to 1 MHz, mode 0, eight bits, MSB first.
The driver accepts 10 kHz through 5 MHz.

1. Program `output_files/de0cv_chess.sof` using Quartus Programmer, selecting
   **5CEBA4**. `tools/program_fpga.ps1` also loads it. Reload after power loss.
2. Stop the older chess or reference service before using SPI0/CE0. Copy this
   entire `DE0CVChessAdvanced` folder to the Raspberry Pi.
3. On Raspberry Pi OS, run:

   ```bash
   bash rpi/setup.sh
   ```

   The installer needs internet once. It enables SPI, installs the Pi packages,
   creates the Wi-Fi hotspot and installs the `de0cv-chess` service. Reboot if
   SPI was just enabled. Use `bash rpi/setup.sh --no-hotspot` for existing LAN
   access, or pass `--ssid MyChess --password mychesspassword`.
4. Join **DE0CV-Chess**, password **fpgachess**, then open
   **http://10.42.0.1:8080**. Wait for **FPGA connected** and start a game.

Install the new FPGA image and the new Pi/web files together. The older port's
engine status is incompatible with the advanced service health check. The SPI
mailbox framing remains compatible with the reference register transport.

The web board includes human vs FPGA, FPGA self-play, pass-and-play, speed
round, clocks, promotion, undo, flipping, saved games and PGN export. The engine
console displays search bounds, completed depth, principal-variation prefix,
phase counters, cache activity, exchange statistics and the field heatmap.

RESET or KEY0 resets the endpoint. KEY1 evaluates the current position. LEDR9
shows engine activity, LEDR8 side to move, and LEDR7..0 field activity. HEX3..0
show the encoded selected move, HEX4 part of the legal count, HEX5 engine state.

## Build and verify

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_fpga.ps1
powershell -ExecutionPolicy Bypass -File tools/setup_test_tools.ps1
powershell -ExecutionPolicy Bypass -File tools/verify.ps1 -Browser
powershell -ExecutionPolicy Bypass -File tools/package.ps1
```

The FPGA build compiles an isolated snapshot and publishes images only after
all timing corners, clock/port coverage and input hashes pass. Failed builds
remain under `.cache/`. No build or test command programs the physical board.

Tests require Python 3.10+, Flask, python-chess, Node.js 22+ and GHDL. Setup
keeps Python packages under `python/.venv/` and GHDL under `.cache/`.
Quartus tools are discovered through `PATH` or `QUARTUS_ROOTDIR`; explicit
`-Quartus` and `-QuartusBin` overrides are also supported. `verify.ps1` accepts
`-Python`, `-Node` and `-Ghdl` paths. `-SkipSearch` runs interface, rules,
arithmetic, memory and exchange checks; the full search suite also checks
cache/reference equivalence, PVS bounds, budgets and eight-ply behavior.
`-Strength` adds independent five-ply mate proofs. `-Browser` requires Chrome
(set `CHROME` for a different executable path).

## Pi diagnostics

```bash
systemctl status de0cv-chess
journalctl -u de0cv-chess -f
curl -f http://127.0.0.1:8080/healthz
sudo systemctl stop de0cv-chess
bash python/run.sh spi --speed 100000 info
sudo systemctl start de0cv-chess
```

The service uses one Gunicorn worker and serializes full command/reply
exchanges. `CHESS_SPI_SPEED` sets the SPI frequency. Close other SPI users
before launching the diagnostic or `bash python/run.sh web` manually.
After moving an installed Pi service, rerun `bash rpi/setup.sh` so systemd
uses the current folder location.

`rtl/` contains the engine, search memories, SPI endpoint and board wrapper;
`python/` all host code, Python tools and Python tests; `rpi/` the Pi installer
and service template; `web/` the current UI; `sim/` the VHDL test benches;
`tests/` the JavaScript checks; `tools/` build/program/package scripts. Generated
compiler databases and test tools are excluded from the portable ZIP.

[Architecture](docs/ARCHITECTURE.md) · [Engine](docs/ENGINE.md) ·
[SPI transport](docs/SPI_PROTOCOL.md) · [Engine protocol](docs/ENGINE_PROTOCOL.md)
