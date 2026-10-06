#!/usr/bin/env python3
"""Exercise policy compilation, not source spelling or simulated OS rules."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPILER = Path(os.environ.get('CLIENT_ACCESS_COMPILER', ROOT / 'ikev2-manager-runtime/lib/client-access-policy.uc'))
POLICY = {
    'version': 1, 'id': 'example', 'revision': 1,
    'server': {'address': 'vpn.example.com', 'remote_id': 'vpn.example.com'},
    'virtual_subnet': '172.31.254.0/24', 'exit': '1',
    'resources': [{'id': 'api', 'domain': 'api.example.com', 'address': '172.31.254.1', 'transports': [{'protocol': 'tcp', 'ports': [443]}]}],
}


def compile_policy(policy):
    return subprocess.run(['ucode', str(COMPILER)], input=json.dumps(policy), text=True, capture_output=True)


class PolicyTests(unittest.TestCase):
    def test_shared_desktop_policy_fixtures(self):
        fixtures = json.loads((ROOT / 'desktop-clients/fixtures/policies.json').read_text())
        for fixture in fixtures:
            with self.subTest(name=fixture['name']):
                result = compile_policy(fixture['policy'])
                self.assertEqual(result.returncode == 0, fixture['valid'], result.stderr)

    def authorization_input(self):
        other = copy.deepcopy(POLICY)
        other['id'] = 'other'
        other['resources'][0].update(id='other-api', domain='other.example.com', address='172.31.254.2')
        return {'version': 1, 'pool': {'first': '10.25.0.10', 'last': '10.25.0.100'},
                'policies': [copy.deepcopy(POLICY), other],
                'users': [{'identity': 'alice', 'policy': 'example'}, {'identity': 'bob', 'policy': 'other'}],
                'sessions': [{'identity': 'alice', 'address': '10.25.0.10', 'reqid': 12, 'spi_in': '00000100', 'spi_out': '00000200'},
                             {'identity': 'bob', 'address': '10.25.0.11', 'reqid': 13, 'spi_in': '00000300', 'spi_out': '00000400'}], 'lease_seconds': 30}

    def authorize(self, data):
        return subprocess.run(['ucode', str(COMPILER), 'authorize'], input=json.dumps(data),
                              text=True, capture_output=True)

    def test_authorization_uses_identity_not_possession_of_an_address(self):
        data = self.authorization_input()
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['tcp'], ['10.25.0.10 . 172.31.254.1 . 443',
                                         '10.25.0.11 . 172.31.254.2 . 443'])
        self.assertEqual(output['udp'], [])
        data['sessions'][0]['identity'] = 'unknown'
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['tcp'], ['10.25.0.11 . 172.31.254.2 . 443'])

    def test_ambiguous_reused_address_and_out_of_pool_session_are_denied(self):
        data = self.authorization_input()
        data['sessions'] += [{'identity': 'unknown', 'address': '10.25.0.10', 'reqid': 14, 'spi_in': '00000500', 'spi_out': '00000600'},
                             {'identity': 'alice', 'address': '192.0.2.5', 'reqid': 15, 'spi_in': '00000700', 'spi_out': '00000800'}]
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['ambiguous_addresses'], 1)
        self.assertEqual(output['tcp'], ['10.25.0.11 . 172.31.254.2 . 443'])
        data['sessions'] = []
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['tcp'], [])

    def test_revoking_user_removes_its_authorization(self):
        data = self.authorization_input()
        data['users'] = []
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['tcp'], [])
        self.assertEqual(output['udp'], [])

    def test_authorization_refuses_conflicting_policy_addresses_and_pool(self):
        data = self.authorization_input()
        data['policies'][1]['resources'][0]['address'] = '172.31.254.1'
        result = self.authorize(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        data = self.authorization_input()
        data['pool'] = {'first': '172.31.254.10', 'last': '172.31.254.100'}
        result = self.authorize(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_authorization_binds_both_directions_and_preserves_rekey_children(self):
        data = self.authorization_input()
        rekey = dict(data['sessions'][0], spi_in='00000101', spi_out='00000201')
        data['sessions'].append(rekey)
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['tcp_in'][:2], [
            '12 . 0x00000100 . 10.25.0.10 . 172.31.254.1 . 443',
            '12 . 0x00000101 . 10.25.0.10 . 172.31.254.1 . 443'])
        self.assertEqual(output['tcp_out'][:2], [
            '12 . 0x00000200 . 10.25.0.10 . 172.31.254.1 . 443',
            '12 . 0x00000201 . 10.25.0.10 . 172.31.254.1 . 443'])
        self.assertEqual(len(output['tcp']), 2)

    def test_authorization_rejects_address_only_and_malformed_sa_evidence(self):
        for field, value in [('reqid', 0), ('reqid', True), ('reqid', 4294967296),
                             ('spi_in', '00000000'), ('spi_out', '0x123'), ('spi_in', None)]:
            data = self.authorization_input()
            data['sessions'][0][field] = value
            result = self.authorize(data)
            self.assertNotEqual(result.returncode, 0, field)
            self.assertEqual(result.stdout, '')
        data = self.authorization_input()
        data['sessions'][0] = {'identity': 'alice', 'address': '10.25.0.10'}
        self.assertNotEqual(self.authorize(data).returncode, 0)

    def test_same_sa_cannot_authorize_two_owners_or_virtual_addresses(self):
        data = self.authorization_input()
        duplicate = dict(data['sessions'][0], identity='bob', address='10.25.0.12', spi_out='00000500')
        data['sessions'].append(duplicate)
        result = self.authorize(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['ambiguous_addresses'], 2)
        self.assertEqual(output['tcp_in'], ['13 . 0x00000300 . 10.25.0.11 . 172.31.254.2 . 443'])

    def allocate(self, catalog):
        result = subprocess.run(['ucode', str(COMPILER), 'allocate'], input=json.dumps(catalog),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_catalog_updates_preserve_addresses_and_retired_allocations(self):
        catalog = {'version': 1, 'virtual_subnet': '172.31.240.0/20',
                   'services': [{'id': 'first', 'client_access': True, 'transports': [{'protocol': 'tcp', 'ports': [443]}], 'domains': ['a.example.com']},
                                {'id': 'second', 'client_access': True, 'transports': [{'protocol': 'tcp', 'ports': [443]}], 'domains': ['b.example.com']}],
                   'allocations': [], 'selected_services': ['first']}
        first = self.allocate(catalog)
        self.assertEqual(len(first['allocations']), 2)  # Published, not necessarily assigned.
        self.assertEqual([r['domain'] for r in first['resources']], ['a.example.com'])
        catalog['allocations'] = first['allocations']
        catalog['services'][0]['domains'] = ['new.example.com']
        second = self.allocate(catalog)
        self.assertEqual(second['allocations'][:2], first['allocations'])
        self.assertEqual(second['resources'][0]['address'], '172.31.240.3')
        catalog['allocations'] = second['allocations']
        catalog['services'].reverse()
        catalog['selected_services'] = ['second']
        third = self.allocate(catalog)
        self.assertEqual(third['allocations'], second['allocations'])
        self.assertEqual(third['resources'][0]['address'], '172.31.240.2')

    def test_catalog_refuses_unknown_unpublished_and_exhausted_services(self):
        catalog = {'version': 1, 'virtual_subnet': '172.31.254.0/28',
                   'services': [{'id': 'first', 'client_access': False, 'transports': [{'protocol': 'tcp', 'ports': [443]}], 'domains': ['a.example.com']}],
                   'allocations': [], 'selected_services': ['first']}
        for selection in [['first'], ['unknown']]:
            catalog['selected_services'] = selection
            result = subprocess.run(['ucode', str(COMPILER), 'allocate'], input=json.dumps(catalog),
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
        catalog['selected_services'] = ['first']
        catalog['services'][0]['client_access'] = True
        catalog['services'][0]['domains'] = [f'host{i}.example.com' for i in range(15)]
        result = subprocess.run(['ucode', str(COMPILER), 'allocate'], input=json.dumps(catalog),
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_shared_domain_does_not_mix_protocol_permissions(self):
        catalog = {'version': 1, 'virtual_subnet': '172.31.240.0/20',
                   'allocations': [], 'selected_services': ['web', 'call'],
                   'services': [
                       {'id': 'web', 'client_access': True, 'domains': ['shared.example.com'],
                        'transports': [{'protocol': 'tcp', 'ports': [443]}]},
                       {'id': 'call', 'client_access': True, 'domains': ['shared.example.com'],
                        'transports': [{'protocol': 'udp', 'ports': [3478]}]}]}
        allocation = self.allocate(catalog)
        self.assertEqual(len(allocation['allocations']), 1)
        candidate = copy.deepcopy(POLICY)
        candidate['virtual_subnet'] = catalog['virtual_subnet']
        candidate['resources'] = allocation['resources']
        result = compile_policy(candidate)
        self.assertEqual(result.returncode, 0, result.stderr)
        rules = json.loads(result.stdout)['router_rules'][:-1]
        self.assertEqual([(r['network'], r['port']) for r in rules],
                         [(['tcp'], [443]), (['udp'], [3478])])

    def render(self, policy, extra=''):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy.json'
            path.write_text(json.dumps(policy))
            values = {
                'log_level': 'warn', 'ttl': '60', 'cache_capacity': '8192',
                'cache_path': '/tmp/example-cache.db', 'upstream_host': '192.0.2.53',
                'upstream_port': '53', 'bootstrap_host': '192.0.2.53', 'bootstrap_port': '53',
                'doh_host': 'dns.example.com', 'doh_port': '443', 'doh_path': '/dns-query',
                'fakeip_range': '198.18.0.0/15', 'final_server': 'upstream',
                'dns_address': '127.0.0.42', 'dns_port': '5353', 'tproxy_address': '127.0.0.1',
                'tproxy_port': '7893', 'direct_tproxy_port': '7894', 'router_tproxy_port': '7895',
                'controller_address': '127.0.0.1:9090', 'controller_secret': 'test-only',
                'ruleset_path': '/tmp/example-rules.json', 'covered': '192.0.2.0/24',
                'client_access_policy': str(path), 'client_access_port': '7900',
            }
            data = ''.join(f'{key}\t{value}\n' for key, value in values.items()) + extra
            return subprocess.run(['ucode', str(ROOT / 'ikev2-manager-runtime/lib/singbox-config.uc'),
                                   'render'], input=data, text=True, capture_output=True)

    def test_generator_isolates_managed_listener_from_direct_and_sniff_rules(self):
        result = self.render(POLICY)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        rules = config['route']['rules']
        self.assertEqual(rules[0]['override_address'], 'api.example.com')
        self.assertEqual(rules[0]['outbound'], 'ikev2-out')
        self.assertEqual(rules[1]['inbound'], ['tproxy-client-access-in'])
        self.assertEqual(rules[1]['action'], 'reject')
        self.assertTrue(any(item['tag'] == 'tproxy-client-access-in' for item in config['inbounds']))

    def test_missing_exit_cannot_fall_back_to_another_tunnel(self):
        policy = copy.deepcopy(POLICY)
        policy['exit'] = '2s'
        result = self.render(policy)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['route']['rules'][0]['action'], 'reject')

    def test_disabled_exit_rejects_and_listener_collision_fails(self):
        result = self.render(POLICY, 'tunnel\t1\tipsec-out\nexit\t1\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['route']['rules'][0]['action'], 'reject')
        result = self.render(POLICY, 'client_access_port\t7893\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_compiles_matching_client_and_router_destinations(self):
        result = compile_policy(POLICY)
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = json.loads(result.stdout)
        self.assertEqual(bundle['hosts'], '172.31.254.1 api.example.com\n')
        self.assertEqual(bundle['routes'], ['172.31.254.1/32'])
        rule = bundle['router_rules'][0]
        self.assertEqual(rule['ip_cidr'], bundle['routes'])
        self.assertEqual(rule['override_address'], 'api.example.com')
        self.assertEqual(rule['outbound'], 'exit-1')
        self.assertEqual(rule['network'], ['tcp'])
        self.assertEqual(bundle['router_rules'][-1]['action'], 'reject')
        self.assertEqual(bundle['policy'], POLICY)

    def test_refuses_unsafe_or_ambiguous_policies(self):
        invalid = []
        for key, value in [('version', 2), ('revision', 0), ('revision', True), ('exit', 'direct-out'),
                           ('virtual_subnet', '198.18.0.0/24'), ('virtual_subnet', '172.31.254.1/24'),
                           ('resources', []), ('id', '../other')]:
            candidate = copy.deepcopy(POLICY)
            candidate[key] = value
            invalid.append(candidate)
        for key, value in [('domain', '*.example.com'), ('domain', 'api.example.com\nother'),
                           ('domain', 'vpn.example.com'), ('domain', '127.0.0.1'),
                           ('address', '172.31.254.0'), ('address', '172.31.254.255'),
                           ('address', '172.31.253.1'), ('address', '172.031.254.1'),
                           ('ports', [0]), ('ports', [65536]), ('ports', [True]),
                           ('ports', [443, 443]), ('ports', [])]:
            candidate = copy.deepcopy(POLICY)
            if key == 'ports':
                candidate['resources'][0]['transports'][0]['ports'] = value
            else:
                candidate['resources'][0][key] = value
            invalid.append(candidate)
        for key in POLICY:
            candidate = copy.deepcopy(POLICY)
            del candidate[key]
            invalid.append(candidate)
        candidate = copy.deepcopy(POLICY)
        candidate['password'] = 'must-not-be-accepted-or-echoed'
        invalid.append(candidate)
        candidate = copy.deepcopy(POLICY)
        candidate['resources'].append(copy.deepcopy(candidate['resources'][0]))
        invalid.append(candidate)
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                result = compile_policy(candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertNotIn('must-not-be-accepted-or-echoed', result.stderr)

    def test_multiple_resources_and_exit(self):
        candidate = copy.deepcopy(POLICY)
        candidate['exit'] = '2s'
        candidate['resources'].append({'id': 'login', 'domain': 'login.example.com',
                                       'address': '172.31.254.2', 'transports': [{'protocol': 'tcp', 'ports': [443, 8443]}]})
        result = compile_policy(candidate)
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = json.loads(result.stdout)
        self.assertEqual(len(bundle['routes']), 2)
        self.assertEqual(bundle['router_rules'][1]['outbound'], 'exit-2s')
        self.assertEqual(bundle['router_rules'][1]['port'], [443, 8443])


if __name__ == '__main__':
    unittest.main()
