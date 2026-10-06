'use strict';
import { readfile, writefile, rename, chmod, unlink } from 'fs';
import { sha256 } from 'digest';
import { publish_client_state, read_client_state } from '/usr/libexec/ikev2-manager.d/client-access-store.uc';
let directory = ARGV[0], mode = ARGV[1], path = directory + '/state.json';
let snapshot, desired;
if (mode == 'seed') {
	// Fixture reset is isolated to a disposable container, never a runtime action.
	unlink(path);
	unlink(directory + '/initialized');
	let policy = json(readfile('/src/desktop-clients/fixtures/policies.json'))[0].policy;
	desired = { version: 1, server: policy.server, virtual_subnet: policy.virtual_subnet, exit: policy.exit,
		services: [
			{ id: 'api', client_access: true, domains: [ policy.resources[0].domain ], transports: policy.resources[0].transports },
			{ id: 'other', client_access: true, domains: [ 'other.example.com' ], transports: policy.resources[0].transports }
		], devices: [
			{ id: 'team', token_sha256: sha256('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
				enabled: true, selected_services: [ 'api' ] },
			{ id: 'other', token_sha256: sha256('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
				enabled: false, selected_services: [ 'other' ] }
		] };
	publish_client_state(directory, desired, 0, true);
} else {
	snapshot = read_client_state(directory);
	if (mode == 'invalid-policy' || mode == 'duplicate-token' || mode == 'inconsistent') {
		if (mode == 'invalid-policy') snapshot.api.devices[0].policy.password = 'must-never-be-returned';
		else if (mode == 'duplicate-token') snapshot.api.devices[1].token_sha256 = snapshot.api.devices[0].token_sha256;
		else snapshot.api.devices[0].enabled = false;
		if (!writefile(path + '.new', sprintf('%J\n', snapshot)) || !chmod(path + '.new', 0600) || !rename(path + '.new', path))
			die('Unable to corrupt API fixture');
	} else {
		desired = snapshot.publication;
		delete desired.allocations;
		for (let device in desired.devices) delete device.previous_policy;
		if (mode == 'enable-second') desired.devices[1].enabled = true;
		else if (mode == 'disable-first') desired.devices[0].enabled = false;
		else if (mode == 'update') push(desired.services[0].domains, 'updated.example.com');
		else die('Unknown API fixture mode');
		publish_client_state(directory, desired, snapshot.generation, false);
	}
}
