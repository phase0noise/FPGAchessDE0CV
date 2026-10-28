"""Check measured RTL choices against the independent mate oracle."""
import argparse
import json
import re
from pathlib import Path


def records(path):
    text = Path(path).read_text(encoding='utf-8-sig', errors='replace')
    # Windows PowerShell may redirect native output as UTF-16.
    if '\x00' in text:
        text = Path(path).read_text(encoding='utf-16')
    pattern = r'BENCH position=(\d+) best=(\d+)\s+completed=(\d+)\s+nodes=(\d+)\s+cache_hits=(\d+)\s+cycles=(\d+)'
    return [dict(zip(('position', 'best', 'depth', 'nodes', 'cacheHits', 'cycles'), map(int, row)))
            for row in re.findall(pattern, text)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('expanded')
    parser.add_argument('--baseline')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    oracle = json.loads((root / '.cache/strength_oracle.json').read_text())
    expanded = records(args.expanded)
    assert len(expanded) == len(oracle), f'Expected {len(oracle)} completed expanded-engine positions, found {len(expanded)}'
    for index, (case, result) in enumerate(zip(oracle, expanded)):
        assert result['position'] == index
        assert result['best'] in case['winningCodes'], f'Failed forced mate: {case["name"]}'
        assert result['depth'] >= 5, f'Benchmark did not complete five plies: {case["name"]}'
    print(f'PASS: expanded engine chooses a proven mate-in-three move on {len(expanded)}/{len(oracle)} positions.')
    report = dict(expandedPassed=len(expanded), total=len(oracle),
                  expandedNormalDepth=5, expandedQuiescence=0, clockHz=50000000,
                  cases=oracle, positions=expanded)
    if args.baseline:
        baseline = records(args.baseline)
        assert len(baseline) == len(oracle)
        passed = sum(result['best'] in case['winningCodes'] for case, result in zip(oracle, baseline))
        report['baselinePassed'] = passed
        report['baseline'] = baseline
        print(f'Previous three-ply engine: {passed}/{len(oracle)} proven mate-in-three choices.')
        assert passed < len(expanded), 'No measured gain over the baseline on this benchmark'
    (root / '.cache/strength_results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
