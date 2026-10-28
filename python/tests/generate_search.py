"""Independent tactical fixtures for the copied FPGA engine, on both colors."""
from pathlib import Path
import chess
from generate_fixtures import encode_move, position_bytes

CASES = [
    ('mate over material', '7k/8/5KQ1/8/8/8/8/1q6 w - - 0 1', 'g6g7', 'g6b1', 20000, 'g6g7'),
    ('poisoned pawn', '6k1/8/4p3/3p4/3Q4/8/8/6K1 w - - 0 1', 'g1f1', 'd4d5', 300, None),
    ('royal fork', '6k1/8/8/3N3q/8/8/8/6K1 w - - 0 1', 'd5f6', 'd5c3', 400, 'd5f6'),
    ('opponent en passant', '7k/8/8/8/1p6/8/P7/K7 w - - 0 1', 'a1b1', 'a2a4', 50, None),
    ('promotion commit', '7k/P7/8/8/8/8/8/7K w - - 0 1', 'a7a8q', 'h1g1', 0, 'a7a8q'),
]

def main():
    lines=[]
    for name,fen,focus,other,gap,best in CASES:
        for mirrored in (False, True):
            board=chess.Board(fen)
            if mirrored:
                board=board.mirror()
            def move(text):
                m=chess.Move.from_uci(text)
                return chess.Move(chess.square_mirror(m.from_square),chess.square_mirror(m.to_square),promotion=m.promotion) if mirrored else m
            assert board.is_valid() and move(focus) in board.legal_moves and move(other) in board.legal_moves
            maps=[]
            for color in (True,False):
                attack=0
                for s,p in board.piece_map().items():
                    if p.color==color:
                        attack|=int(board.attacks(s))
                maps.extend(attack.to_bytes(8,'little'))
            committed=[]
            if best:
                trial=board.copy();trial.push(move(best));committed=list(position_bytes(trial))
            legal=sorted(encode_move(m) for m in board.legal_moves)
            lines.append(' '.join(map(str,[*position_bytes(board),len(legal),*legal,*maps,
                         encode_move(move(focus)),encode_move(move(other)),gap,
                         encode_move(move(best)) if best else -1,*committed])))
    output=Path(__file__).resolve().parents[2]/'.cache/search_vectors.txt'
    output.parent.mkdir(exist_ok=True)
    output.write_text('\n'.join(lines)+'\n',encoding='ascii')
    print(f'Generated {len(lines)} tactical fixtures with independently checked legal moves.')

if __name__=='__main__':main()
