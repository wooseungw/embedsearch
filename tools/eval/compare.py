#!/usr/bin/env python3
"""Compare two CLI --json snapshots only when corpus, queries and model match."""
import argparse
import json
from collections import defaultdict
from pathlib import Path


def compare(baseline, candidate):
    for field in ('schemaVersion', 'corpusSHA256', 'queriesSHA256', 'modelKey'):
        if baseline.get(field) != candidate.get(field):
            raise ValueError(f'incomparable snapshots: {field} differs')
    old = next(r for r in baseline['reports'] if r['mode'] == 'hybrid')
    new = next(r for r in candidate['reports'] if r['mode'] == 'hybrid')
    pairs = list(zip(old['outcomes'], new['outcomes']))
    if len(old['outcomes']) != len(new['outcomes']) or any(a['query'] != b['query'] for a, b in pairs):
        raise ValueError('incomparable query ordering')
    groups = defaultdict(list)
    for a, b in pairs:
        groups[a['type']].append((a, b))
    print(f"MRR@10 {old['mrr10']:.4f} -> {new['mrr10']:.4f}; success@1 {old['success1']:.1%} -> {new['success1']:.1%}")
    for name, rows in sorted(groups.items()):
        print(f"{name}: {sum(a['rank'] == 1 for a, _ in rows)}/{len(rows)} -> {sum(b['rank'] == 1 for _, b in rows)}/{len(rows)}")
    protected = []
    for a, b in pairs:
        if a['rank'] == 1 and b['rank'] != 1:
            print(f"REGRESSED {a['type']}: {a['query']} (1 -> {b['rank']})")
            if a['type'] in ('exact', 'chosung'):
                protected.append(a['query'])
    errors = sum(r['executionErrors'] for r in candidate['reports'])
    if errors:
        print(f'Execution errors: {errors}')
    return new['mrr10'] + 1e-9 >= old['mrr10'] and not protected and errors == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        passed = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    except (ValueError, KeyError, StopIteration) as error:
        parser.error(str(error))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
