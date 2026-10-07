'use strict';
import { readfile, writefile, chmod } from 'fs';
import { sha256 } from 'digest';
import { write_client_enrollment } from '/usr/libexec/ikev2-manager.d/client-access-enrollment-store.uc';
import { read_client_state, publish_client_state } from '/usr/libexec/ikev2-manager.d/client-access-store.uc';
let directory = '/etc/ikev2-manager/clients';
if (ARGV[0] == 'seed') {
	write_client_enrollment(directory, { version: 1, expected_generation: 0, operation: 'issue', payload: {
		id: 'http-laptop', token_sha256: sha256('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'),
		selected_services: [ 'api' ], lifetime_seconds: 60 } }, time(), true);
} else if (ARGV[0] == 'bundle') {
	let bundle = json(readfile(ARGV[1])), state = read_client_state(directory);
	let record = json(readfile(directory + '/credentials/http-laptop.json'));
	if (bundle.version !== 1 || bundle.state != 'enrolled' || bundle.policy.id != 'http-laptop' ||
		bundle.credentials.username != 'http-laptop' || bundle.credentials.password != record.password ||
		!filter(state.api.devices, device => device.id == 'http-laptop')[0].enabled)
		die('wrong enrollment bundle, or registration did not open the device');
} else if (ARGV[0] == 'enable' || ARGV[0] == 'disable') {
	let state = read_client_state(directory), desired = state.publication;
	delete desired.allocations;
	for (let device in desired.devices) {
		delete device.previous_policy;
		if (device.id == 'http-laptop') device.enabled = ARGV[0] == 'enable';
	}
	publish_client_state(directory, desired, state.generation, false);
} else if (ARGV[0] == 'wrong-password') {
	let path = directory + '/credentials/http-laptop.json', record = json(readfile(path));
	record.password = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
	if (!writefile(path, sprintf('%J\n', record)) || !chmod(path, 0600)) die('credential fixture failed');
} else if (ARGV[0] == 'future-clock') {
	let path = directory + '/invitations.json', journal = json(readfile(path));
	journal.ledger.updated_at = time() + 30;
	if (!writefile(path, sprintf('%J\n', journal)) || !chmod(path, 0600)) die('clock fixture failed');
} else if (ARGV[0] == 'expire') {
	let path = directory + '/invitations.json', journal = json(readfile(path));
	journal.ledger.updated_at = time() - 120;
	journal.ledger.invitations[0].issued_at = time() - 120;
	journal.ledger.invitations[0].expires_at = time() - 60;
	if (!writefile(path, sprintf('%J\n', journal)) || !chmod(path, 0600)) die('expiry fixture failed');
} else die('unknown enrollment HTTP fixture');
