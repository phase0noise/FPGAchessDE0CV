# Advanced chess engine protocol

## Engine commands

| Subcommand | Request after subcommand | Success payload |
| --- | --- | --- |
| 0 | none | 40-byte protocol-5 status |
| 1 | 64 piece bytes, turn, rights, EP | acknowledgement |
| 2 | none | start acknowledgement |
| 3 | none | stop acknowledgement |
| 4 | none | 16 attack-map bytes + 64 signed field bytes |
| 5 | none | 67-byte factual position |
| 6 | none | 80 configuration bytes |
| 7 | page 0..15 | 16 records: move:u16, score:i16 |
| 8 | 80 configuration bytes | acknowledgement |
| 9 | PRNG seed:u32 | acknowledgement |
| 10 | none | reset position acknowledgement |
| 11 | generation:u32, selected move:u16 | guarded commit acknowledgement |
| 12 | policy page 0..1 | 64 policy bytes |
| 13 | policy page 0..1, 64 bytes | upload acknowledgement |
| 14 | explanation page 0..63 | Four 18-byte records |
| 17 | count 0..8, newest-first move:u16 values | history acknowledgement |
| 18 | none | 128-byte telemetry snapshot |
| 19 | candidate page 0..15 | 16 metadata bytes aligned with command 7 |

Squares run a1=0 through h8=63. Piece types are 1 pawn, 2 knight, 3 bishop,
4 rook, 5 queen, 6 king; bit 3 marks Black. Empty=0; turn=0 White/1 Black.
Rights bits are WK/WQ/BK/BQ; EP=64 means none. Move fields are source [5:0],
destination [11:6], promotion kind [14:12]. Attack-map square bitsets alone use
little-endian 64-bit encoding.

## Status and candidate bounds

Protocol 5 status is 40 bytes:

| Bytes | Meaning |
| --- | --- |
| 0..3 | `SCF2` signature |
| 4..7 | Busy, done, check, side to move |
| 8..9 | Legal root count |
| 10..11 | Selected move |
| 12..13 | Signed selected score |
| 14 | FSM state |
| 15 | Engine protocol version 5 |
| 16..19 | Decision cycles, low 32 bits |
| 20..23 | Position generation |
| 24..27 | PRNG state |
| 28..31 | Current depth, completed depth, history count, feature byte |
| 32..35 | Decision cycles, upper 16 bits zero-extended to u32 |
| 36..39 | Actual internal frequency in Hz |

Decision cycles are captured together on command 0. Reconstruct the 48-bit
value as `low32 + upper32 * 2^32`. Divide by reported frequency for FPGA time.
The `SCF2` signature prevents an old page from treating scout bounds as exact
scores. Use the matching FPGA image, Pi service and web files. The new page also accepts old `SCF1`
protocol 3/4 status layouts (32 bytes), with their older depth limits and
50 MHz clock convention. Unknown versions are rejected.

Command 19 returns one byte per candidate in the corresponding command-7
page. Bits [7:6] encode 0 exact, 1 upper bound, 2 lower bound (3 reserved).
Bits [3:0] hold the iteration depth; bits [5:4] are reserved. Only entries
below the published legal count are meaningful. Spatial mode does not use
search-depth metadata. Completed PVS results use exact scores and losing
upper bounds; the selected move must be exact. The host rejects incomplete
bounds/depths or a bound that fails to establish the exact winner.

Command 14 retains move:u16, score:i16 and seven signed component:i16 values.
Search mode zeros the first six root preference terms and puts the searched
value in the final component. Spatial mode retains its original seven terms.

## Telemetry snapshot

Command 18 captures all 128 bytes together:

| Bytes | Meaning |
| --- | --- |
| 0..3 | Visited search nodes, including earlier iterations |
| 4..7 | Alpha-beta cutoffs |
| 8..11 | Requested normal depth, active quiescence allowance, completed depth, flags |
| 12..15 | Full-key cache matches, including ordering hints |
| 16..19 | Cache writes |
| 20..23 | Actual internal clock Hz |
| 24..27 | Maximum normal depth (8), maximum visited ply, evaluation lanes, controller divider |
| 28..31 | Cache cutoffs that directly supplied an answer |
| 32..35 | Root scout full-window re-searches |
| 36..63 | Seven phase-counter low32 values |
| 64 | Captured continuation length, 0..14 |
| 65..92 | Fourteen encoded moves, only the length prefix is valid |
| 93 | Feature bits: positional terms 0, PVS 1, root ordering 2, exchange ordering 3 |
| 94..95 | Signed king-pressure term at selected immediate-root position |
| 96..97 | Signed mobility term at selected immediate-root position |
| 98..101 | Snapshot decision cycles, low32 |
| 102..105 | Exchange analyzer calls |
| 106..109 | Controller clocks spent waiting on exchange analysis |
| 110..111 | Snapshot decision cycles, upper16 |
| 112..125 | Seven phase-counter upper16 values |
| 126 | Move-queue lanes |
| 127 | Reserved zero |

Byte 11 bits are budget expired (0) and cache enabled (1). Phase counters are
48-bit, in this order: root/field, evaluation/hash, move generation/legality,
queue selection, board restore, cache/return, control. For group `i`, combine
`u32(36+4*i)` with `u16(112+2*i) * 2^32`. Their sum equals the 48-bit snapshot
decision cycles. Each counter accounts for full controller intervals,
including native-clock waits. Exchange wait clocks are a subset of move
generation/legality, rather than an additional phase.

The continuation belongs to the last completed result. A cache cutoff can
shorten it; it is a captured prefix, not proof of a complete line at the
requested depth. The browser independently replays each move before commit.
Root king/mobility terms describe the immediate chosen board, not all leaves
in the minimax value. Old protocols use 10-/20-byte command-18 layouts; their
first fields retain their old meaning.

## Search policy

Read a full 64-byte page with command 12, preserve unrelated values, then
upload the entire page with command 13. Search controls occupy page 0:

| Index | Accepted values | Default |
| --- | --- | --- |
| 10 | 0 Spatial; 2..8 normal plies | 5 |
| 12 | Material weight 0..32; 16 = normal material | 16 |
| 13 | Placement weight 0..32; 16 = full weight | 8 |
| 15 | Quiescence enabled 0/1 | 1 |
| 40 | Think seconds 1..60; 0 unlimited | 10 |
| 41 | Capture/promotion extension allowance 0..4 | 4 |
| 42 | Position cache enabled 0/1 | 1 |
| 43 | King-pressure weight 0..32 | 16 |
| 44 | Pseudo-legal mobility weight 0..32 | 8 |

Indices 16..23 remain recurrent neighbor weights and 24..39 remain its response
LUT. Normal iterations start at two plies. Publication is atomic across the
result bank, selected value, static terms and continuation. Budget expiry
restores the last completed iteration; the first iteration always finishes.

The browser polls status around 120 ms and telemetry around 500 ms, then
reads candidate scores/metadata, the selected explanation, field snapshot and
position before commit. It checks generation and post-commit board readback.
SPI/HTTP/verification latency is outside the FPGA decision counter.
