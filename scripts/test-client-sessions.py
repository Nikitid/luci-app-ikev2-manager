#!/usr/bin/env python3
"""Require authenticated inbound identity plus installed kernel SA evidence."""
import copy
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPILER = Path(os.environ.get('CLIENT_ACCESS_COMPILER', ROOT / 'ikev2-manager-runtime/lib/client-access-policy.uc'))


def snapshot():
    return {'errors': [], 'data': [{'ikev2-in': {'version': '2', 'state': 'ESTABLISHED',
        'remote-eap-id': 'alice', 'remote-vips': ['10.25.0.10'], 'child-sas': {'net-1': {
        'name': 'net', 'state': 'INSTALLED', 'mode': 'TUNNEL', 'protocol': 'ESP',
        'if-id-in': '0000002b', 'if-id-out': '0000002b', 'reqid': '12',
        'spi-in': '01234567', 'spi-out': '89abcdef', 'remote-ts': ['10.25.0.10/32']}}}}]}


def run(value):
    return subprocess.run(['ucode', str(COMPILER), 'sessions'], input=json.dumps(value),
                          text=True, capture_output=True)


class SessionsTests(unittest.TestCase):
    def sessions(self, value):
        result = run(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_authenticated_installed_session_retains_kernel_binding(self):
        self.assertEqual(self.sessions(snapshot()), [{'identity': 'alice', 'address': '10.25.0.10',
            'reqid': 12, 'spi_in': '01234567', 'spi_out': '89abcdef'}])
        value = snapshot()
        value['data'][0]['site-link'] = value['data'][0].pop('ikev2-in')
        self.assertEqual(self.sessions(value), [])

    def test_vici_omits_eap_field_when_authenticated_identities_match(self):
        value = snapshot()
        sa = value['data'][0]['ikev2-in']
        del sa['remote-eap-id']
        sa['remote-id'] = 'alice'
        self.assertEqual(self.sessions(value)[0]['identity'], 'alice')
        sa['remote-eap-id'] = 'bob'
        self.assertEqual(self.sessions(value)[0]['identity'], 'bob')
        for invalid in [None, '', 'bad\nidentity']:
            sa['remote-eap-id'] = invalid
            self.assertEqual(self.sessions(value), [])
        del sa['remote-eap-id']
        sa['remote-id'] = 'bad\nidentity'
        self.assertEqual(self.sessions(value), [])

    def test_incomplete_unauthenticated_or_other_interface_never_admits(self):
        for field, value in [('version', '1'), ('state', 'CONNECTING'), ('state', 'DELETING'),
                             ('remote-eap-id', None), ('remote-eap-id', 'bad\nidentity'),
                             ('remote-vips', ['10.25.0.10', '10.25.0.11']),
                             ('remote-vips', ['999.25.0.10']), ('child-sas', {})]:
            candidate = snapshot()
            candidate['data'][0]['ikev2-in'][field] = value
            self.assertEqual(self.sessions(candidate), [], field)
        for field, value in [('name', 'other'), ('state', 'INSTALLING'), ('state', 'RETRYING'), ('state', 'ROUTED'), ('state', 'DELETING'),
                             ('mode', 'TRANSPORT'), ('protocol', 'AH'), ('if-id-in', '0000002a'),
                             ('if-id-out', '00000034'), ('reqid', '0'), ('reqid', '4294967296'),
                             ('spi-in', '00000000'), ('spi-out', 'bad'),
                             ('remote-ts', ['0.0.0.0/0']), ('remote-ts', ['10.25.0.11/32']),
                             ('remote-ts', ['10.25.0.10/32', '0.0.0.0/0'])]:
            candidate = snapshot()
            candidate['data'][0]['ikev2-in']['child-sas']['net-1'][field] = value
            self.assertEqual(self.sessions(candidate), [], field)

    def test_rekey_and_conflicting_owners_remain_visible_to_guard(self):
        value = snapshot()
        other = copy.deepcopy(value['data'][0])
        other['ikev2-in']['remote-eap-id'] = 'bob'
        other['ikev2-in']['child-sas']['net-1']['reqid'] = '13'
        value['data'].append(other)
        self.assertEqual([item['identity'] for item in self.sessions(value)], ['alice', 'bob'])
        other['ikev2-in']['remote-eap-id'] = 'alice'
        self.assertEqual(len(self.sessions(value)), 2)

    def test_authenticated_rekey_keeps_installed_child_bindings(self):
        for ike_state in ['ESTABLISHED', 'REKEYING', 'REKEYED']:
            for child_state in ['INSTALLED', 'UPDATING', 'REKEYING', 'REKEYED']:
                value = snapshot()
                sa = value['data'][0]['ikev2-in']
                sa['state'] = ike_state
                sa['child-sas']['net-1']['state'] = child_state
                self.assertEqual(len(self.sessions(value)), 1, (ike_state, child_state))
        value = snapshot()
        value['data'][0]['ikev2-in']['state'] = 'REKEYING'
        value['data'][0]['ikev2-in']['remote-eap-id'] = None
        self.assertEqual(self.sessions(value), [])

    def test_failed_snapshot_is_error_not_empty_authenticated_state(self):
        for value in [{}, {'errors': ['unavailable'], 'data': []}, {'errors': [], 'data': [None]},
                      {'errors': [], 'data': [{'ikev2-in': 'invalid'}]}]:
            result = run(value)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
