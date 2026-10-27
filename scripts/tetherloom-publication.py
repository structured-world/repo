#!/usr/bin/env python3
"""Retire exact transfer artifacts after their signed output is committed."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request


REPOSITORY = 'structured-world/tetherloom'
PREFIX = f'/repos/{REPOSITORY}/actions'


def api(method, path):
    request = urllib.request.Request(
        'https://api.github.com' + path, method=method,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        # Already deleted artifacts are successful cleanup retries, not failures.
        if error.code == 404 and '/artifacts/' in path:
            return None
        raise


def positive(value):
    if type(value) is not int or value <= 0:
        raise ValueError('expected a positive integer')
    return value


def source(run_id, expected_attempt=None):
    run = api('GET', f'{PREFIX}/runs/{positive(run_id)}')
    if (run['id'] != run_id or run['repository']['full_name'] != REPOSITORY
            or run['event'] != 'release' or run['name'] != 'Release'
            or run['path'] != '.github/workflows/release.yml'
            or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', run['head_branch'])
            or (run['status'] == 'completed' and run['conclusion'] != 'success')):
        raise ValueError('not a successful release or an admitted release dispatch')
    positive(run['run_attempt'])
    if expected_attempt is None:
        if run['status'] != 'completed':
            raise ValueError('an unversioned dispatch requires a completed source run')
    elif run['run_attempt'] != positive(expected_attempt):
        raise ValueError('dispatch belongs to a different source attempt')
    if not re.fullmatch(r'[0-9a-f]{40,64}', run['head_sha']):
        raise ValueError('invalid source commit')
    return {'run_id': run_id, 'attempt': run['run_attempt'], 'sha': run['head_sha']}


def artifact_ids(run_id):
    ids = []
    for page in range(1, 101):
        result = api('GET', f'{PREFIX}/runs/{run_id}/artifacts?per_page=100&page={page}')
        artifacts = result['artifacts']
        ids.extend(positive(artifact['id']) for artifact in artifacts)
        if len(artifacts) < 100:
            if len(set(ids)) != len(ids):
                raise ValueError('artifact listing changed during pagination')
            return sorted(ids)
    raise ValueError('artifact listing exceeds publication limit')


def receipt_path(receipt):
    return Path('.publications/tetherloom') / (
        f"{positive(receipt['run_id'])}-{positive(receipt['attempt'])}.json")


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def committed_receipt(path):
    committed = subprocess.run(['git', 'show', f'HEAD:{path.as_posix()}'],
                               check=True, capture_output=True, text=True)
    return json.loads(committed.stdout)


def prepare(run_id, state, output, expected_attempt=None):
    # A committed publication authorizes its own cleanup, independently of the
    # live attempt's progress. Only unpublished attempts need fresh admission.
    if expected_attempt is not None:
        identity = {'run_id': positive(run_id), 'attempt': positive(expected_attempt)}
    else:
        identity = source(run_id)
    path = receipt_path(identity)
    published = path.exists()
    if published:
        receipt = committed_receipt(path)
        if any(receipt[key] != value for key, value in identity.items()):
            raise ValueError('publication receipt does not match the source')
    else:
        if expected_attempt is not None:
            identity = source(run_id, expected_attempt)
        receipt = dict(identity, artifacts=artifact_ids(run_id))
        if not receipt['artifacts']:
            raise ValueError('release has no transfer artifacts')
    save(state, receipt)
    with output.open('a') as stream:
        stream.write(f'published={str(published).lower()}\nreceipt_path={path.as_posix()}\n')


def seal(state):
    receipt = json.loads(state.read_text())
    identity = source(receipt['run_id'], receipt['attempt'])
    if (any(receipt[key] != value for key, value in identity.items())
            or receipt['artifacts'] != artifact_ids(receipt['run_id'])):
        raise ValueError('source attempt or artifacts changed during publication')
    path = receipt_path(receipt)
    if path.exists():
        raise ValueError('publication receipt already exists')
    save(path, receipt)


def cleanup(state):
    receipt = json.loads(state.read_text())
    path = receipt_path(receipt)
    if committed_receipt(path) != receipt:
        raise ValueError('cleanup requires the committed publication receipt')
    ids = receipt['artifacts']
    if not ids or any(type(i) is not int or i <= 0 for i in ids) or len(set(ids)) != len(ids):
        raise ValueError('invalid artifact identities in publication receipt')
    run = api('GET', f"{PREFIX}/runs/{receipt['run_id']}")
    if (run['id'] != receipt['run_id'] or run['repository']['full_name'] != REPOSITORY
            or run['head_sha'] != receipt['sha']):
        raise ValueError('published source run is inaccessible or changed')
    # Check every surviving object before the first deletion. New uploads with
    # the same name have different IDs and are never swept into this set.
    remaining = []
    for artifact_id in ids:
        artifact = api('GET', f'{PREFIX}/artifacts/{artifact_id}')
        if artifact is None:
            continue
        owner = artifact['workflow_run']
        if (artifact['id'] != artifact_id or owner['id'] != receipt['run_id']
                or owner['head_sha'] != receipt['sha']):
            raise ValueError('artifact does not belong to the published run')
        remaining.append(artifact_id)
    for artifact_id in remaining:
        api('DELETE', f'{PREFIX}/artifacts/{artifact_id}')
    print(f'Retired {len(remaining)} published transfer artifacts')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'seal', 'cleanup'))
    parser.add_argument('--run-id', type=int)
    parser.add_argument('--state', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        attempt = os.environ.get('SOURCE_RUN_ATTEMPT', '')
        prepare(args.run_id, args.state, Path(os.environ['GITHUB_OUTPUT']),
                int(attempt) if attempt else None)
    elif args.action == 'seal':
        seal(args.state)
    else:
        cleanup(args.state)


if __name__ == '__main__':
    main()
