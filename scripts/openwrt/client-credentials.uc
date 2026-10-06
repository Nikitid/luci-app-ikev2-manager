'use strict';
import { readfile, writefile, chmod, unlink, rename, symlink, lstat } from 'fs';
import { sha256 } from 'digest';
import { read_client_enrollment, write_client_enrollment, abandon_client_enrollment } from '/usr/libexec/ikev2-manager.d/client-access-enrollment-store.uc';
import { provision_client_credentials, cleanup_client_credentials } from '/usr/libexec/ikev2-manager.d/client-access-credentials.uc';
let directory = '/etc/ikev2-manager/clients';
let record_path = directory + '/credentials/laptop.json';
function check(condition, message) { if (!condition) die(message); }
function refused(action, message) {
	let failed = false;
	try { action(); } catch (error) { failed = true; }
	check(failed, message);
}
function password() { return json(readfile(record_path)).password; }
function check_account() {
	let secret = '0s' + b64enc(password());
	let records = filter(split(readfile('/etc/ikev2-manager/users.db'), '\n'), line => split(line, '\t')[0] == 'laptop');
	check(length(records) == 1 && split(records[0], '\t')[1] == secret, 'wrong IKE credential');
}
if (ARGV[0] == 'prepare') {
	write_client_enrollment(directory, { version: 1, expected_generation: 0, operation: 'issue', payload: {
		id: 'laptop', token_sha256: sha256('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'),
		selected_services: [ 'api' ], lifetime_seconds: 600 } }, 1000, true);
	write_client_enrollment(directory, { version: 1, expected_generation: 1, operation: 'reserve', payload: {
		invitation_sha256: sha256('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'),
		device_token_sha256: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' } }, 1100, false);
} else if (ARGV[0] == 'provision' || ARGV[0] == 'retry') {
	let before = lstat(record_path) != null ? password() : null;
	let result = provision_client_credentials(directory, 2);
	check(result.credential_loaded && result.id == 'laptop' && length(keys(result)) == 3, 'wrong provisioning result');
	check(match(password(), /^[a-f0-9]{64}$/) != null, 'invalid generated credential');
	if (before != null) check(password() == before, 'retry rotated credential');
	check_account();
	check(read_client_enrollment(directory).pending != null, 'provisioning opened publication gate');
} else if (ARGV[0] == 'offline') {
	let before = password();
	refused(() => provision_client_credentials(directory, 2), 'offline daemon accepted as loaded');
	check(password() == before, 'offline retry rotated credential');
} else if (ARGV[0] == 'safety') {
	refused(() => provision_client_credentials(directory, 1), 'stale provisioning accepted');
	let before = readfile('/etc/ikev2-manager/users.db');
	check(chmod(record_path, 0644), 'credential mode fixture failed');
	refused(() => provision_client_credentials(directory, 2), 'unsafe credential mode accepted');
	check(chmod(record_path, 0600), 'credential mode restore failed');
	check(rename(record_path, record_path + '.retained'), 'credential history fixture failed');
	refused(() => provision_client_credentials(directory, 2), 'lost credential regenerated');
	check(symlink(record_path + '.retained', record_path), 'credential symlink fixture failed');
	refused(() => provision_client_credentials(directory, 2), 'credential symlink accepted');
	unlink(record_path);
	check(rename(record_path + '.retained', record_path), 'credential history restore failed');
	let record = json(readfile(record_path));
	let original = record.password;
	record.password = original == 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' ?
		'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' :
		'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
	check(writefile(record_path, sprintf('%J\n', record)) && chmod(record_path, 0600), 'credential conflict fixture failed');
	refused(() => provision_client_credentials(directory, 2), 'unrelated IKE credential overwritten');
	check(readfile('/etc/ikev2-manager/users.db') == before, 'credential conflict changed accounts');
	record.password = original;
	check(writefile(record_path, sprintf('%J\n', record)) && chmod(record_path, 0600), 'credential restore failed');
} else if (ARGV[0] == 'cleanup') {
	let before = readfile('/etc/ikev2-manager/users.db');
	refused(() => cleanup_client_credentials(directory, 'laptop', 2), 'pending credential deleted without abandonment');
	abandon_client_enrollment(directory, 2, 1200);
	refused(() => cleanup_client_credentials(directory, 'laptop', 2), 'stale credential cleanup accepted');
	let record = json(readfile(record_path)), original = record.password;
	record.password = original == 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' ?
		'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' :
		'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
	check(writefile(record_path, sprintf('%J\n', record)) && chmod(record_path, 0600), 'cleanup conflict fixture failed');
	refused(() => cleanup_client_credentials(directory, 'laptop', 3), 'unrelated IKE account deleted');
	check(readfile('/etc/ikev2-manager/users.db') == before, 'cleanup conflict changed accounts');
	record.password = original;
	check(writefile(record_path, sprintf('%J\n', record)) && chmod(record_path, 0600), 'cleanup credential restore failed');
	check(cleanup_client_credentials(directory, 'laptop', 3).credential_removed && lstat(record_path) == null &&
		lstat(directory + '/credentials/laptop.issued') != null, 'credential cleanup lost tombstone or secret survived');
	check(cleanup_client_credentials(directory, 'laptop', 3).credential_removed, 'credential cleanup retry failed');
	let other_before = filter(split(before, '\n'), line => split(line, '\t')[0] == 'unrelated');
	let after = readfile('/etc/ikev2-manager/users.db');
	let other_after = filter(split(after, '\n'), line => split(line, '\t')[0] == 'unrelated');
	check(length(other_before) == 1 && sprintf('%J', other_before) == sprintf('%J', other_after) &&
		!length(filter(split(after, '\n'), line => split(line, '\t')[0] == 'laptop')), 'cleanup changed unrelated credential');
} else die('unknown credential test operation');
