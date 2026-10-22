#!/usr/bin/env python3
"""Administrative assignments retain secrets and stable address history."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('state', Path(__file__).with_name('test-client-state.py'))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)

class AdminTests(unittest.TestCase):
    def setUp(self):
        result = state.run({'version': 1, 'expected_generation': 0, 'previous': None, 'desired': state.desired()})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.snapshot = json.loads(result.stdout)

    def request(self, operation, payload):
        return {'version': 1, 'expected_generation': self.snapshot['generation'], 'operation': operation, 'payload': payload}

    def run_admin(self, request, catalog):
        return state.run({'state': self.snapshot, 'request': request, 'catalog': catalog}, 'admin-edit')

    def apply(self, request, catalog):
        result = self.run_admin(request, catalog)
        self.assertEqual(result.returncode, 0, result.stderr)
        prepared = json.loads(result.stdout)
        committed = state.run({'version': 1, 'expected_generation': self.snapshot['generation'],
                               'previous': self.snapshot, 'desired': prepared['desired']})
        self.assertEqual(committed.returncode, 0, committed.stderr)
        return prepared, json.loads(committed.stdout)

    def test_inspection_contains_no_credentials_or_policy_history(self):
        result = state.run(self.snapshot, 'admin-inspect')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('token_sha256', result.stdout)
        self.assertNotIn('previous_policy', result.stdout)
        self.assertNotIn('api.example.com', result.stdout)
        self.assertEqual(json.loads(result.stdout)['services'][0]['domain_count'], len(self.snapshot['publication']['services'][0]['domains']))
        self.assertEqual(len(json.loads(result.stdout)['devices']), len(self.snapshot['publication']['devices']))

    def test_domain_update_preserves_keys_and_allocations_and_updates_device_revision(self):
        request = self.request('refresh-catalog', {})
        catalog = [{'id': service['id'], 'domains': list(service['domains'])} for service in self.snapshot['publication']['services'] if service['client_access']]
        catalog[0]['domains'].append('new.api.example.com')
        prepared, updated = self.apply(request, catalog)
        self.assertTrue(prepared['changed'])
        self.assertEqual(updated['publication']['allocations'][:len(self.snapshot['publication']['allocations'])], self.snapshot['publication']['allocations'])
        self.assertEqual([d['token_sha256'] for d in updated['publication']['devices']], [d['token_sha256'] for d in self.snapshot['publication']['devices']])
        self.assertGreater(updated['api']['devices'][0]['policy']['revision'], self.snapshot['api']['devices'][0]['policy']['revision'])

    def test_disabled_service_removes_assignments_and_retrieval(self):
        service = self.snapshot['publication']['services'][0]
        prepared, updated = self.apply(self.request('configure-service', {'id': service['id'], 'client_access': False, 'transports': service['transports']}), [])
        for device in prepared['desired']['devices']:
            self.assertNotIn(service['id'], device['selected_services'])
        for device in updated['api']['devices']:
            if not next(d for d in prepared['desired']['devices'] if d['id'] == device['id'])['selected_services']:
                self.assertFalse(device['enabled'])

    def test_networks_are_published_when_asked_and_kept_until_asked_away(self):
        service = self.snapshot['publication']['services'][0]
        base = {'id': service['id'], 'client_access': True, 'transports': service['transports']}
        # Written off their base address, they are set at it, and repeated ones once.
        catalog = [{'id': service['id'], 'domains': service['domains'], 'networks': ['91.108.4.7/22', '91.108.4.0/22', '149.154.160.0/20']}]
        prepared, updated = self.apply(self.request('configure-service', dict(base, networks=True)), catalog)
        published = next(s for s in updated['publication']['services'] if s['id'] == service['id'])
        self.assertEqual(published['networks'], ['91.108.4.0/22', '149.154.160.0/20'])
        self.snapshot = updated
        # A request that does not mention them, as today's page sends, keeps them.
        prepared, updated = self.apply(self.request('configure-service', base), [dict(catalog[0], networks=['91.108.4.0/22'])])
        self.assertEqual(next(s for s in updated['publication']['services'] if s['id'] == service['id'])['networks'], ['91.108.4.0/22'])
        self.snapshot = updated
        inspected = json.loads(state.run(self.snapshot, 'admin-inspect').stdout)
        self.assertEqual(next(s for s in inspected['services'] if s['id'] == service['id'])['network_count'], 1)
        # Asked away, they go.
        prepared, updated = self.apply(self.request('configure-service', dict(base, networks=False)), [{'id': service['id'], 'domains': service['domains']}])
        self.assertNotIn('networks', next(s for s in updated['publication']['services'] if s['id'] == service['id']))

    def test_networks_that_cannot_be_carried_are_refused(self):
        service = self.snapshot['publication']['services'][0]
        request = self.request('configure-service', {'id': service['id'], 'client_access': True, 'transports': service['transports'], 'networks': True})
        for networks in [[], ['10.%d.0.0/16' % n for n in range(65)]]:
            self.assertNotEqual(self.run_admin(request, [{'id': service['id'], 'domains': service['domains'], 'networks': networks}]).returncode, 0)
        # Neither names nor networks: nothing to publish.
        self.assertNotEqual(self.run_admin(request, [{'id': service['id'], 'domains': []}]).returncode, 0)

    def offer(self, offer, ids=('alice',)):
        prepared, updated = self.apply(self.request('assign-devices', {'ids': list(ids), 'enabled': True, 'offer': offer,
                                                                        'owner': 'Alice', 'note': ''}), [])
        self.snapshot = updated
        return next(d for d in updated['publication']['devices'] if d['id'] == ids[0])

    def choose(self, on, closed, device='alice'):
        prepared, updated = self.apply(self.request('device-choices', {'id': device, 'on': on, 'closed': closed}), [])
        self.snapshot = updated
        return next(d for d in updated['publication']['devices'] if d['id'] == device)

    def test_an_offer_gives_required_services_and_leaves_optional_ones_to_the_device(self):
        device = self.offer([{'id': 'api', 'required': True, 'closed': 'yes'},
                             {'id': 'chat', 'required': False, 'closed': 'choice'}])
        self.assertEqual((device['selected_services'], device['choices']), (['api'], {'on': [], 'closed': []}))
        device = self.choose(['chat'], ['chat'])
        self.assertEqual(device['selected_services'], ['api', 'chat'])
        policy = next(d for d in self.snapshot['api']['devices'] if d['id'] == 'alice')['policy']
        self.assertEqual(sorted(r['domain'] for r in policy['resources']), ['api.example.com', 'chat.example.com'])
        shown = next(d for d in json.loads(state.run(self.snapshot, 'admin-inspect').stdout)['devices'] if d['id'] == 'alice')
        self.assertEqual(shown['choices'], {'on': ['chat'], 'closed': ['chat']})
        # A new offer keeps only the choices it still leaves to the person.
        device = self.offer([{'id': 'api', 'required': True, 'closed': 'yes'},
                             {'id': 'chat', 'required': False, 'closed': 'no'}])
        self.assertEqual((device['selected_services'], device['choices']), (['api', 'chat'], {'on': ['chat'], 'closed': []}))
        # A service closed for clients leaves every offer.
        service = next(s for s in self.snapshot['publication']['services'] if s['id'] == 'chat')
        prepared, updated = self.apply(self.request('configure-service', {'id': 'chat', 'client_access': False,
                                                                          'transports': service['transports']}), [])
        device = next(d for d in updated['publication']['devices'] if d['id'] == 'alice')
        self.assertEqual((device['offer'], device['selected_services']), ([{'id': 'api', 'required': True, 'closed': 'yes'}], ['api']))

    def test_a_device_chooses_only_what_its_offer_leaves_it(self):
        self.offer([{'id': 'api', 'required': True, 'closed': 'no'}, {'id': 'chat', 'required': False, 'closed': 'no'}])
        for on, closed in [(['api'], []), (['other'], []), ([], ['chat']), ([], ['api']), (['chat', 'chat'], [])]:
            self.assertNotEqual(self.run_admin(self.request('device-choices', {'id': 'alice', 'on': on, 'closed': closed}), []).returncode,
                                0, (on, closed))
        # Bob has no offer: nothing to choose from.
        self.assertNotEqual(self.run_admin(self.request('device-choices', {'id': 'bob', 'on': [], 'closed': []}), []).returncode, 0)
        # A device that follows an offer is not given another list by hand,
        self.assertNotEqual(self.run_admin(self.request('assign-device', {'id': 'alice', 'enabled': True,
                                                                          'selected_services': ['chat']}), []).returncode, 0)
        # and an offer of a service not published is refused.
        self.assertNotEqual(self.run_admin(self.request('assign-devices', {'ids': ['alice'], 'enabled': True, 'owner': 'Alice', 'note': '',
                                                                           'offer': [{'id': 'nope', 'required': True, 'closed': 'yes'}]}), []).returncode, 0)
        # A plain list leaves the offer behind.
        prepared, updated = self.apply(self.request('assign-devices', {'ids': ['alice'], 'enabled': True, 'owner': 'Alice', 'note': '',
                                                                       'selected_services': ['chat']}), [])
        device = next(d for d in updated['publication']['devices'] if d['id'] == 'alice')
        self.assertEqual((device['selected_services'], 'offer' in device, 'choices' in device), (['chat'], False, False))

    def test_unchanged_catalog_is_noop_and_bad_requests_are_refused(self):
        catalog = [{'id': s['id'], 'domains': s['domains']} for s in self.snapshot['publication']['services'] if s['client_access']]
        request = self.request('refresh-catalog', {})
        result = self.run_admin(request, catalog)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['changed'])
        for mutate in [lambda r: r.update(expected_generation=0), lambda r: r.update(extra=True), lambda r: r.update(operation='delete-state')]:
            invalid = copy.deepcopy(request); mutate(invalid)
            self.assertNotEqual(self.run_admin(invalid, catalog).returncode, 0)
        self.assertNotEqual(self.run_admin(request, catalog[:-1]).returncode, 0)
        invalid_catalog = copy.deepcopy(catalog); invalid_catalog[0]['domains'] = ['*.example.com']
        self.assertNotEqual(self.run_admin(request, invalid_catalog).returncode, 0)

    def test_existing_catalog_underscore_identifier_is_supported(self):
        payload = {'id': 'example_service', 'client_access': True, 'transports': [{'protocol': 'tcp', 'ports': [443]}]}
        _, updated = self.apply(self.request('configure-service', payload), [{'id': 'example_service', 'domains': ['catalog.example.com']}])
        self.assertIn('example_service', [s['id'] for s in updated['publication']['services']])
        self.snapshot = updated
        device = updated['publication']['devices'][0]
        _, assigned = self.apply(self.request('assign-device', {'id': device['id'], 'enabled': True, 'selected_services': ['example_service']}), [])
        self.assertEqual(assigned['api']['devices'][0]['policy']['resources'][0]['domain'], 'catalog.example.com')

    def test_removed_device_is_retired_and_later_changes_still_apply(self):
        ids = [device['id'] for device in self.snapshot['publication']['devices']]
        self.assertGreaterEqual(len(ids), 2)
        prepared, self.snapshot = self.apply(self.request('remove-device', {'id': ids[0]}), [])
        self.assertTrue(prepared['changed'])
        self.assertIn(ids[0], self.snapshot['retired_ids'])
        self.assertNotIn(ids[0], [d['id'] for d in json.loads(state.run(self.snapshot, 'admin-inspect').stdout)['devices']])
        # With a retired device in the state, the next change must still be
        # accepted: this is what opening a newly registered device does.
        other = [d for d in self.snapshot['publication']['devices'] if d['id'] == ids[1]][0]
        closed, self.snapshot = self.apply(self.request('assign-device', {'id': ids[1], 'enabled': False,
                                           'selected_services': other['selected_services']}), [])
        opened, self.snapshot = self.apply(self.request('assign-device', {'id': ids[1], 'enabled': True,
                                           'selected_services': other['selected_services'], 'owner': 'A', 'note': ''}), [])
        self.assertTrue(opened['changed'])
        self.assertTrue([d for d in self.snapshot['publication']['devices'] if d['id'] == ids[1]][0]['enabled'])
        again = self.run_admin(self.request('remove-device', {'id': ids[0]}), [])
        self.assertNotEqual(again.returncode, 0)
        # The removed device kept its record for one publication only; its
        # name stays spent, and a state without the record still validates.
        self.assertNotIn(ids[0], [d['id'] for d in self.snapshot['publication']['devices']])
        self.assertIn(ids[0], self.snapshot['retired_ids'])
        self.assertEqual(len(self.snapshot['api']['devices']), len(self.snapshot['publication']['devices']))
        checked = state.run(self.snapshot, 'validate-state')
        self.assertEqual(checked.returncode, 0, checked.stderr)
        invitation = state.run({'state': self.snapshot, 'digest': 'e' * 64, 'request': {'version': 1, 'expected_generation': 0,
            'endpoint': 'https://' + self.snapshot['publication']['server']['address'] + '/client/v1/enroll',
            'id': ids[0], 'selected_services': other['selected_services'], 'lifetime_seconds': 600}}, 'invitation')
        self.assertNotEqual(invitation.returncode, 0)
        desired = copy.deepcopy(self.snapshot['publication'])
        del desired['allocations']
        for device in desired['devices']:
            del device['previous_policy']
        desired['devices'].append({'id': ids[0], 'token_sha256': 'f' * 64, 'enabled': False, 'selected_services': other['selected_services']})
        revived = state.run({'version': 1, 'expected_generation': self.snapshot['generation'], 'previous': self.snapshot, 'desired': desired})
        self.assertNotEqual(revived.returncode, 0)

    def test_assignments_cannot_create_devices_or_change_credentials(self):
        device = self.snapshot['publication']['devices'][0]
        payload = {'id': device['id'], 'enabled': False, 'selected_services': device['selected_services']}
        _, updated = self.apply(self.request('assign-device', payload), [])
        self.assertFalse(updated['api']['devices'][0]['enabled'])
        payload['token_sha256'] = 'f' * 64
        self.assertNotEqual(self.run_admin(self.request('assign-device', payload), []).returncode, 0)
        del payload['token_sha256']; payload['id'] = 'unknown'
        self.assertNotEqual(self.run_admin(self.request('assign-device', payload), []).returncode, 0)

if __name__ == '__main__':
    unittest.main()
