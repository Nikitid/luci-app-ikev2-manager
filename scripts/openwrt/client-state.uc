'use strict';
import { readfile, unlink, writefile, chmod, symlink, open } from 'fs';
import { publish_client_state, read_client_state } from '/usr/libexec/ikev2-manager.d/client-access-store.uc';

let directory = ARGV[0];
function check(value, message) {
	if (!value) die(message);
}
function refused(action, message) {
	let failed = false;
	try { action(); } catch (error) { failed = true; }
	check(failed, message);
}
let desired = { version: 1, server: { address: 'vpn.example.com', remote_id: 'vpn.example.com' },
	virtual_subnet: '172.31.254.0/24', exit: '1',
	services: [ { id: 'api', client_access: true, domains: [ 'api.example.com' ],
		transports: [ { protocol: 'tcp', ports: [ 443 ] } ] } ],
	devices: [ { id: 'alice', token_sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
		enabled: true, selected_services: [ 'api' ] } ] };
check(publish_client_state(directory, desired, 0, true) == 1, 'initial publication failed');
let initial = read_client_state(directory);
refused(() => publish_client_state(directory, desired, 0, true), 'state was reinitialized');
refused(() => publish_client_state(directory, desired, 0, false), 'stale writer accepted');
let lock = open(directory + '/publication.lock', 'r');
check(lock.lock('xn'), 'test lock failed');
refused(() => publish_client_state(directory, desired, 1, false), 'concurrent writer accepted');
lock.close();
let target = directory + '/unrelated';
check(writefile(target, 'keep') && chmod(target, 0600), 'test target failed');
check(symlink(target, directory + '/state.pending'), 'test symlink failed');
refused(() => publish_client_state(directory, desired, 1, false), 'symlink staging accepted');
check(readfile(target) == 'keep', 'unrelated file overwritten');
unlink(directory + '/state.pending');
desired.services[0].domains = [ 'new.example.com' ];
check(publish_client_state(directory, desired, 1, false) == 2, 'update failed');
let updated = read_client_state(directory);
check(updated.publication.allocations[0].address == initial.publication.allocations[0].address &&
	length(updated.publication.allocations) == 2 && updated.api.devices[0].policy.revision == 2,
	'committed history was lost');
let raw = readfile(directory + '/state.json');
unlink(directory + '/state.json');
refused(() => publish_client_state(directory, desired, 2, false), 'missing history was reset');
refused(() => publish_client_state(directory, desired, 0, true), 'missing history was reinitialized');
check(writefile(directory + '/state.json', raw) && chmod(directory + '/state.json', 0600), 'test restore failed');
check(chmod(directory + '/state.json', 0644), 'test permissions failed');
refused(() => read_client_state(directory), 'unsafe permissions accepted');
check(chmod(directory + '/state.json', 0600), 'test permissions restore failed');
check(read_client_state(directory).generation == 2, 'restored state failed');
print('client-state: PASS\n');
