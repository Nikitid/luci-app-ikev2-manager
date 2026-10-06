#!/usr/bin/env python3
"""Compile the dedicated managed path from the committed central catalog."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('state_tests', Path(__file__).with_name('test-client-state.py'))
state_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state_tests)


class PathTests(unittest.TestCase):
    def input(self, desired=None, previous=None):
        desired = desired or state_tests.desired()
        result = state_tests.run({'version': 1, 'expected_generation': previous['generation'] if previous else 0,
                                 'previous': previous, 'desired': desired})
        self.assertEqual(result.returncode, 0, result.stderr)
        return {'version': 1, 'state': json.loads(result.stdout), 'exit_link': 'ipsec-out',
                'dns_address': '192.0.2.53', 'dns_port': 53, 'listen_port': 17896}

    def compile(self, value):
        result = state_tests.run(value, 'path')
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_catalog_union_uses_only_the_required_interface(self):
        value = self.input()
        result = self.compile(value)
        config = result['config']
        self.assertEqual([r['override_address'] for r in config['route']['rules'] if r['action'] == 'route'],
                         ['api.example.com', 'chat.example.com'])
        self.assertEqual(config['outbounds'], [{'type': 'direct', 'tag': 'managed-exit',
            'bind_interface': 'ipsec-out', 'domain_resolver': {'server': 'managed-dns', 'strategy': 'ipv4_only'}}])
        self.assertEqual(config['dns']['servers'], [{'type': 'tcp', 'tag': 'managed-dns',
            'server': '192.0.2.53', 'server_port': 53, 'bind_interface': 'ipsec-out'}])
        self.assertEqual(config['route']['rules'][-1],
                         {'inbound': ['tproxy-client-access-in'], 'action': 'reject', 'method': 'drop'})
        self.assertEqual(result['route']['ingress'], 'ipsec-in')
        self.assertNotIn('token_sha256', json.dumps(result))

    def test_changed_domains_retire_old_routes_without_recycling(self):
        initial = self.input()
        desired = state_tests.desired()
        desired['services'][0]['domains'] = ['updated.example.com']
        updated = self.input(desired, initial['state'])
        compiled = self.compile(updated)
        routed = [r for r in compiled['config']['route']['rules'] if r['action'] == 'route']
        self.assertNotIn('api.example.com', [r['override_address'] for r in routed])
        old_address = initial['state']['api']['devices'][0]['policy']['resources'][0]['address']
        self.assertNotIn(old_address + '/32', [cidr for r in routed for cidr in r['ip_cidr']])
        self.assertEqual(updated['state']['publication']['allocations'][:2],
                         initial['state']['publication']['allocations'])

    def test_untrusted_or_unusable_path_inputs_are_refused(self):
        initial = self.input()
        for field, value in [('exit_link', 'eth0'), ('exit_link', 'ipsec-out;command'),
                             ('dns_address', '127.0.0.1'), ('dns_address', '0.0.0.0'),
                             ('dns_address', '224.1.1.1'), ('dns_address', '999.1.1.1'),
                             ('dns_port', 0), ('listen_port', '17896'), ('extra', True)]:
            candidate = copy.deepcopy(initial)
            candidate[field] = value
            result = state_tests.run(candidate, 'path')
            self.assertNotEqual(result.returncode, 0, field)
            self.assertEqual(result.stdout, '')
        initial['state']['api']['devices'][0]['enabled'] = False
        self.assertNotEqual(state_tests.run(initial, 'path').returncode, 0)


if __name__ == '__main__':
    unittest.main()
