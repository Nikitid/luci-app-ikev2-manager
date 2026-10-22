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

    def test_networks_are_granted_by_device_network_and_port_and_marked_only_from_the_sa(self):
        value = fixture()
        policy = value['api']['devices'][0]['policy']
        policy['version'] = 2
        policy['networks'] = [{'network': '149.154.160.0/20', 'transports': [{'protocol': 'tcp', 'ports': [443]},
                                                                             {'protocol': 'udp', 'ports': [3478]}]}]
        result = self.reconcile(value)
        self.assertEqual(result['networks_tcp'], ['10.25.0.10 . 149.154.160.0/20 . 443'])
        self.assertEqual(result['networks_udp'], ['10.25.0.10 . 149.154.160.0/20 . 3478'])
        nft = result['nft']
        # Granted in an interval set, marked only for the session's own SA,
        # found again just before routing, and never dropped by this table.
        self.assertIn('flags interval,timeout', nft)
        self.assertIn('ip saddr 10.25.0.10 ipsec in reqid 12 ipsec in spi 0x01234567 jump authorize_network_services', nft)
        self.assertIn('hook prerouting priority 290', nft)
        networks = nft.split('chain authorize_networks {')[1].split('}')[0]
        self.assertNotIn('drop', networks)
        # A device without networks is granted none.
        del policy['networks']
        policy['version'] = 1
        self.assertEqual(self.reconcile(value)['networks_tcp'], [])

    def test_closed_device_with_an_older_exit_does_not_stop_the_open_ones(self):
        # A removed device keeps the policy it last had; the administrator has
        # since chosen another exit. The open device must still be admitted.
        value = fixture()
        old = copy.deepcopy(value['api']['devices'][0])
        old.update({'id': 'gone', 'token_sha256': 'b' * 64, 'enabled': False})
        old['policy'] = copy.deepcopy(old['policy'])
        old['policy'].update({'id': 'gone', 'exit': '2' if value['api']['devices'][0]['policy']['exit'] != '2' else '1'})
        value['api']['devices'].append(old)
        self.assertEqual(len(self.reconcile(value)['tcp_in']), 1)

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
