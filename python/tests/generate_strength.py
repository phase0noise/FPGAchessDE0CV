"""Prove small mate-in-three positions with python-chess, independent of RTL.

The oracle explores every defender reply and all legal attacker moves. These
bare king/queen positions require five plies; none can be forced in three.
This is a tactical regression benchmark, not an Elo estimate.
"""
from pathlib import Path
import json
import chess
from generate_fixtures import encode_move, position_bytes

FENS = [
    '7k/8/8/6Q1/5K2/8/8/8 w - - 0 1',
    '7k/8/8/4K3/8/8/3Q4/8 w - - 0 1',
    '7k/8/8/8/5K2/8/6Q1/8 w - - 0 1',
    '7k/8/8/8/6K1/8/6Q1/8 w - - 0 1',
    '7k/8/8/4K3/8/2Q5/8/8 w - - 0 1',
    '7k/8/4Q3/6K1/8/8/8/8 w - - 0 1',
]


def prove_mate(board, depth, attacker, cache):
    key = (board.board_fen(), board.turn, depth, attacker)
    if key in cache:
        return cache[key]
    moves = list(board.legal_moves)
    if not moves:
        return board.is_check() and board.turn != attacker
    if depth == 0 or not board.pieces(chess.QUEEN, attacker):
        return False
    attacking = board.turn == attacker
    if attacking:
        moves.sort(key=board.gives_check, reverse=True)
    result = not attacking
    for move in moves:
        board.push(move)
        win = prove_mate(board, depth - 1, attacker, cache)
        board.pop()
        if win == attacking:
            result = attacking
            break
    cache[key] = result
    return result


def main():
    lines, cases = [], []
    cache = {}
    for index, fen in enumerate(FENS):
        for mirrored in (False, True):
            board = chess.Board(fen)
            if mirrored:
                board = board.mirror()
            attacker = board.turn
            assert board.is_valid()
            assert not prove_mate(board, 3, attacker, cache)
            assert prove_mate(board, 5, attacker, cache)
            winning = []
            for move in list(board.legal_moves):
                board.push(move)
                win = prove_mate(board, 4, attacker, cache)
                board.pop()
                if win:
                    winning.append(move)
            winning.sort(key=lambda move: move.uci())
            other = next(move for move in board.legal_moves if move not in winning)
            maps = []
            for color in (chess.WHITE, chess.BLACK):
                attack = 0
                for square, piece in board.piece_map().items():
                    if piece.color == color:
                        attack |= int(board.attacks(square))
                maps.extend(attack.to_bytes(8, 'little'))
            committed = []
            best = -1
            if len(winning) == 1:
                best = encode_move(winning[0])
                after = board.copy()
                after.push(winning[0])
                committed = list(position_bytes(after))
            legal = sorted(encode_move(move) for move in board.legal_moves)
            lines.append(' '.join(map(str, [*position_bytes(board), len(legal), *legal, *maps,
                encode_move(winning[0]), encode_move(other), 20000, best, *committed])))
            cases.append(dict(name=f'mate-three-{index + 1}-{"black" if mirrored else "white"}',
                fen=board.fen(), winning=[move.uci() for move in winning],
                winningCodes=[encode_move(move) for move in winning]))
    output = Path(__file__).resolve().parents[1] / '.cache'
    output.mkdir(exist_ok=True)
    (output / 'strength_vectors.txt').write_text('\n'.join(lines) + '\n', encoding='ascii')
    (output / 'strength_oracle.json').write_text(json.dumps(cases, indent=2) + '\n')
    print(f'Proved {len(cases)} mate-in-three fixtures on both colors, including all winning first moves.')


if __name__ == '__main__':
    main()
