// Invoked only by the bounded background worker; it never returns credentials.
'use strict';
import { lstat } from 'fs';
import { read_client_enrollment, finalize_client_enrollment } from './client-access-enrollment-store.uc';
import { provision_client_credentials } from './client-access-credentials.uc';
let directory = '/etc/ikev2-manager/clients';
try {
	if (length(ARGV) != 0) die('invalid enrollment worker invocation');
	if (lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null) {
		print('state=idle\n'); exit(0);
	}
	let journal = read_client_enrollment(directory);
	if (journal.pending == null) { print('state=idle\n'); exit(0); }
	provision_client_credentials(directory, journal.ledger.generation);
	finalize_client_enrollment(directory, journal.ledger.generation, time());
	print('state=complete\n');
} catch (error) {
	warn('enrollment worker: registration unavailable\n');
	exit(1);
}
