#!/usr/bin/env python3
"""Register the actual marketplace in an isolated Codex profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex', help='Codex CLI executable (default: codex on PATH)')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    catalog = json.loads((root / '.agents/plugins/marketplace.json').read_text())
    with tempfile.TemporaryDirectory(prefix='sw-marketplace-codex-') as temporary:
        environment = dict(os.environ, HOME=temporary, USERPROFILE=temporary,
                           CODEX_HOME=str(Path(temporary) / '.codex'))
        Path(environment['CODEX_HOME']).mkdir()
        def cli(arguments):
            result = subprocess.run([args.codex, *arguments], cwd=temporary, env=environment,
                                    capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError('Codex qualification failed: ' + result.stderr)
            return result.stdout
        version = cli(['--version']).strip()
        added = json.loads(cli(['plugin', 'marketplace', 'add', str(root), '--json']))
        if added['marketplaceName'] != catalog['name']:
            raise ValueError('Codex registered a different marketplace')
        listing = cli(['plugin', 'marketplace', 'list'])
        if catalog['name'] not in listing:
            raise ValueError('Codex does not list the registered marketplace')
        print(json.dumps({'status': 'verified', 'codex': version,
                          'marketplace': added['marketplaceName'], 'entries': len(catalog['plugins'])}))


if __name__ == '__main__':
    main()
