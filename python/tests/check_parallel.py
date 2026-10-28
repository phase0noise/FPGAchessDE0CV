"""Compare wider restore, source selection and pawn arithmetic with the reference."""
import argparse
import json
from pathlib import Path
from check_cache import scores
from check_strength import records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('parallel')
    parser.add_argument('reference')
    parser.add_argument('--wide-only', required=True)
    parser.add_argument('--source-mask', required=True)
    parser.add_argument('--special-parallel', required=True)
    parser.add_argument('--special-reference', required=True)
    args = parser.parse_args()
    paths = [args.reference, args.wide_only, args.source_mask, args.parallel]
    results = [records(path) for path in paths]
    reference_scores = scores(args.reference)
    assert reference_scores and results[0], 'Missing reference results'
    for path, result in zip(paths[1:], results[1:]):
        assert scores(path) == reference_scores, 'Parallel datapath changed a root score'
        assert len(result) == len(results[0]), 'Missing parallel result'
        for baseline, actual in zip(results[0], result):
            for field in ('position', 'best', 'depth', 'nodes', 'cacheHits'):
                assert actual[field] == baseline[field], f'Parallel datapath changed {field}'
    totals = [sum(r['cycles'] for r in result) for result in results]
    assert totals[3] < totals[2] < totals[1] < totals[0], 'Expected all three changes to reduce cycles'
    special_scores=scores(args.special_reference)
    assert special_scores and special_scores == scores(args.special_parallel), 'Parallel special-move scores changed'
    special_reference, special_parallel = records(args.special_reference), records(args.special_parallel)
    assert special_reference and len(special_reference) == len(special_parallel)
    for baseline, actual in zip(special_reference, special_parallel):
        for field in ('position', 'best', 'depth', 'nodes', 'cacheHits'):
            assert actual[field] == baseline[field], f'Special-move search changed {field}'
    report = dict(positions=len(results[0]), candidateScores=len(reference_scores),
                  reference=dict(stackLanes=1, fastSources=False, pawnLanes=1, cycles=totals[0], results=results[0]),
                  wideStack=dict(stackLanes=8, fastSources=False, pawnLanes=1, cycles=totals[1], results=results[1]),
                  sourceMask=dict(stackLanes=8, fastSources=True, pawnLanes=1, cycles=totals[2], results=results[2]),
                  parallel=dict(stackLanes=8, fastSources=True, pawnLanes=2, cycles=totals[3], results=results[3]),
                  specialCandidateScores=len(special_scores), specialPositions=len(special_reference),
                  reductionPercent=round(100 * (1 - totals[3] / totals[0]), 2),
                  speedup=round(totals[0] / totals[3], 3))
    output = Path(__file__).resolve().parents[2] / '.cache/parallel_results.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: same {len(reference_scores)} scores, moves, nodes and cache matches; '
          f'{report["reductionPercent"]}% fewer cycles ({report["speedup"]}x throughput) on {len(results[0])} fixtures.')
    print(f'PASS: all {len(special_scores)} special-rule candidate scores, selected moves, node counts and cache matches agree.')


if __name__ == '__main__':
    main()
