#!/usr/bin/env python3
"""Run the actual download step against independently missing artifact roles.

GitHub's downloader accepts partial pattern matches. Source packages must
neither disappear nor stand in for missing installable packages.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parent.parent
workflow = yaml.safe_load((ROOT / '.github/workflows/publish.yml').read_text())
steps = [step for job in workflow['jobs'].values() for step in job['steps']]
script = next(step['run'] for step in steps if step.get('name') == 'Download tetherloom artifacts')
script = script.replace('${{ steps.tetherloom-runid.outputs.run_id }}', '12345')

# Reproduce the observed CLI contract, including success when only one of
# several requested patterns matches. No GitHub credentials or network.
FAKE_GH = '''import fnmatch, json, os, pathlib, shutil, sys
if sys.argv[1:3] == ['run', 'view']:
    print(json.dumps({'status':'completed','conclusion':'success',
      'headBranch':'v0.1.1','event':'release','workflowName':'Release'}))
elif sys.argv[1:3] == ['run', 'download']:
    args=sys.argv[3:]
    destination=pathlib.Path(args[args.index('-D')+1])
    patterns=[args[i+1] for i,a in enumerate(args) if a=='--pattern']
    matches=[p for p in pathlib.Path(os.environ['ARTIFACT_FIXTURES']).iterdir()
             if any(fnmatch.fnmatchcase(p.name, pattern) for pattern in patterns)]
    if not matches:
        raise SystemExit('no matching artifacts')
    for artifact in matches:
        shutil.copytree(artifact, destination/artifact.name)
else:
    raise SystemExit('unexpected gh invocation')
'''


class ArtifactRoles(unittest.TestCase):
    def run_step(self, files):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = root / 'fixtures'
            fixtures.mkdir()
            for name in files:
                path = fixtures / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            binary = root / 'bin'
            binary.mkdir()
            gh = binary / 'gh'
            gh.write_text(f'#!{sys.executable}\n' + FAKE_GH)
            gh.chmod(0o755)
            env = {'PATH': str(binary) + os.pathsep + os.environ['PATH'],
                   'EVENT_NAME': 'workflow_dispatch', 'ARTIFACT_FIXTURES': str(fixtures)}
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script],
                                    cwd=root, env=env, capture_output=True, text=True)
            return result.returncode, result.stdout + result.stderr

    def test_missing_artifacts_are_refused(self):
        # No accepted artifact is not a release, even if its run succeeded.
        self.assertNotEqual(self.run_step([])[0], 0)

    def test_source_packages_do_not_replace_binaries(self):
        # Regression: *.src.rpm also matches the broad tetherloom*.rpm glob.
        status, output = self.run_step(['srpm/tetherloom-server-0.1.1-1.fc44.src.rpm'])
        self.assertNotEqual(status, 0, output)

    def test_binary_packages_do_not_replace_sources(self):
        # A successful binary download must not hide a missing source artifact.
        status, output = self.run_step(['deb-arm64/tetherloom-server_0.1.1_arm64.deb'])
        self.assertNotEqual(status, 0, output)

    def test_debian_and_source_packages_are_admitted(self):
        # Keep the existing acceptance of a Debian binary with source packages.
        status, output = self.run_step(['deb-arm64/tetherloom-server_0.1.1_arm64.deb',
                                       'srpm/tetherloom-server-0.1.1-1.fc44.src.rpm'])
        self.assertEqual(status, 0, output)

    def test_binary_and_source_rpms_are_admitted(self):
        # Excluding source RPMs must keep installable RPMs acceptable.
        status, output = self.run_step(['rpm-fc44/tetherloom-server-0.1.1-1.fc44.x86_64.rpm',
                                       'srpm/tetherloom-server-0.1.1-1.fc44.src.rpm'])
        self.assertEqual(status, 0, output)

    def test_source_rpm_in_a_binary_artifact_is_not_installable(self):
        # A misplaced canonical source RPM is still not a binary package.
        status, output = self.run_step(['rpm-fc44/tetherloom-server-0.1.1-1.fc44.src.rpm',
                                       'srpm/tetherloom-server-0.1.1-1.fc44.src.rpm'])
        self.assertNotEqual(status, 0, output)


if __name__ == '__main__':
    unittest.main()
