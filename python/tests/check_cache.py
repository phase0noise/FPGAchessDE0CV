"""Compare complete candidate scores with transposition reuse enabled/disabled."""
import argparse
import re
from pathlib import Path
from check_strength import records


def scores(path):
    data = Path(path).read_bytes()
    text = data.decode('utf-16' if data.startswith(b'\xff\xfe') else 'utf-8-sig')
    return {(int(p), int(m)): int(v) for p, m, v in
            re.findall(r'CACHE_SCORE position=(\d+) move=(\d+) value=(-?\d+)', text)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('enabled')
    parser.add_argument('disabled')
    args = parser.parse_args()
    enabled, disabled = records(args.enabled), records(args.disabled)
    assert enabled and len(enabled) == len(disabled)
    a, b = scores(args.enabled), scores(args.disabled)
    assert a and a == b, 'Cache changed a complete root candidate score'
    assert all(x['best'] == y['best'] for x, y in zip(enabled, disabled))
    assert sum(x['cacheHits'] for x in enabled) > 0
    assert all(x['cacheHits'] == 0 for x in disabled)
    print(f'PASS: cache on/off preserves all {len(a)} candidate scores and selected moves.')


if __name__ == '__main__':
    main()
