#!/usr/bin/env python3
"""Committed allocation and device history survive central policy updates."""
import copy
import json
import subprocess
import unittest
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('publication_tests', Path(__file__).with_name('test-client-publication.py'))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
proposal, COMPILER = publication.proposal, publication.COMPILER


def desired():
    value = proposal()
    del value['allocations']
    for device in value['devices']:
        del device['previous_policy']
    return value


def run(value, mode='state'):
    return subprocess.run(['ucode', str(COMPILER), mode], input=json.dumps(value),
                          text=True, capture_output=True)


class StateTests(unittest.TestCase):
    def update(self, value, previous=None):
        result = run({'version': 1, 'expected_generation': previous['generation'] if previous else 0,
                      'previous': previous, 'desired': value})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_stable_history_and_individual_revisions(self):
        value = desired()
        initial = self.update(value)
        restart = self.update(value, json.loads(json.dumps(initial)))
        self.assertEqual(initial['api'], restart['api'])
        self.assertEqual(restart['generation'], 2)
        value['services'][0]['domains'].append('new.example.com')
        updated = self.update(value, restart)
        self.assertEqual([d['policy']['revision'] for d in updated['api']['devices']], [2, 1])
        self.assertEqual(updated['publication']['allocations'][:2], initial['publication']['allocations'])

    def test_removed_identity_is_retired_and_cannot_be_reused(self):
        value = desired()
        initial = self.update(value)
        removed = value['devices'].pop(0)
        revoked = self.update(value, initial)
        self.assertEqual(revoked['retired_ids'], ['alice'])
        self.assertFalse(next(d for d in revoked['api']['devices'] if d['id'] == 'alice')['enabled'])
        again = self.update(value, revoked)
        self.assertEqual(again['retired_ids'], ['alice'])
        value['devices'].append(removed)
        self.assertNotEqual(run({'version': 1, 'expected_generation': again['generation'],
                                 'previous': again, 'desired': value}).returncode, 0)

    def test_stale_and_inconsistent_state_refused(self):
        value = desired()
        initial = self.update(value)
        result = run({'version': 1, 'expected_generation': 0, 'previous': initial, 'desired': value})
        self.assertNotEqual(result.returncode, 0)
        for change in ['api', 'history', 'allocation', 'retired']:
            invalid = copy.deepcopy(initial)
            if change == 'api':
                invalid['api']['devices'][0]['enabled'] = False
            elif change == 'history':
                invalid['publication']['devices'][0]['previous_policy'] = None
            elif change == 'allocation':
                invalid['publication']['allocations'][0]['address'] = '172.31.254.99'
            else:
                invalid['retired_ids'] = ['alice']
            self.assertNotEqual(run(invalid, 'validate-state').returncode, 0, change)

    def test_empty_state_validates_base_and_caller_cannot_supply_history(self):
        value = desired()
        value['devices'] = []
        value['services'] = []
        self.assertEqual(self.update(value)['api']['devices'], [])
        invalid = copy.deepcopy(value)
        invalid['server']['address'] = 'invalid host'
        self.assertNotEqual(run({'version': 1, 'expected_generation': 0,
                                 'previous': None, 'desired': invalid}).returncode, 0)
        value['allocations'] = []
        self.assertNotEqual(run({'version': 1, 'expected_generation': 0,
                                 'previous': None, 'desired': value}).returncode, 0)


if __name__ == '__main__':
    unittest.main()
