"""Check datapath equivalence and PVS bounds against full-window RTL results."""
import argparse
import json
import re
from pathlib import Path


def read(path):
    raw=Path(path).read_bytes()
    return raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig')


def parse(path):
    text=read(path)
    bench=[dict(zip(('position','best','depth','nodes','cacheHits','cycles','score'),map(int,m)))
           for m in re.findall(r'BENCH position=(\d+) best=(\d+) completed=(\d+) nodes=(\d+) cache_hits=(\d+) cycles=(\d+) score=(-?\d+)',text)]
    scores={(int(p),int(m)):(int(v),int(k)) for p,m,v,k in
            re.findall(r'CACHE_SCORE position=(\d+) move=(\d+) value=(-?\d+) bound=(\d+)',text)}
    pv={int(p):list(map(int,m.split())) for p,m in re.findall(r'PV position=(\d+) moves=([\d ]+)',text)}
    assert bench and scores and 'PASS: independent' in text, f'Incomplete simulation: {path}'
    return bench,scores,pv


def check_pvs(reference,scout):
    ref,exact,_=parse(reference)
    actual,bounds,_=parse(scout)
    assert exact.keys()==bounds.keys(), 'PVS changed the legal candidate set'
    winners={b['position']:b for b in actual}
    for before,after in zip(ref,actual):
        assert before['position']==after['position'] and before['depth']==after['depth']
        assert before['score']==after['score'], f'PVS changed the best value: {before} {after}'
        assert exact[(after['position'],after['best'])][0]==before['score']
        assert bounds[(after['position'],after['best'])][1]==0
    for key,(value,kind) in bounds.items():
        reference_value,reference_kind=exact[key]
        assert reference_kind==0
        if kind==0: assert value==reference_value,(key,value,reference_value)
        elif kind==1: assert reference_value<=value<=winners[key[0]]['score'],(key,value,reference_value)
        else: raise AssertionError('Completed root winner cannot be established by a lower bound')
    return actual,len(bounds)


def check_lines(log,vectors):
    import chess
    _,_,lines=parse(log)
    positions=Path(vectors).read_text(encoding='ascii').splitlines()
    for index,moves in lines.items():
        packed=list(map(int,positions[index].split()))
        board=chess.Board(None)
        for square,piece in enumerate(packed[:64]):
            if piece: board.set_piece_at(square,chess.Piece(piece&7,not bool(piece&8)))
        board.turn=not bool(packed[64])
        board.castling_rights=sum(chess.BB_SQUARES[s] for i,s in enumerate((7,0,63,56)) if packed[65]&(1<<i))
        board.ep_square=packed[66] if packed[66]<64 else None
        for code in moves:
            move=chess.Move(code&63,(code>>6)&63,promotion=(code>>12)&7 or None)
            assert move in board.legal_moves, f'Illegal captured PV move {move} in {board.fen()}'
            board.push(move)
    return len(lines)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--scalar',required=True);ap.add_argument('--parallel',required=True);ap.add_argument('--pvs',required=True)
    ap.add_argument('--vectors',default='.cache/cache_vectors.txt');ap.add_argument('--output',default='docs/advancement-results.json')
    ap.add_argument('--queue');ap.add_argument('--special-reference');ap.add_argument('--special-pvs')
    args=ap.parse_args()
    scalar,scalars,_=parse(args.scalar);wide,wides,_=parse(args.parallel)
    assert scalars==wides, 'Lane widening changed a root score'
    assert [(b['best'],b['nodes'],b['score']) for b in scalar]==[(b['best'],b['nodes'],b['score']) for b in wide]
    pvs,count=check_pvs(args.parallel,args.pvs)
    lines=sum(check_lines(log,args.vectors) for log in (args.scalar,args.parallel,args.pvs))
    totals={name:sum(b['cycles'] for b in rows) for name,rows in (('scalar',scalar),('fourLanes',wide),('fourLanesAndPvs',pvs))}
    result=dict(scope='Two deterministic three-ply fork/promotion fixtures; positional terms and SEE disabled to isolate changes; no strength rating',
                positions=len(scalar),candidateBoundsChecked=count,legalPvPrefixesChecked=lines,
                cycles=totals,laneCycleReduction=1-totals['fourLanes']/totals['scalar'],
                pvsAdditionalCycleReduction=1-totals['fourLanesAndPvs']/totals['fourLanes'],
                scalar=scalar,fourLanes=wide,pvs=pvs)
    if args.queue:
        queued,queue_scores,_=parse(args.queue)
        assert queue_scores==parse(args.pvs)[1]
        assert [(b['best'],b['nodes'],b['score'],b['cacheHits']) for b in queued]==[(b['best'],b['nodes'],b['score'],b['cacheHits']) for b in pvs]
        result['fourBankQueue']=queued;result['cycles']['fourLanesPvsAndQueue']=sum(b['cycles'] for b in queued)
        assert result['cycles']['fourLanesPvsAndQueue']<totals['fourLanesAndPvs']
        lines+=check_lines(args.queue,args.vectors)
    if args.special_reference:
        special,special_count=check_pvs(args.special_reference,args.special_pvs)
        lines+=check_lines(args.special_reference,'.cache/chess_vectors.txt')+check_lines(args.special_pvs,'.cache/chess_vectors.txt')
        result['specialRulePositions']=len(special);result['specialRuleBoundsChecked']=special_count
    result['legalPvPrefixesChecked']=lines
    Path(args.output).write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
    print(f'PASS: {len(scalars)} exact lane scores, {count} PVS bounds, {lines} legal PV prefixes. Cycles: {totals}')


if __name__=='__main__': main()
