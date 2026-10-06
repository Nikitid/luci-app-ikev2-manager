#!/usr/bin/env python3
"""Device policy publication from a server-owned service catalog."""
import copy
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPILER = Path(os.environ.get('CLIENT_ACCESS_COMPILER', ROOT / 'ikev2-manager-runtime/lib/client-access-policy.uc'))


def proposal():
    return {'version': 1, 'server': {'address': 'vpn.example.com', 'remote_id': 'vpn.example.com'},
            'virtual_subnet': '172.31.254.0/24', 'exit': '1', 'allocations': [],
            'services': [{'id': name, 'client_access': True, 'domains': [name + '.example.com'],
                          'transports': [{'protocol': 'tcp', 'ports': [443]}]} for name in ['api', 'chat']],
            'devices': [{'id': name, 'token_sha256': token * 64, 'enabled': True,
                         'selected_services': [service], 'previous_policy': None}
                        for name, token, service in [('alice', 'a', 'api'), ('bob', 'b', 'chat')]]}


def run(value):
    return subprocess.run(['ucode', str(COMPILER), 'publish'], input=json.dumps(value),
                          text=True, capture_output=True)


class PublicationTests(unittest.TestCase):
    def publish(self, value):
        result = run(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def retain(self, value, output):
        value['allocations'] = output['allocations']
        for device, published in zip(value['devices'], output['api']['devices']):
            device['previous_policy'] = published['policy']

    def test_devices_get_only_assigned_services(self):
        output = self.publish(proposal())
        self.assertEqual(len(output['allocations']), 2)
        for index, domain in enumerate(['api.example.com', 'chat.example.com']):
            policy = output['api']['devices'][index]['policy']
            self.assertEqual([r['domain'] for r in policy['resources']], [domain])
            self.assertEqual(policy['revision'], 1)

    def test_update_is_stable_and_revisions_are_per_device(self):
        value = proposal()
        initial = self.publish(value)
        self.retain(value, initial)
        value['services'].reverse()
        unchanged = self.publish(value)
        self.assertEqual(unchanged, initial)
        value['services'][1]['domains'].append('new.example.com')
        updated = self.publish(value)
        self.assertEqual(updated['allocations'][:2], initial['allocations'])
        self.assertEqual([d['policy']['revision'] for d in updated['api']['devices']], [2, 1])
        self.retain(value, updated)
        value['services'][1]['domains'] = ['new.example.com']
        retired = self.publish(value)
        self.assertEqual(retired['allocations'], updated['allocations'])
        self.assertEqual(retired['api']['devices'][0]['policy']['revision'], 3)

    def test_removal_disables_retrieval_and_retains_last_policy(self):
        value = proposal()
        initial = self.publish(value)
        self.retain(value, initial)
        value['devices'][0]['selected_services'] = []
        output = self.publish(value)
        self.assertFalse(output['api']['devices'][0]['enabled'])
        self.assertEqual(output['api']['devices'][0]['policy'], initial['api']['devices'][0]['policy'])
        self.assertTrue(output['api']['devices'][1]['enabled'])

    def test_refuses_invalid_assignments_identity_allocations_and_duplicates(self):
        value = proposal()
        self.retain(value, self.publish(value))
        variants = []
        for field, new in [('selected_services', ['unknown']), ('id', 'other'), ('token_sha256', 'b' * 64)]:
            candidate = copy.deepcopy(value)
            candidate['devices'][0][field] = new
            variants.append(candidate)
        candidate = copy.deepcopy(value)
        candidate['allocations'] = []
        candidate['services'].reverse()
        variants.append(candidate)
        candidate = copy.deepcopy(value)
        candidate['server']['remote_id'] = 'other.example.com'
        variants.append(candidate)
        candidate = copy.deepcopy(value)
        candidate['devices'][0]['previous_policy']['revision'] = 2147483647
        candidate['exit'] = '2'
        variants.append(candidate)
        candidate = copy.deepcopy(value)
        candidate['services'][0]['client_access'] = False
        variants.append(candidate)
        for candidate in variants:
            result = run(candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
