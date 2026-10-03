#!/usr/bin/env python3
"""Query OSV for exact resolved Maven coordinates; source and secrets stay local."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import urllib.request


def audit(inventory):
    packages = json.loads(inventory.read_text())['packages']
    queries = [{'package': {'name': p['group'] + ':' + p['name'], 'ecosystem': 'Maven'}, 'version': p['version']}
               for p in packages if p['group'] and p['group'] not in {'project', 'unspecified'}]
    if not queries:
        raise ValueError('No resolved Maven coordinates to audit.')
    findings = []
    for offset in range(0, len(queries), 100):
        batch = queries[offset:offset+100]
        request = urllib.request.Request('https://api.osv.dev/v1/querybatch',
            data=json.dumps({'queries': batch}).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=45) as response:
            results = json.load(response)['results']
        if len(results) != len(batch):
            raise ValueError('Incomplete advisory response.')
        for query, result in zip(batch, results):
            if result.get('vulns') or result.get('next_page_token'):
                findings.append({'package': query['package']['name'], 'version': query['version'],
                    'advisories': result.get('vulns', []), 'additional_pages': bool(result.get('next_page_token'))})
    print(json.dumps({'checked_utc': datetime.now(timezone.utc).isoformat(), 'packages_checked': len(queries),
        'findings': findings, 'scope': 'Resolved Android release Maven artifacts only. Excludes device OS/WebView and unknown vulnerabilities.'}, indent=2))
    if findings:
        raise ValueError('Known advisory matches require review before release.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path)
    args = parser.parse_args()
    try:
        audit(args.inventory)
    except Exception as error:
        parser.exit(1, f'Android dependency review incomplete: {error}\n')
