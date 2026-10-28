# Port maintenance

The engine baseline is DE10LiteChess commit
`dd8bf16811d43ac13b5efc5dd1970b9f18174527`. The exact source and port hashes
are recorded in [port-provenance.json](port-provenance.json).

All six engine modules come from that current project: `chess_pkg`,
`chess_cell_memory`, `chess_spatial`, `chess_search_memory`, `chess_see` and
`chess_engine`. Their chess logic is unchanged. Only M9K attributes become
M10K, device/transport comments change, and line endings are normalized.
The web UI and the full engine regression suite also come from that baseline.

The existing DE0CVChess project supplies the board wrapper, DE0-CV pins,
SPI target, mailbox, Raspberry Pi service and installer. The new mailbox
forwards CLOCK_HZ; the Pi diagnostic/health endpoint accepts the new SCF2
status. The current engine's complete timing-enable constraints replace the
older port's shorter bank list. UART, Pico firmware and MAX 10 configuration
assignments are excluded from this project. The clock is the native 50 MHz. SPI, memories and the engine share that domain;
the SPI bus defaults to 1 MHz and the driver permits up to 5 MHz.
The bridge selects the existing `PAWN_LANES=1` option to reduce duplicated
arithmetic while retaining four evaluation/hash and move-queue lanes.
The QSF selects `OPTIMIZATION_MODE "AGGRESSIVE AREA"` so Quartus maps the full
engine to the 5CEBA4's logic capacity. This setting is part of the port's
qualified build configuration.

Cyclone V also gives some packed DSP data registers names such as
`Mult0~245` instead of their RTL `eval_*` names. All variable multipliers in
the main engine process execute under the common `phase=0` enable. The SDC
includes these direct DSP data nodes in that four-cycle bank while excluding
the nested native `ENA_DFF` helper registers and the separate SEE instance.
Their native control paths retain single-cycle checks.

For another engine refresh, copy all six engine modules and their matching
web files together, reapply M10K hints and DE0-CV/Pi wording, and review command
sizes, status/telemetry versions and the enabled-register lists in the SDC.
Keep the SPI transport and board pins unless the hardware wiring changes.
Run `tools/verify.ps1`, build the Cyclone V image, then package the matching
source, Pi service, UI and SOF with `tools/package.ps1`.
