# Parallel datapath

The engine searches one speculative board at a time. Parallel hardware reduces
repeated work inside each searched node, with RAM banks matched to arithmetic
lanes. [ADVANCED_ENGINE.md](ADVANCED_ENGINE.md) describes the complete current
pipeline, root scheduling and clock contract.

| Operation | Scalar reference | Production |
| --- | --- | --- |
| Board restore | 64 reads/copies, 128 controller enables | Eight-square words; 8 reads/copies, 16 enables |
| Source eligibility | Visit every square | Decode all 64 squares concurrently, then select next eligible source |
| Destination scan | Visit every destination | Select reachable destinations; explicitly add pawn pushes and castling |
| Pawn-file terms | Eight issue enables | One lane; eight issue enables plus two pipeline drain enables |
| Material / placement / hash | 64 square issue steps | Four lanes; 16 groups plus three drain steps |
| Ordered-move selection | One RAM entry per enable | Four banks, pair winners, group winner |

The shared enable occurs every four internal clocks. The spatial fabric,
search controller and recurrent-field update arithmetic remain single
instances. The field settles once per decision; board restore, evaluation,
hashing and move selection recur throughout the tree.

## Evaluation and hashing

Four adjacent squares have distinct files, so pawn/file summaries update
without competing for one file counter. Each lane computes material,
middlegame/endgame placement, phase and king shelter. Weighting and signed
rounding occur per piece before registered pair sums and final accumulation.
Pawn structure, bishop pairs, insufficient-material flags and hash salts retain
the scalar reference's rules.

The final phase blend uses registered sum/magnitude and reciprocal-product
stages for exact division by 24. The pawn-file pass registers raw terms,
per-file weighting/rounding and accumulation separately. These address measured
arithmetic paths and preserve score rounding in the narrower reference modes.

Four square-interleaved Zobrist ROM banks supply the matching keys. The bank is
the original key index modulo four; contents use the same SplitMix64 constants.
Memory tests compare all 1,024 keys with the scalar reference port.

The fourteen-level board stack holds eight 32-bit words per board, or 3,584
logical bits. Production saves/restores packed ranks. The scalar compatibility
path also saves every square when evaluation issues four squares at once.

## Move queues

Four interleaved RAM banks store the existing 32-bit move/priority records.
The native-clock pipeline reads a group, registers two pair winners, then
registers its group winner. Address/mask tags stay aligned with the data.
Partial groups mask unused lanes; ties choose the lower queue index.
Remove-by-swap retrieves the actual final live entry before replacing the
selected move.

The four-clock controller interval accommodates these stages. Native stages
have single-cycle timing requirements; only registers with the common
controller enable receive the paired four-cycle setup/three-cycle hold
exception. Registered controller requests feed short native write/start
strobes. [build-results.txt](build-results.txt) records routed timing.

## Reference configurations and measurements

`STACK_LANES=1`, `FAST_SOURCES=false`, `PAWN_LANES=1`, `EVAL_LANES=1` and
`QUEUE_LANES=1` retain narrower reference paths. Production uses 8, true, 2,
4 and 4 respectively. `ROOT_PVS=false, ROOT_ORDERING=false` provides a
full-window root-search reference for validating exact values and scout bounds.

[advancement-results.json](advancement-results.json) isolates four-lane
evaluation, root scheduling and queue banking on deterministic three-ply
fork/promotion fixtures. New positional terms and exchange ordering are
disabled in that isolated comparison. Separate special-rule searches check
PVS bounds with those features enabled. These establish efficiency and
correctness within their stated scope; they do not establish a strength rating.
