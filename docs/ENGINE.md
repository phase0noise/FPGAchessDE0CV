# Search engine

The FPGA owns move generation, evaluation and computer move selection. One
spatial fabric and one search controller operate on one speculative board.
Four evaluation/hash lanes, four move-queue banks, eight-square restores and
a single pawn-file arithmetic lane accelerate work repeated at each node. See
[ADVANCED_ENGINE.md](ADVANCED_ENGINE.md) for the detailed pipeline and
[ARCHITECTURE.md](ARCHITECTURE.md) for the browser/Pi/FPGA division.

## Search and result publication

The default targets five normal plies with a ten-second budget. Normal depth
supports 2 through 8, and Spatial mode uses no tree search. Iterative deepening
starts at two plies. The previous completed best root move goes first at the
next depth. Later candidates use a narrow alpha/alpha+1 scout window; a
candidate that can improve the best value is applied again from the factual
board and searched with a full window.

The selected winner has an exact value. A losing scout can publish an upper
bound, explicitly marked in candidate metadata. The browser checks the full
legal set and bound semantics before guarded commit. Candidate samples are
not a ranking of five independently exact runner-up values.

Each iteration writes a separate result bank. A timeout preserves the last
complete candidate bank, selected move, score, immediate-root positional terms
and captured continuation. The first iteration can exceed a short budget so
that a successful result still contains the complete legal set. The host
replays the continuation's legal moves, checks the chosen explanation and
position, commits with the generation number and reads back the board.

## Move generation and ordering

A concurrent source mask selects eligible pieces in ascending square order.
Reach-map destinations skip impossible squares, with pawn pushes and castling
added explicitly. Every speculative move passes the spatial king-safety
filter. Castling rook motion, en passant, all four promotions, rights, turn and
king squares are saved/restored through the same board stack.

Ordering prefers a cache move, favorable captures/promotions, killer moves and
quiet-move history/placement. A native-clock exchange analyzer examines
ambiguous defended captures by a more valuable piece. It follows least-valued
attackers, exposed slider rays, en passant and promotion; defended king
recaptures are rejected. Non-king pins are handled conservatively, and the
chain is bounded to fifteen recaptures. The result changes ordering only and
never removes a move.

Quiescence searches captures/promotions for up to four further plies and all
check evasions. One extra evasion ply is allowed at the quiescence limit.
Stand pat and horizon evaluation first establish that a legal move exists,
preserving mate/stalemate at the frontier. Mate values favor shorter wins and
longer survival. Fourteen stack levels cover normal depth, extensions and
control headroom.

Bare kings, king plus one minor against king, and bishop-only positions with
bishops on one color score as insufficient-material draws. Repetition on the
speculative path scores as a draw. The browser maintains full game history,
move-count rules and game-level repetition claims.

## Evaluation

Each position is evaluated from its board contents so cached values do not
depend on a path's arithmetic rounding. Material and placement blend between
middlegame and endgame by remaining minor/rook/queen material. Other terms
cover bishop pairs, passed/isolated/doubled pawns, rook files and king shelter.

The new terms measure king-zone attack coverage and per-piece reach for
knights, bishops, rooks and queens, excluding friendly occupied destinations.
Mobility is pseudo-legal and can include a pinned piece's reach; the move
legality filter remains separate. Policy weights 43 and 44 control these
terms. Setting mobility weight to zero skips its piece scan.

Search mode publishes consistent searched position values without adding
random, habit or recurrent-field bonuses at the root. Spatial mode retains
its field-based preference scoring. Immediate-root king/mobility telemetry
is not a decomposition of every leaf in the searched minimax result.

## Block RAM

| Table | Logical capacity | Purpose |
| --- | --- | --- |
| Position cache | 4,096 x 128 bits | Full key, depth, score bound, preferred move, epoch |
| Ordered moves | 14 x 512 x 32 bits, four banks | Per-level move/priority queues |
| Quiet history | 4,096 x 13 bits | Saturating source/destination cutoff history |
| Zobrist keys | 1,024 x 64 bits, four banks | Piece/color/square keys |
| Board stack | 14 x 8 x 32 bits | Packed speculative boards |
| Candidate results | 2 x 256 x 144 bits | Published/in-progress explanations |
| Candidate metadata | 2 x 256 x 8 bits | Bound kind and completed depth |
| Continuations | 14 x 228 bits | Captured line and length per level |

The cache compares a full 64-bit key including side, castling and en passant.
Entries track normal depth, quiescence allowance, remaining stack allowance,
score bound and mate distance. A match can answer a search or provide only an
ordering hint; telemetry distinguishes these cases. An evaluation advances an
epoch, preventing scored reuse across unrelated roots/policies. Soft reset
preserves the epoch because it does not clear RAM; wrap clears the table.
Repetition results are not cached through ancestors. Cache cutoffs can shorten
the captured continuation, so the console labels it as a prefix.

Tables use synchronous Cyclone V M10K ports and configuration-time RAM initialization. There is no large reset mux clearing all RAM. The native-clock
pipeline and common four-clock controller enable are part of the timing
contract. Qualified frequency/resources are in [build-results.txt](build-results.txt).

## Controls and verification

[ENGINE_PROTOCOL.md](ENGINE_PROTOCOL.md) specifies protocol 5, eight-ply controls,
48-bit time/phase counters, reported clock and candidate bounds. Load matching
FPGA image and Pi service. The console displays measured phases, cache answers,
root re-searches, exchange activity and a legally replayed continuation.

`tools/verify.ps1 -Browser -Strength` checks independent legality, physical SPI,
RAM banks, exchange cases, tactical choices, cache/reference equivalence,
scout bounds, deadline publication, an actually visited eight-ply ending,
proven five-ply mate choices and mobile interactions. Long searches use a
simulation-only attack model checked against the wired production fabric on
all source squares in the independent rule fixtures. Search/evaluation/memory
RTL remains the production implementation. Current results and the separate
physical-board acceptance status are in [VALIDATION.md](VALIDATION.md).
