# DE0-CV chess SPI mailbox

The electrical wiring and SPI target are copied from `spirpi`: SPI0 / CE0,
mode 0, eight bits, MSB first. Each `spidev.xfer2()` holds CS low for one frame:

- Write: `00 address data...`
- Read: `80 address dummy...`; returned data begins in the first dummy byte.
- The eight-bit address increments after each data byte. Keep each frame
  inside the 256-byte address space.
- MISO is tri-stated when CS is high. The optional active-low IRQ is open-drain.

Default clock is 1 MHz; the Pi driver permits 10 kHz..5 MHz. All logic uses the
FPGA's native 50 MHz clock. SPI inputs enter the reference's two-stage synchronizers.
The chess register map is distinct from the original dashboard map; old images
are rejected by identity before any chess request is written.

## Registers

All chess metadata integers are **big endian**, including the sequence and CRC.

| Address | Access | Meaning |
| --- | --- | --- |
| 00 | R | Signature `C5` |
| 01 | R | Chess mailbox interface version `03` |
| 02 | R | Capabilities `07`: CRC, sequence, cached retry |
| 03 | R | bit 0 transport busy; bit 1 reply ready; bit 2 reply status nonzero |
| 04..07 | R | Application identity `CHS3` |
| 08..0B | R | Completed reply sequence, u32 |
| 0C | R | Reply status |
| 0D..0E | R | Reply payload length, u16 (0..1024) |
| 0F | W | `A5`: submit staged request; `5A`: acknowledge/release IRQ |
| 10..13 | R/W | Request sequence, u32 |
| 14 | R/W | Request payload length, 1..81; writing clears the byte-received bitmap |
| 15..16 | R/W | Request CRC, u16 |
| 18 | R/W | Response window page, 0..7 |
| 1A..1B | R | Response CRC, u16 |
| 20..70 | R/W | Staged command payload, up to 81 bytes |
| 80..FF | R | 128-byte response window, selected by page 18 |

Transport busy covers validation, command acknowledgement and reply capture;
it does not remain set while the independent chess evaluator thinks. Engine
status subcommand 0 reports that activity. Reply RAM remains stable until the
next submitted request. Acknowledgement clears ready/IRQ and retains cached
data for an identical retry.

Status 0=success; 1=malformed engine request; 2=unsupported; 3=range/busy/stale
commit; 4=engine command acknowledgement timeout; 5=incomplete payload or request
CRC failure; 6=sequence reused with different request data. The engine's maximum
acknowledgement wait is 100 ms. Search itself runs asynchronously.

## CRC and command exchange

CRC-16/CCITT-FALSE: polynomial 1021, initial FFFF, no reflection or final XOR.
The standard `123456789` check result is 29B1.

- Request CRC input: `01 sequence:u32 length:u8 command_payload`
- Reply CRC input: `01 sequence:u32 status:u8 length:u16 reply_payload`

1. Confirm identity and wait for transport busy=0.
2. Write 10..16 (sequence, length, CRC), then payload at 20.
3. Write `A5` to 0F in its own complete SPI frame.
4. Poll flags until busy=0 and ready=1.
5. Read 08..0E and verify the sequence/length. Read payload via the window,
   then check the reply CRC at 1A..1B.
6. Write `5A` to 0F.

Every requested payload byte must have been written since the length field.
The submit frame must end without a framing error; a partial execute frame is
discarded. Hardware freezes and validates the request before dispatching it.
The same sequence/length/CRC returns the latest cached reply. A different valid
request uses a new sequence. Requests following a lost/corrupt reply retry the
same sequence; the original engine's 80-bit mutation token adds replay protection
for its most recent mutation. One controller and one command exchange are active
at a time. The Pi serializes that whole exchange, including all response pages.

## HTTP bridge and engine payloads

`POST /api/command` accepts 1..81 command bytes encoded as ASCII hexadecimal.
It returns JSON with numeric `status` and hexadecimal `payload`. Hardware
failures return HTTP 503. `GET /api/info` describes the transport; `/healthz`
requires the current 40-byte `SCF2` engine status with protocol version 5 and
a valid reported clock. The older port's `SCF1` status is incompatible.

The mailbox identity and CRC framing remain version 3 (`CHS3`). They describe
the transport, not the version of the engine command data carried inside it.
See [ENGINE_PROTOCOL.md](ENGINE_PROTOCOL.md) for protocol-5 commands, all
128 telemetry bytes, eight-ply settings and candidate-bound metadata.
