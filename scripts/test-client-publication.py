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


LIBRARY = COMPILER.parent
MEMORY = r"""
import { check_client_policy, compile_client_policy } from '%(lib)s/client-access.uc';
import { compile_client_publication } from '%(lib)s/client-access-publication.uc';
function refused(action) { try { action(); } catch (error) { return true; } return false; }
function copy(value) { return json(sprintf('%%J', value)); }
let resources = [ { id: 'host-1', domain: 'api.example.com', address: '172.31.254.2', transports: [ { protocol: 'tcp', ports: [ 443 ] } ] },
	{ id: 'host-2', domain: 'chat.example.com', address: '172.31.254.3', transports: [ { protocol: 'tcp', ports: [ 443 ] } ] } ];
let policy = { version: 1, id: 'alice', revision: 1, server: { address: 'vpn.example.com', remote_id: 'vpn.example.com' },
	virtual_subnet: '172.31.254.0/24', exit: '1', resources: resources };
let out = { first: !refused(() => check_client_policy(policy)), again: !refused(() => check_client_policy(copy(policy))) };
// The same resources, already found valid, under another pool, another
// server, and one of them twice.
let moved = copy(policy); moved.virtual_subnet = '10.9.0.0/24';
let named = copy(policy); named.server = { address: 'api.example.com', remote_id: 'api.example.com' };
let twice = copy(policy); push(twice.resources, copy(resources[0]));
let wider = copy(policy); wider.resources[0].transports[0].ports = [ 443, 70000 ];
out.other_pool = refused(() => check_client_policy(moved));
out.server_name = refused(() => check_client_policy(named));
out.repeated = refused(() => check_client_policy(twice));
out.changed = refused(() => check_client_policy(wider));
out.compiled = length(compile_client_policy(policy).router_rules);
// A refused proposal leaves what the caller holds as it was.
let proposal = { version: 1, server: policy.server, virtual_subnet: policy.virtual_subnet, exit: '1', allocations: [],
	services: [ { id: 'api', client_access: true, domains: [ 'b.example.com', 'a.example.com' ], transports: [ { protocol: 'tcp', ports: [ 443 ] } ] } ],
	devices: [ { id: 'alice', token_sha256: '%(a)s', enabled: true, selected_services: [ 'api' ], previous_policy: null },
		{ id: 'bob', token_sha256: '%(a)s', enabled: true, selected_services: [ 'api' ], previous_policy: null } ] };
let before = sprintf('%%J', proposal);
out.proposal_refused = refused(() => compile_client_publication(proposal));
out.caller_untouched = sprintf('%%J', proposal) == before;
proposal.devices[1].token_sha256 = '%(b)s';
let made = compile_client_publication(proposal);
out.allocated = length(made.allocations);
out.caller_allocations = length(proposal.allocations);
// Two devices given the same services do not share one array a later change could reach.
push(made.api.devices[0].policy.resources, 'x');
out.separate = length(made.api.devices[1].policy.resources);
print(sprintf('%%J\n', out));
"""


class MemoryTests(unittest.TestCase):
    """What was found valid once is remembered; nothing invalid may pass on that memory."""

    def test_memory_accepts_nothing_it_did_not_check(self):
        script = MEMORY % {'lib': LIBRARY, 'a': 'a' * 64, 'b': 'b' * 64}
        result = subprocess.run(['ucode', '-e', script], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'first': True, 'again': True, 'other_pool': True, 'server_name': True, 'repeated': True, 'changed': True,
            'compiled': 3, 'proposal_refused': True, 'caller_untouched': True, 'allocated': 2, 'caller_allocations': 0,
            'separate': 2})


if __name__ == '__main__':
    unittest.main()
