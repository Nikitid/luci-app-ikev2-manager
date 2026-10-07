// Root administrative invitation entry point. Output contains a secret.
'use strict';
import { stdin } from 'fs';
import { issue_client_invitation, stage_client_invitation, consume_client_invitation } from './client-access-invitation.uc';
import { write_client_label } from './client-access-directory.uc';

if (ARGV[0] == 'take' && length(ARGV) == 2) {
 try { print(sprintf('%J\n', consume_client_invitation(ARGV[1], time()))); }
 catch (error) { warn('client-access-invitation: delivery refused or unavailable\n'); exit(1); }
}
else if (ARGV[0] == 'issue' || ARGV[0] == 'issue-job') {
	try {
		if (length(ARGV) != (ARGV[0] == 'issue' ? 1 : 2)) die('invalid invitation command');
		let raw = stdin.read(1048577);
		if (type(raw) != 'string' || length(raw) > 1048576) die('invalid invitation size');
		// Who the device is for travels with the request and is recorded apart
		// from the invitation, which carries only what decides access.
		let request = json(raw), owner = null, note = null;
		if (type(request) == 'object' && 'owner' in request) {
			owner = request.owner; note = request.note;
			delete request.owner; delete request.note;
		}
		if (ARGV[0] == 'issue-job') stage_client_invitation(request, time(), ARGV[1]);
  else print(sprintf('%J\n', issue_client_invitation('/etc/ikev2-manager/clients', request, time())));
		if (owner != null) write_client_label('/etc/ikev2-manager/clients', request.id, owner, note ?? '');
	} catch (error) {
		warn('client-access-invitation: issuance refused or unavailable\n');
		exit(1);
	}
}
else { warn('usage: client-access-invitation-control.uc issue|issue-job JOB|take JOB\n'); exit(2); }
