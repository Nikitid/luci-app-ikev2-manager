// Compile without applying. Credentials are never part of this document.
'use strict';
import { compile_client_path } from './client-access-path.uc';
import { prepare_client_enrollment, prepare_client_invitation } from './client-access-enrollment.uc';
import { prepare_client_admin, inspect_client_admin } from './client-access-admin.uc';
import { stdin } from 'fs';
import { prepare_client_state, validate_client_state } from './client-access-state.uc';
import { authenticated_client_sessions } from './client-access-sessions.uc';
import { compile_client_publication } from './client-access-publication.uc';
import { compile_client_policy, allocate_client_catalog } from './client-access.uc';
import { compile_client_authorization, reconcile_client_authorization } from './client-access-authorization.uc';

let policy;
try {
	let limit = ARGV[0] == 'state' ? 33554432 : (ARGV[0] == 'validate-state' || ARGV[0] == 'path') ? 16777216 : 1048576;
	let raw = stdin.read(limit + 1);
	if (type(raw) != 'string' || length(raw) > limit)
		die('policy exceeds size limit');
	policy = json(raw);
} catch (error) {
	warn('client-access-policy: invalid JSON or size limit exceeded\n');
	exit(1);
}
try {
	if (ARGV[0] == 'invitation')
		print(sprintf('%J\n', prepare_client_invitation(policy.state, policy.request, policy.digest)));
	else if (ARGV[0] == 'enrollment')
		print(sprintf('%J\n', prepare_client_enrollment(policy)));
	else if (ARGV[0] == 'admin-edit')
		print(sprintf('%J\n', prepare_client_admin(policy.state, policy.request, policy.catalog)));
	else if (ARGV[0] == 'admin-inspect')
		print(sprintf('%J\n', inspect_client_admin(policy)));
	else if (ARGV[0] == 'path')
		print(sprintf('%J\n', compile_client_path(policy)));
	else if (ARGV[0] == 'state')
		print(sprintf('%J\n', prepare_client_state(policy)));
	else if (ARGV[0] == 'validate-state')
		print(sprintf('%J\n', validate_client_state(policy)));
	else if (ARGV[0] == 'sessions')
		print(sprintf('%J\n', authenticated_client_sessions(policy)));
	else if (ARGV[0] == 'publish')
		print(sprintf('%J\n', compile_client_publication(policy)));
	else if (ARGV[0] == 'allocate')
		print(sprintf('%J\n', allocate_client_catalog(policy)));
	else if (ARGV[0] == 'reconcile')
		print(sprintf('%J\n', reconcile_client_authorization(policy)));
	else if (ARGV[0] == 'authorize')
		print(sprintf('%J\n', compile_client_authorization(policy)));
	else if (ARGV[0] == null)
		print(sprintf('%J\n', compile_client_policy(policy)));
	else {
		warn('usage: client-access-policy.uc [allocate|authorize|publish|sessions|reconcile|state|validate-state|path|admin-edit|admin-inspect|enrollment|invitation]\n');
		exit(2);
	}
} catch (error) {
	warn(`${error}\n`);
	exit(1);
}
