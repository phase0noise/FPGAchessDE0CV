"""Compare reach-map destination scanning with the original 64-square walk."""
import argparse
import json
from pathlib import Path
from check_cache import scores
from check_strength import records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('fast')
    parser.add_argument('original')
    args = parser.parse_args()
    fast, original = records(args.fast), records(args.original)
    assert fast and len(fast) == len(original)
    assert scores(args.fast) == scores(args.original), 'Destination skipping changed root scores'
    assert scores(args.fast), 'Missing root candidate scores'
    for a, b in zip(fast, original):
        for field in ('position', 'best', 'depth', 'nodes', 'cacheHits'):
            assert a[field] == b[field], f'Destination skipping changed {field}'
        assert a['cycles'] < b['cycles'], 'No cycle reduction on a benchmark position'
    fast_cycles = sum(r['cycles'] for r in fast)
    original_cycles = sum(r['cycles'] for r in original)
    report = dict(positions=len(fast), candidateScores=len(scores(args.fast)),
                  fastCycles=fast_cycles, originalCycles=original_cycles,
                  reductionPercent=round(100 * (1 - fast_cycles / original_cycles), 2),
                  fast=fast, original=original)
    output = Path(__file__).resolve().parents[2] / '.cache/destination_results.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: identical moves, scores and nodes; {report["reductionPercent"]}% fewer cycles on {len(fast)} positions.')


if __name__ == '__main__':
    main()
