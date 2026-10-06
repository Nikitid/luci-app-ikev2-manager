#!/usr/bin/env python3
"""Invitations are bounded, one-use and cannot grant access on reservation."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('client_state', Path(__file__).with_name('test-client-state.py'))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
TOKEN = 'c' * 64
DIGEST = hashlib.sha256(TOKEN.encode()).hexdigest()


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        result = state.run({'version': 1, 'expected_generation': 0, 'previous': None, 'desired': state.desired()})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.snapshot = json.loads(result.stdout)
        self.ledger = {'version': 1, 'generation': 0, 'updated_at': 0, 'invitations': []}

    def run_transition(self, operation, payload, now=1000, generation=None):
        return state.run({'ledger': self.ledger, 'state': self.snapshot, 'now': now,
                          'request': {'version': 1, 'expected_generation': self.ledger['generation'] if generation is None else generation,
                                      'operation': operation, 'payload': payload}}, 'enrollment')

    def transition(self, operation, payload, now=1000):
        result = self.run_transition(operation, payload, now)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.ledger = output['ledger']
        return output

    def issue(self):
        return self.transition('issue', {'id': 'laptop', 'token_sha256': DIGEST,
                                         'selected_services': ['api'], 'lifetime_seconds': 600})

    def reserve(self, token=TOKEN):
        return {'invitation_sha256': hashlib.sha256(token.encode()).hexdigest(), 'device_token_sha256': 'd' * 64}

    def refused(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertNotIn(TOKEN, result.stderr)

    def invitation_request(self):
        return {'version': 1, 'expected_generation': 0,
                'endpoint': 'https://vpn.example.com:8443/client/v1/enroll',
                'id': 'laptop', 'selected_services': ['api'], 'lifetime_seconds': 600}

    def prepare_invitation(self, request):
        return state.run({'state': self.snapshot, 'request': request, 'digest': DIGEST}, 'invitation')

    def test_admin_invitation_is_bound_to_server_and_selected_services(self):
        request = self.invitation_request()
        result = self.prepare_invitation(request)
        self.assertEqual(result.returncode, 0, result.stderr)
        prepared = json.loads(result.stdout)
        self.assertEqual(prepared['operation'], 'issue')
        self.assertEqual(prepared['payload']['token_sha256'], DIGEST)
        issued = self.transition('issue', prepared['payload'])
        self.assertIsNone(issued['proposed_state'])
        self.assertNotIn(TOKEN, result.stdout)
        self.assertNotIn('endpoint', prepared['payload'])

    def test_admin_invitation_rejects_unsafe_endpoints_and_caller_secrets(self):
        for endpoint in ['http://vpn.example.com/client/v1/enroll',
                         'https://other.example.com/client/v1/enroll',
                         'https://vpn.example.com@other.example.com/client/v1/enroll',
                         'https://vpn.example.com/client/v1/enroll?token=x',
                         'https://vpn.example.com/client/v1/enroll#token',
                         'https://vpn.example.com:0/client/v1/enroll',
                         'https://vpn.example.com:65536/client/v1/enroll',
                         'https://vpn.example.com:0443/client/v1/enroll',
                         'https://vpn.example.com/client/v1/../enroll']:
            request = self.invitation_request(); request['endpoint'] = endpoint
            self.refused(self.prepare_invitation(request))
        for field, value in [('token', TOKEN), ('password', 'private'),
                             ('selected_services', ['unknown']), ('id', 'alice'),
                             ('lifetime_seconds', 3601), ('expected_generation', True)]:
            request = self.invitation_request(); request[field] = value
            self.refused(self.prepare_invitation(request))

    def test_reservation_burns_invitation_without_enabling_device(self):
        issued = self.issue()
        self.assertIsNone(issued['proposed_state'])
        self.assertNotIn(TOKEN, json.dumps(issued))
        reserved = self.transition('reserve', self.reserve(), 1100)
        self.assertEqual(self.ledger['invitations'][0]['status'], 'reserved')
        proposed = reserved['proposed_state']
        device = next(d for d in proposed['api']['devices'] if d['id'] == 'laptop')
        self.assertFalse(device['enabled'])
        self.assertEqual([r['domain'] for r in device['policy']['resources']], ['api.example.com'])
        self.assertEqual(proposed['api']['devices'][:2], self.snapshot['api']['devices'])
        self.assertEqual(proposed['publication']['allocations'], self.snapshot['publication']['allocations'])
        self.refused(self.run_transition('reserve', self.reserve(), 1101))
        # Serialization/restart cannot resurrect a consumed invitation.
        self.ledger = json.loads(json.dumps(self.ledger))
        self.refused(self.run_transition('reserve', self.reserve(), 1102))

    def test_expiry_boundary_wrong_token_and_clock_rollback(self):
        self.issue()
        for payload, now in [(self.reserve('e' * 64), 1100), (self.reserve(), 1600),
                             (self.reserve(), 1700), (self.reserve(), 999)]:
            self.refused(self.run_transition('reserve', payload, now))
        self.assertEqual(self.ledger['invitations'][0]['status'], 'issued')

    def test_cancel_and_stale_writer_cannot_reserve(self):
        self.issue()
        self.refused(self.run_transition('reserve', self.reserve(), 1100, generation=0))
        self.transition('cancel', {'id': 'laptop'}, 1100)
        self.refused(self.run_transition('reserve', self.reserve(), 1101))
        self.refused(self.run_transition('cancel', {'id': 'laptop'}, 1101))

    def test_service_revocation_during_invitation_is_respected(self):
        self.issue()
        desired = state.desired()
        desired['services'][0]['client_access'] = False
        desired['devices'][0]['selected_services'] = []
        result = state.run({'version': 1, 'expected_generation': self.snapshot['generation'],
                            'previous': self.snapshot, 'desired': desired})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.snapshot = json.loads(result.stdout)
        self.refused(self.run_transition('reserve', self.reserve(), 1100))

    def test_existing_and_retired_identity_and_duplicate_hash_refused(self):
        payload = {'id': 'alice', 'token_sha256': DIGEST, 'selected_services': ['api'], 'lifetime_seconds': 600}
        self.refused(self.run_transition('issue', payload))
        payload['id'] = 'laptop'; payload['token_sha256'] = 'b' * 64
        self.refused(self.run_transition('issue', payload))
        payload['id'] = 'alice'; payload['token_sha256'] = DIGEST
        desired = state.desired(); desired['devices'].pop(0)
        result = state.run({'version': 1, 'expected_generation': self.snapshot['generation'],
                            'previous': self.snapshot, 'desired': desired})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.snapshot = json.loads(result.stdout)
        self.refused(self.run_transition('issue', payload))
        self.issue()
        payload['id'] = 'another'
        self.refused(self.run_transition('issue', payload))
        for digest in [DIGEST, 'b' * 64]:
            invalid = self.reserve(); invalid['device_token_sha256'] = digest
            self.refused(self.run_transition('reserve', invalid, 1100))

    def test_strict_schema_and_bounded_invitation_lifetime(self):
        payload = {'id': 'laptop', 'token_sha256': DIGEST, 'selected_services': ['api'], 'lifetime_seconds': 600}
        for field, value in [('lifetime_seconds', 59), ('lifetime_seconds', 3601), ('lifetime_seconds', True),
                             ('selected_services', []), ('selected_services', ['api', 'api']),
                             ('selected_services', ['unknown']), ('id', '../user'), ('token_sha256', TOKEN.upper()),
                             ('password', 'unexpected')]:
            invalid = copy.deepcopy(payload); invalid[field] = value
            self.refused(self.run_transition('issue', invalid))
        self.issue()
        self.ledger['invitations'][0]['status'] = 'issued-again'
        self.refused(self.run_transition('reserve', self.reserve(), 1100))


if __name__ == '__main__':
    unittest.main()
