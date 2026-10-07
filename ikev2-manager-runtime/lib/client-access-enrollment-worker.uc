// Invoked only by the bounded background worker; it never returns credentials.
'use strict';
import { lstat } from 'fs';
import { read_client_enrollment, finalize_client_enrollment } from './client-access-enrollment-store.uc';
import { provision_client_credentials } from './client-access-credentials.uc';
import { read_client_state, publish_client_state } from './client-access-store.uc';
import { prepare_client_admin } from './client-access-admin.uc';
import { record_client_event } from './client-access-journal.uc';
import { popen } from 'fs';
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
	let state = read_client_state(directory);
	let device = filter(state.publication.devices, item => item.id == id)[0];
	// The administrator may keep new devices closed until looked at: a link
	// that reached the wrong hands then lets nobody in by itself.
	let setting = popen('/sbin/uci -q get ikev2-manager.client_access.approve', 'r');
	let approve = replace(setting?.read(8) ?? '', /\n$/, '') == '1';
	setting?.close();
	record_client_event(approve ? 'registered-waiting' : 'registered', id);
	if (!approve && device != null && !device.enabled && length(device.selected_services) && index(state.retired_ids, id) < 0) {
		// The same change the page makes when the administrator opens a device.
		let prepared = prepare_client_admin(state, { version: 1, expected_generation: state.generation,
			operation: 'assign-device', payload: { id: id, enabled: true, selected_services: device.selected_services } }, []);
		if (prepared.changed) publish_client_state(directory, prepared.desired, state.generation, false);
	}
	print('state=complete\n');
} catch (error) {
	warn('enrollment worker: registration unavailable\n');
	exit(1);
}
