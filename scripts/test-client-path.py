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
                'dns_address': '192.0.2.53', 'dns_port': 53, 'listen_port': 17896,
                'runtime_dir': '/var/run/ikev2-client-access'}

    def compile(self, value):
        result = state_tests.run(value, 'path')
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_catalog_union_uses_only_the_required_interface(self):
        value = self.input()
        result = self.compile(value)
        config = result['config']
        self.assertEqual([r['override_address'] for r in config['route']['rules'] if r.get('outbound') == 'managed-exit' and 'override_address' in r],
                         ['api.example.com', 'chat.example.com'])
        # The only way out to the Internet is the required interface; the other
        # outbound is the loopback front for names over HTTPS and is reached
        # by one rule alone.
        self.assertEqual(config['outbounds'], [{'type': 'direct', 'tag': 'managed-exit',
            'bind_interface': 'ipsec-out', 'domain_resolver': {'server': 'managed-dns', 'strategy': 'ipv4_only'}},
            {'type': 'direct', 'tag': 'names-front', 'domain_resolver': {'server': 'managed-dns', 'strategy': 'ipv4_only'}}])
        self.assertEqual([r for r in config['route']['rules'] if r.get('outbound') == 'names-front'],
                         [{'inbound': ['tproxy-client-access-in'], 'ip_cidr': ['172.31.254.127/32'], 'network': ['tcp'], 'port': [443],
                           'action': 'route', 'outbound': 'names-front', 'override_address': '127.0.0.1', 'override_port': 17898}])
        self.assertEqual(config['route']['final'], 'managed-exit')
        self.assertEqual(config['dns']['servers'], [{'type': 'tcp', 'tag': 'managed-dns',
            'server': '192.0.2.53', 'server_port': 53, 'bind_interface': 'ipsec-out'},
            {'type': 'fakeip', 'tag': 'managed-names', 'inet4_range': '172.31.254.128/25'}])
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
        routed = [r for r in compiled['config']['route']['rules'] if 'override_address' in r]
        self.assertNotIn('api.example.com', [r['override_address'] for r in routed])
        self.assertNotIn('api.example.com', json.dumps(compiled['config']))
        old_address = initial['state']['api']['devices'][0]['policy']['resources'][0]['address']
        self.assertNotIn(old_address + '/32', [cidr for r in routed for cidr in r['ip_cidr']])
        self.assertEqual(updated['state']['publication']['allocations'][:2],
                         initial['state']['publication']['allocations'])

    def test_names_under_a_service_are_answered_and_carried_only_for_its_devices(self):
        config = self.compile(self.input())['config']
        hijack = config['route']['rules'][0]
        self.assertEqual(hijack, {'inbound': ['tproxy-client-access-in'], 'ip_cidr': ['172.31.254.127/32'],
                                  'port': [53], 'action': 'hijack-dns'})
        sets = {item['tag']: item for item in config['route']['rule_set']}
        self.assertTrue(sets and all(item['type'] == 'local' and item['path'] ==
                        '/var/run/ikev2-client-access/' + tag + '.json' for tag, item in sets.items()))
        answers = [r for r in config['dns']['rules'] if r.get('server') == 'managed-names' and r['inbound'] == ['tproxy-client-access-in']]
        self.assertEqual(len(answers), len(sets))
        for rule in answers:
            # Only A, only from the service's own devices, only the domain
            # itself and what is under it - never a name that merely ends alike.
            self.assertEqual(rule['query_type'], ['A'])
            self.assertTrue(rule['rule_set_ip_cidr_match_source'] and rule['rule_set'][0] in sets)
            self.assertEqual(rule['domain_suffix'], ['.' + name for name in rule['domain']])
        plain = [r for r in config['dns']['rules'] if r['inbound'] == ['tproxy-client-access-in']]
        self.assertEqual(plain[-1], {'inbound': ['tproxy-client-access-in'], 'action': 'predefined', 'rcode': 'REFUSED'})
        # Names over HTTPS come from the loopback front: the same names get an
        # address, every other record type is empty, anything else is refused,
        # and nothing asked there ever reaches the resolver of the exit.
        front = [r for r in config['dns']['rules'] if r['inbound'] == ['names-local-in']]
        self.assertEqual(sorted(sum((r['domain'] for r in front if r.get('server') == 'managed-names'), [])),
                         sorted(sum((r['domain'] for r in answers), [])))
        self.assertTrue(all(r['query_type'] == ['A'] for r in front if r.get('server') == 'managed-names'))
        self.assertEqual(front[-1], {'inbound': ['names-local-in'], 'action': 'predefined', 'rcode': 'REFUSED'})
        self.assertEqual(config['dns']['rules'][-1], front[-1])
        self.assertIn({'inbound': ['names-local-in'], 'action': 'hijack-dns'}, config['route']['rules'])
        self.assertIn({'type': 'direct', 'tag': 'names-local-in', 'listen': '127.0.0.1', 'listen_port': 17897}, config['inbounds'])
        named = [r for r in config['route']['rules'] if r.get('rule_set')]
        self.assertTrue(named)
        for rule in named:
            self.assertTrue(rule['rule_set_ip_cidr_match_source'])
            self.assertNotIn('ip_cidr', rule, 'an address condition would admit every name')
            self.assertEqual(rule['outbound'], 'managed-exit')
            self.assertTrue(rule['port'] and rule['network'])
        self.assertEqual(config['route']['rules'][-1]['action'], 'reject')
        self.assertTrue(config['experimental']['cache_file']['store_fakeip'])

    def test_untrusted_or_unusable_path_inputs_are_refused(self):
        initial = self.input()
        for field, value in [('exit_link', 'eth0'), ('exit_link', 'ipsec-out;command'),
                             ('dns_address', '127.0.0.1'), ('dns_address', '0.0.0.0'),
                             ('dns_address', '224.1.1.1'), ('dns_address', '999.1.1.1'),
                             ('dns_port', 0), ('listen_port', '17896'), ('extra', True),
                             ('runtime_dir', 'relative'), ('runtime_dir', '/var/run/../etc'),
                             ('runtime_dir', '/var/run/a b')]:
            candidate = copy.deepcopy(initial)
            candidate[field] = value
            result = state_tests.run(candidate, 'path')
            self.assertNotEqual(result.returncode, 0, field)
            self.assertEqual(result.stdout, '')
        # The path is compiled every two seconds from the snapshot the publisher
        # committed; the snapshot is compiled and compared where it is changed,
        # not here. What has no publication, or a broken catalog, is still refused.
        broken = copy.deepcopy(initial); del broken['state']['publication']
        self.assertNotEqual(state_tests.run(broken, 'path').returncode, 0)
        broken = copy.deepcopy(initial); broken['state']['publication']['services'][0]['domains'].append('not a domain')
        self.assertNotEqual(state_tests.run(broken, 'path').returncode, 0)


if __name__ == '__main__':
    unittest.main()
