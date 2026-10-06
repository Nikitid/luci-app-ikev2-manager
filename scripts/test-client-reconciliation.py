#!/usr/bin/env python3
"""Join published device assignments to authenticated local VICI evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPILER = Path(os.environ.get('CLIENT_ACCESS_COMPILER', ROOT / 'ikev2-manager-runtime/lib/client-access-policy.uc'))


def fixture():
    spec = importlib.util.spec_from_file_location('sessions', ROOT / 'scripts/test-client-sessions.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    policy = copy.deepcopy(json.loads((ROOT / 'desktop-clients/fixtures/policies.json').read_text())[0]['policy'])
    return {'version': 1, 'pool': {'first': '10.25.0.10', 'last': '10.25.0.100'},
            'api': {'version': 1, 'devices': [{'id': 'alice', 'token_sha256': 'a' * 64,
                                            'enabled': True, 'policy': policy}]},
            'snapshot': module.snapshot(), 'lease_seconds': 30}


def run(value):
    return subprocess.run(['ucode', str(COMPILER), 'reconcile'], input=json.dumps(value),
                          text=True, capture_output=True)


class ReconciliationTests(unittest.TestCase):
    def reconcile(self, value):
        result = run(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_valid_identity_is_bound_and_disabled_or_unknown_is_denied(self):
        value = fixture()
        result = self.reconcile(value)
        self.assertEqual(result['tcp_in'], ['12 . 0x01234567 . 10.25.0.10 . 172.31.254.1 . 443'])
        self.assertEqual(result['tcp_out'], ['12 . 0x89abcdef . 10.25.0.10 . 172.31.254.1 . 443'])
        value['api']['devices'][0]['enabled'] = False
        self.assertEqual(self.reconcile(value)['tcp_in'], [])
        value['api']['devices'][0]['enabled'] = True
        value['snapshot']['data'][0]['ikev2-in']['remote-eap-id'] = 'unknown'
        self.assertEqual(self.reconcile(value)['tcp_out'], [])

    def test_incomplete_sa_and_ambiguous_owners_never_receive_a_grant(self):
        value = fixture()
        value['snapshot']['data'][0]['ikev2-in']['state'] = 'CONNECTING'
        self.assertEqual(self.reconcile(value)['tcp_in'], [])
        value = fixture()
        other = copy.deepcopy(value['snapshot']['data'][0])
        other['ikev2-in']['remote-eap-id'] = 'unknown'
        value['snapshot']['data'].append(other)
        result = self.reconcile(value)
        self.assertEqual(result['ambiguous_addresses'], 1)
        self.assertEqual(result['tcp_in'], [])

    def test_local_state_or_vici_errors_cannot_become_empty_success(self):
        for mutate in [lambda v: v['api']['devices'][0].update(token_sha256='invalid'),
                       lambda v: v['api']['devices'].append(copy.deepcopy(v['api']['devices'][0])),
                       lambda v: v['snapshot'].update(errors=['unavailable']),
                       lambda v: v['api']['devices'][0]['policy'].update(password='must-not-be-returned')]:
            value = fixture()
            mutate(value)
            result = run(value)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('must-not-be-returned', result.stderr)


if __name__ == '__main__':
    unittest.main()
