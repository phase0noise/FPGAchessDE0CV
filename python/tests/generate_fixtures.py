"""Generate independent browser and VHDL rules fixtures with python-chess."""
import argparse
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import chess

SPECIAL = [
    chess.STARTING_FEN,
    'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1',
    'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
    'r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1',
    '4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1',
    '4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1',
    '4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1',
    '4k3/P7/8/8/8/8/7p/4K3 w - - 0 1',
    '4k3/P7/8/8/8/8/7p/4K3 b - - 0 1',
    '1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1',
    '4k3/8/8/8/8/8/4r3/4K3 w - - 0 1',
    '7k/6Q1/6K1/8/8/8/8/8 b - - 0 1',
    '7k/5Q2/6K1/8/8/8/8/8 b - - 0 1',
    '4k3/8/8/8/8/5r2/8/R3K2R w KQ - 0 1',
    '4k3/8/8/r4pPK/8/8/8/8 w - f6 0 1',
    'k7/8/8/8/8/8/6r1/4K2R w K - 0 1',
    '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
    '4kb2/8/8/8/8/8/8/2B1K3 w - - 0 1',
    '4k3/8/8/8/8/8/6N1/4K3 w - - 0 1',
]

def encode_move(move):
    return move.from_square | (move.to_square << 6) | ((move.promotion or 0) << 12)

def position_bytes(board):
    pieces = [(p.piece_type | (0 if p.color else 8)) if (p := board.piece_at(s)) else 0 for s in chess.SQUARES]
    rights = sum(bit for color, king, bit in [(True, True, 1), (True, False, 2), (False, True, 4), (False, False, 8)]
                 if (board.has_kingside_castling_rights(color) if king else board.has_queenside_castling_rights(color)))
    return bytes(pieces + [int(not board.turn), rights, board.ep_square if board.ep_square is not None else 64])

def positions(count):
    for fen in SPECIAL:
        board = chess.Board(fen)
        assert board.is_valid(), fen
        yield board
    rng = random.Random(353)
    board = chess.Board()
    for _ in range(count):
        for _ in range(rng.randrange(1, 12)):
            if board.is_game_over() or board.ply() > 250:
                board.reset()
            board.push(rng.choice(list(board.legal_moves)))
        yield board.copy()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=128)
    args = parser.parse_args()
    out = ROOT / '.cache'
    out.mkdir(exist_ok=True)
    browser, rtl = [], []
    for board in positions(args.count):
        moves = []
        for move in board.legal_moves:
            after = board.copy()
            after.push(move)
            moves.append(dict(uci=move.uci(), san=board.san(move), fen=after.fen(en_passant='fen')))
        browser.append(dict(fen=board.fen(en_passant='fen'), moves=moves,
                            check=board.is_check(), insufficient=board.is_insufficient_material(),
                            bytes=list(position_bytes(board))))
        maps = []
        for color in (chess.WHITE, chess.BLACK):
            attack = 0
            for s in chess.SQUARES:
                p = board.piece_at(s)
                if p and p.color == color:
                    attack |= int(board.attacks(s))
            maps.extend(attack.to_bytes(8, 'little'))
        rtl.append(' '.join(map(str, [*position_bytes(board), len(moves),
                                      *sorted(encode_move(m) for m in board.legal_moves), *maps])))
    (out / 'rules.json').write_text(json.dumps(browser), encoding='utf8')
    (out / 'chess_vectors.txt').write_text('\n'.join(rtl) + '\n', encoding='ascii')
    print(f'Generated {len(browser)} independent browser and VHDL positions.')

if __name__ == '__main__':
    main()
