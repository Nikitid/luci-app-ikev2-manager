// Invoked only by the bounded background worker; it never returns credentials.
'use strict';
import { lstat } from 'fs';
import { read_client_enrollment, finalize_client_enrollment } from './client-access-enrollment-store.uc';
import { provision_client_credentials } from './client-access-credentials.uc';
import { read_client_state, publish_client_state } from './client-access-store.uc';
let directory = '/etc/ikev2-manager/clients';
try {
	if (length(ARGV) != 0) die('invalid enrollment worker invocation');
	if (lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null) {
		print('state=idle\n'); exit(0);
	}
	let journal = read_client_enrollment(directory);
	if (journal.pending == null) { print('state=idle\n'); exit(0); }
	provision_client_credentials(directory, journal.ledger.generation);
	let id = journal.pending.id;
	finalize_client_enrollment(directory, journal.ledger.generation, time());
	// The invitation named the device and its services; that was the
	// administrator's decision to let it in. Registration commits the device
	// closed, as its journal requires, and this ordinary update opens it. If
	// the router stops between the two, the device stays closed and is opened
	// from the page.
	let state = read_client_state(directory), desired = state.publication, opened = false;
	delete desired.allocations;
	for (let device in desired.devices) {
		delete device.previous_policy;
		if (device.id == id && !device.enabled && length(device.selected_services) && index(state.retired_ids, id) < 0) {
			device.enabled = true;
			opened = true;
		}
	}
	if (opened) publish_client_state(directory, desired, state.generation, false);
	print('state=complete\n');
} catch (error) {
	warn('enrollment worker: registration unavailable\n');
	exit(1);
}
