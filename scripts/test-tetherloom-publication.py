#!/usr/bin/env python3
"""Exercise publication receipts and exact artifact cleanup without credentials."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

import yaml


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publication', ROOT / 'scripts/tetherloom-publication.py')
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class Publication(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, self.previous)
        self.state = Path('pending.json')
        self.output = Path('output')
        self.run = {'id': 123, 'repository': {'full_name': publication.REPOSITORY},
                    'event': 'release', 'name': 'Release', 'path': '.github/workflows/release.yml',
                    'head_branch': 'v1.2.3', 'head_sha': 'a' * 40,
                    'status': 'completed', 'conclusion': 'success', 'run_attempt': 1}
        self.artifacts = {i: {'id': i, 'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
                          for i in (11, 12)}
        self.deleted = []
        self.fail = None
        self.patcher = patch.object(publication, 'api', self.api)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def api(self, method, path):
        if path == publication.PREFIX + '/runs/123':
            return copy.deepcopy(self.run)
        if '/artifacts?' in path:
            page = int(path.split('page=')[-1])
            values = list(self.artifacts.values())
            return {'artifacts': copy.deepcopy(values[(page - 1) * 100:page * 100])}
        artifact_id = int(path.rsplit('/', 1)[1])
        if method == 'DELETE':
            if artifact_id == self.fail:
                raise PermissionError('deletion denied')
            self.deleted.append(artifact_id)
            self.artifacts.pop(artifact_id, None)
            return None
        return copy.deepcopy(self.artifacts.get(artifact_id))

    def prepare(self):
        publication.prepare(123, self.state, self.output)

    def commit(self):
        subprocess.run(['git', 'init', '-q'], check=True)
        subprocess.run(['git', 'add', '.publications'], check=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.org',
                        'commit', '-qm', 'Publish fixture'], check=True)

    def publish(self):
        self.prepare()
        publication.seal(self.state)
        self.commit()

    def retry_checkout(self):
        # A rerun keeps its original event commit; checkout may explicitly select main.
        event = subprocess.run(['git', 'rev-parse', 'HEAD~1'], check=True,
                               capture_output=True, text=True).stdout.strip()
        subprocess.run(['git', 'branch', '-f', 'published-main', 'HEAD'], check=True)
        subprocess.run(['git', 'checkout', '-q', '--detach', event], check=True)
        workflow = yaml.safe_load((ROOT / '.github/workflows/publish.yml').read_text())
        checkout = next(step for step in workflow['jobs']['publish']['steps']
                        if step.get('name') == 'Checkout repo')
        ref = checkout['with'].get('ref')
        if ref == 'main':
            subprocess.run(['git', 'checkout', '-q', '--detach', 'published-main'], check=True)
        elif ref is not None:
            self.fail(f'unexpected publication checkout ref: {ref}')

    def event_commit(self):
        subprocess.run(['git', 'init', '-q'], check=True)
        Path('event').write_text('event before publication\n')
        subprocess.run(['git', 'add', 'event'], check=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.org',
                        'commit', '-qm', 'Event fixture'], check=True)

    def test_workflow_rerun_after_complete_cleanup_reads_pushed_receipt(self):
        # Reproduces event-SHA checkout after every transfer artifact has been retired.
        self.event_commit()
        self.publish()
        publication.cleanup(self.state)
        self.retry_checkout()
        self.output.unlink()
        self.prepare()
        self.assertIn('published=true\n', self.output.read_text())
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])

    def test_failed_publication_cannot_delete_artifacts(self):
        # Even a sealed local receipt cannot authorize deletion before its commit.
        self.prepare()
        publication.seal(self.state)
        with self.assertRaises(subprocess.CalledProcessError):
            publication.cleanup(self.state)
        self.assertEqual(self.deleted, [])

    def test_successful_publication_retires_exact_ids(self):
        # A newer upload, even with the same source identity, is outside the receipt.
        self.publish()
        self.artifacts[13] = {'id': 13, 'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
        self.run['run_attempt'] = 2
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])
        self.assertEqual(list(self.artifacts), [13])

    def test_duplicate_delivery_needs_no_deleted_downloads(self):
        # The committed receipt survives retirement and selects the cleanup-only path.
        self.publish()
        publication.cleanup(self.state)
        self.output.unlink()
        self.prepare()
        self.assertIn('published=true\n', self.output.read_text())
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])

    def test_partial_cleanup_resumes_after_permission_failure(self):
        # Deletion failures propagate, while the durable ID set makes retry safe.
        self.publish()
        self.fail = 12
        with self.assertRaises(PermissionError):
            publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11])
        self.fail = None
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])

    def test_old_dispatch_resumes_partial_cleanup_during_new_attempt(self):
        # A published attempt remains eligible for cleanup when a new build starts.
        self.publish()
        self.fail = 12
        with self.assertRaises(PermissionError):
            publication.cleanup(self.state)
        self.fail = None
        self.run.update(run_attempt=2, status='in_progress', conclusion=None)
        self.artifacts[13] = {'id': 13, 'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
        self.output.unlink()
        publication.prepare(123, self.state, self.output, expected_attempt=1)
        self.assertIn('published=true\n', self.output.read_text())
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])
        self.assertEqual(list(self.artifacts), [13])

    def test_old_dispatch_resumes_cleanup_after_new_attempt_failed(self):
        # A later failed attempt cannot revoke the earlier committed cleanup fact.
        self.publish()
        self.run.update(run_attempt=2, status='completed', conclusion='failure')
        self.output.unlink()
        publication.prepare(123, self.state, self.output, expected_attempt=1)
        self.assertIn('published=true\n', self.output.read_text())
        publication.cleanup(self.state)
        self.assertEqual(self.deleted, [11, 12])

    def test_other_run_is_rejected_before_any_delete(self):
        # All surviving IDs are checked before deleting any member of the set.
        self.publish()
        self.artifacts[12]['workflow_run']['id'] = 456
        with self.assertRaises(ValueError):
            publication.cleanup(self.state)
        self.assertEqual(self.deleted, [])

    def test_source_access_failure_is_not_mistaken_for_deleted_artifacts(self):
        # GitHub hides private objects behind 404; verify source access first.
        self.publish()
        api = self.api

        def denied(method, path):
            if path.endswith('/runs/123'):
                raise PermissionError('source repository is inaccessible')
            return api(method, path)

        with patch.object(publication, 'api', denied):
            with self.assertRaises(PermissionError):
                publication.cleanup(self.state)
        self.assertEqual(self.deleted, [])

    def test_rerun_during_download_prevents_sealing(self):
        # A run attempt is not interchangeable with another attempt of the same run.
        self.prepare()
        self.run['run_attempt'] = 2
        with self.assertRaises(ValueError):
            publication.seal(self.state)
        self.assertFalse(Path('.publications').exists())

    def test_replacement_artifact_prevents_sealing(self):
        # A changed artifact set invalidates the download-to-publication snapshot.
        self.prepare()
        self.artifacts[13] = self.artifacts.pop(12)
        self.artifacts[13]['id'] = 13
        with self.assertRaises(ValueError):
            publication.seal(self.state)

    def test_new_attempt_does_not_reuse_old_receipt(self):
        # A later attempt must be consumed and published independently.
        self.publish()
        self.run['run_attempt'] = 2
        self.output.unlink()
        self.prepare()
        self.assertIn('published=false\n', self.output.read_text())
        self.assertIn('123-2.json', self.output.read_text())

    def test_failed_source_run_is_refused(self):
        # A successful repository push must not be prepared from a failed release.
        self.run['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            self.prepare()

    def test_in_progress_dispatch_requires_matching_attempt(self):
        # An old dispatch must not admit a new, unfinished rerun of the same ID.
        self.run['status'] = 'in_progress'
        self.run['conclusion'] = None
        self.run['run_attempt'] = 2
        with self.assertRaises(ValueError):
            self.prepare()
        with self.assertRaises(ValueError):
            publication.prepare(123, self.state, self.output, expected_attempt=1)
        publication.prepare(123, self.state, self.output, expected_attempt=2)
        publication.seal(self.state)

    def test_pagination_preserves_every_id(self):
        # Cleanup must not silently retain all artifacts after the API's first page.
        self.artifacts = {i: {'id': i} for i in range(1, 103)}
        self.prepare()
        self.assertEqual(json.loads(self.state.read_text())['artifacts'], list(range(1, 103)))

    def test_modified_receipt_cannot_authorize_deletion(self):
        # An edited local state file is not the receipt committed with packages.
        self.publish()
        receipt = json.loads(self.state.read_text())
        receipt['artifacts'] = [11]
        publication.save(self.state, receipt)
        with self.assertRaises(ValueError):
            publication.cleanup(self.state)
        self.assertEqual(self.deleted, [])

    def test_prepare_command_writes_workflow_outputs(self):
        # Exercise the CLI argument and environment path used by the workflow.
        with patch('sys.argv', ['publication', 'prepare', '--run-id', '123',
                                '--state', str(self.state)]), \
                patch.dict(os.environ, {'GITHUB_OUTPUT': str(self.output)}):
            publication.main()
        self.assertEqual(self.output.read_text(),
                         'published=false\nreceipt_path=.publications/tetherloom/123-1.json\n')


class GitHubAPI(unittest.TestCase):
    def test_delete_uses_scoped_endpoint_and_empty_response(self):
        # HTTP 204 has no JSON body; the token stays in the request header.
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture-token'}), \
                patch('urllib.request.urlopen', return_value=io.BytesIO(b'')) as send:
            self.assertIsNone(publication.api('DELETE', publication.PREFIX + '/artifacts/11'))
        request = send.call_args.args[0]
        self.assertEqual(request.method, 'DELETE')
        self.assertEqual(request.full_url,
                         'https://api.github.com/repos/structured-world/tetherloom/actions/artifacts/11')
        self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-token')
        self.assertEqual(send.call_args.kwargs['timeout'], 30)

    def test_only_missing_artifacts_are_idempotent(self):
        # Rate limits and permission errors must remain visible failures.
        for status in (403, 404, 429, 500):
            error = urllib.error.HTTPError('https://api.github.com', status, 'fixture', {}, None)
            with self.subTest(status=status), patch.dict(os.environ, {'GH_TOKEN': 'fixture'}), \
                    patch('urllib.request.urlopen', side_effect=error):
                if status == 404:
                    self.assertIsNone(publication.api('DELETE', publication.PREFIX + '/artifacts/11'))
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        publication.api('DELETE', publication.PREFIX + '/artifacts/11')

    def test_inaccessible_run_is_not_a_missing_artifact(self):
        # A repository-level 404 must not make all deletions appear successful.
        error = urllib.error.HTTPError('https://api.github.com', 404, 'fixture', {}, None)
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}), \
                patch('urllib.request.urlopen', side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                publication.api('GET', publication.PREFIX + '/runs/123')


class Workflow(unittest.TestCase):
    def test_cleanup_is_after_push_with_a_separate_write_token(self):
        # The consumer owns deletion, and its download token remains read-only.
        workflow = yaml.safe_load((ROOT / '.github/workflows/publish.yml').read_text())
        steps = workflow['jobs']['publish']['steps']
        names = [step.get('name') for step in steps]
        self.assertLess(names.index('Commit and push'), names.index('Retire published Tetherloom artifacts'))
        read = steps[names.index('Generate Tetherloom read token')]
        write = steps[names.index('Generate Tetherloom cleanup token')]
        self.assertEqual(read['with']['permission-actions'], 'read')
        self.assertEqual(write['with']['permission-actions'], 'write')
        self.assertEqual(write['with']['repositories'], 'tetherloom')
        cleanup = steps[names.index('Retire published Tetherloom artifacts')]
        self.assertNotIn('always()', cleanup.get('if', ''))
        download = steps[names.index('Download tetherloom artifacts')]
        self.assertIn("steps.tetherloom-publication.outputs.published != 'true'", download['if'])
        self.assertIn('git add -- "$TETHERLOOM_RECEIPT"', steps[names.index('Commit and push')]['run'])
        for name in ('Prepare package metadata', 'Update package repositories', 'Build docs'):
            self.assertIn("steps.tetherloom-publication.outputs.published != 'true'", steps[names.index(name)]['if'])


if __name__ == '__main__':
    unittest.main()
