#!/usr/bin/env python3
"""Check the actual Dart lockfile against OSV without uploading source or secrets."""
import argparse
import json
from pathlib import Path
import re
import urllib.request


def locked_packages(text):
    packages = []
    for match in re.finditer(r'(?m)^  ([a-z][a-z0-9_]*):\s*\n((?:    .*\n|\n)+)', text):
        name, body = match.groups()
        if not re.search(r'(?m)^    source: hosted\s*$', body):
            continue
        version = re.search(r'(?m)^    version: ["\']?([^"\'\s]+)["\']?\s*$', body)
        if version is None:
            raise ValueError(f'Missing locked version: {name}')
        packages.append({'package': {'name': name, 'ecosystem': 'Pub'}, 'version': version.group(1)})
    if not packages:
        raise ValueError('No hosted packages found. Run flutter pub get first.')
    return packages


def audit(path):
    queries = locked_packages(path.read_text())
    request = urllib.request.Request('https://api.osv.dev/v1/querybatch', data=json.dumps({'queries': queries}).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=45) as response:
        results = json.load(response)['results']
    if len(results) != len(queries):
        raise ValueError('Incomplete advisory response')
    findings = []
    for query, result in zip(queries, results):
        if result.get('next_page_token') or result.get('vulns'):
            findings.append({'package': query['package']['name'], 'version': query['version'], 'advisories': result.get('vulns', []), 'additional_pages': bool(result.get('next_page_token'))})
    print(json.dumps({'hosted_packages_checked': len(queries), 'findings': findings, 'scope': 'Dart packages only. Android Maven dependencies, OS/WebView and unknown vulnerabilities are not covered.'}, indent=2))
    if findings:
        raise ValueError('Known advisory matches require review before release')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lockfile', nargs='?', type=Path, default=Path('pubspec.lock'))
    args = parser.parse_args()
    try:
        audit(args.lockfile)
    except Exception as error:
        parser.exit(1, f'Dependency review incomplete: {error}\n')
