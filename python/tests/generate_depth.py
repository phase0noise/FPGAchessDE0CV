"""Independent depth-eight fixtures, forced draws and a live pawn ending."""
from pathlib import Path
import chess
from generate_fixtures import encode_move, position_bytes


def main():
    lines = []
    for mirrored in (False, True):
        board = chess.Board('8/8/8/8/8/8/r1k5/K7 w - - 0 1')
        if mirrored:
            board = board.mirror()
        assert board.is_valid()
        legal = list(board.legal_moves)
        assert len(legal) == 1
        move = legal[0]
        after = board.copy()
        after.push(move)
        assert after.is_insufficient_material()
        maps = []
        for color in (chess.WHITE, chess.BLACK):
            attack = 0
            for square, piece in board.piece_map().items():
                if piece.color == color:
                    attack |= int(board.attacks(square))
            maps.extend(attack.to_bytes(8, 'little'))
        code = encode_move(move)
        lines.append(' '.join(map(str, [*position_bytes(board), 1, code, *maps,
            -1, -1, 0, code, *position_bytes(after)])))
    output = Path(__file__).resolve().parents[1] / '.cache/depth_vectors.txt'
    output.parent.mkdir(exist_ok=True)
    output.write_text('\n'.join(lines) + '\n', encoding='ascii')
    board=chess.Board('8/8/8/8/8/2k5/P7/K7 w - - 0 1')
    assert board.is_valid() and not board.is_game_over()
    maps=[]
    for color in (chess.WHITE,chess.BLACK):
        attack=0
        for square,piece in board.piece_map().items():
            if piece.color==color: attack|=int(board.attacks(square))
        maps.extend(attack.to_bytes(8,'little'))
    legal=sorted(encode_move(m) for m in board.legal_moves)
    live=' '.join(map(str,[*position_bytes(board),len(legal),*legal,*maps,-1,-1,0,-1]))
    (output.parent/'depth_live_vectors.txt').write_text(live+'\n',encoding='ascii')
    print('Proved two forced king captures leading to insufficient-material draws.')


if __name__ == '__main__':
    main()
