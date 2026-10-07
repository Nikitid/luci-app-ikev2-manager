// Root-only per-device credentials. Provisioning runs in a detached worker;
// only the authenticated enrollment endpoint may read the bootstrap bundle.
'use strict';
import { open, lstat, mkdir, rename, unlink, popen } from 'fs';
import { sha256 } from 'digest';
import { read_client_enrollment } from './client-access-enrollment-store.uc';
import { read_client_state } from './client-access-store.uc';

function safe(path, kind, mode) {
	let info = lstat(path);
	if (info?.type != kind || info.uid != 0 || info.mode != mode || (kind == 'file' && info.nlink != 1))
		die('unsafe credential storage');
	return info;
}
function identity(id) {
	if (type(id) != 'string' || !(length(id) <= 48 ? match(id, /^[a-z][a-z0-9-]*$/) : null)) die('invalid credential identity');
}
function random_secret() {
	let source = open('/dev/urandom', 're');
	if (source == null) die('credential randomness unavailable');
	let bytes = source.read(32); source.close();
	if (type(bytes) != 'string' || length(bytes) != 32) die('credential randomness unavailable');
	let secret = '';
	for (let i = 0; i < 32; i++) secret += sprintf('%02x', ord(substr(bytes, i, 1)));
	return secret;
}
function durable() {
	if (system('/bin/sync') != 0) die('credential synchronization failed');
}
function read_record(path) {
	let info = safe(path, 'file', 0600);
	if (info.size < 1 || info.size > 1024) die('invalid credential record size');
	let file = open(path, 're');
	if (file == null) die('credential record unavailable');
	let raw = file.read(1025); file.close();
	if (type(raw) != 'string' || length(raw) > 1024) die('invalid credential record size');
	let record = json(raw);
	if (type(record) != 'object' || length(keys(record)) != 4 || record.version !== 1 ||
		type(record.token_sha256) != 'string' || !(length(record.token_sha256) == 64 ? match(record.token_sha256, /^[a-f0-9]+$/) : null) ||
		type(record.password) != 'string' || !(length(record.password) == 64 ? match(record.password, /^[a-f0-9]+$/) : null))
		die('invalid credential record');
	identity(record.id);
	return record;
}
function stage(directory, id, token_hash) {
	let base = directory + '/credentials';
	if (lstat(base) == null && !mkdir(base, 0700)) die('credential directory unavailable');
	safe(base, 'directory', 0700);
	let path = base + '/' + id + '.json', marker = base + '/' + id + '.issued', temporary = base + '/' + id + '.pending';
	if (lstat(path) == null) {
		let record;
		if (lstat(temporary) != null) record = read_record(temporary);
		else {
			if (lstat(marker) != null) die('credential history requires recovery');
			record = { version: 1, id: id, token_sha256: token_hash, password: random_secret() };
			let raw = sprintf('%J\n', record), file = open(temporary, 'wxe', 0600);
			if (file == null) die('unable to stage credential');
			let written = file.write(raw), closed = file.close();
			if (written != length(raw) || !closed) die('unable to stage credential');
			safe(temporary, 'file', 0600); durable();
		}
		if (record.id != id || record.token_sha256 != token_hash) die('credential identity conflict');
		if (lstat(marker) == null) {
			let sentinel = open(marker, 'wxe', 0600);
			if (sentinel == null) die('credential marker unavailable');
			let written = sentinel.write('1\n'), closed = sentinel.close();
			if (written != 2 || !closed) die('credential marker unavailable');
			durable();
		} else safe(marker, 'file', 0600);
		if (!rename(temporary, path)) die('unable to commit credential');
		durable();
	}
	safe(marker, 'file', 0600);
	let record = read_record(path);
	if (record.id != id || record.token_sha256 != token_hash) die('credential identity conflict');
	return record;
}

function account_secret(id) {
	let path = '/etc/ikev2-manager/users.db';
	if (lstat(path) == null) return null;
	let info = safe(path, 'file', 0600);
	if (info.size > 1048576) die('credential database oversized');
	let file = open(path, 're');
	if (file == null) die('credential database unavailable');
	let raw = file.read(1048577); file.close();
	if (type(raw) != 'string' || length(raw) > 1048576) die('credential database oversized');
	let found = null;
	for (let line in split(raw, '\n')) {
		let fields = split(line, '\t');
		if (fields[0] != id) continue;
		if (length(fields) != 2 || found != null) die('ambiguous credential account');
		found = fields[1];
	}
	return found;
}
function command(command) {
	let child = popen('/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin ' + command + ' 2>/dev/null', 'r');
	if (child == null) die('credential operation unavailable');
	let body = child.read(4097), status = child.close();
	if (status != 0 || type(body) != 'string' || length(body) > 4096) die('credential operation failed');
	return trim(body);
}
function verify_policy(id) {
	let section = 'ikev2-manager.user_' + substr(sha256(id), 0, 16);
	// Either a device that sends its services alone and has no other rights,
	// or one that sends everything and has those of a VPN user: nothing else.
	if (command('/sbin/uci -q get ' + section + '.username') != id) die('credential policy mismatch');
	let rights = map([ 'router_access', 'internet_access', 'lan_access', 'pbr_mode' ], option => command('/sbin/uci -q get ' + section + '.' + option));
	if (join(',', rights) != 'deny,deny,deny,exclude' && join(',', rights) != 'inherit,inherit,inherit,inherit') die('credential policy mismatch');
}

// Only the dedicated, authenticated enrollment API may return this bundle.
// The normal policy API and administrative inspection never call this reader.
export function bootstrap_client_credentials(directory, id, token_hash) {
	identity(id); safe(directory, 'directory', 0700);
	safe(directory + '/credentials', 'directory', 0700);
	safe(directory + '/credentials/' + id + '.issued', 'file', 0600);
	let record = read_record(directory + '/credentials/' + id + '.json');
	if (record.id != id || record.token_sha256 != token_hash || account_secret(id) != '0s' + b64enc(record.password))
		die('bootstrap credential conflict');
	verify_policy(id);
	return { username: record.id, password: record.password };
};

export function provision_client_credentials(directory, expected_generation) {
	safe(directory, 'directory', 0700);
	let lockpath = directory + '/enrollment.lock';
	safe(lockpath, 'file', 0600);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null) die('credential lock unavailable');
	if (!lock.lock('xn')) { lock.close(); die('enrollment is busy'); }
	let input = null;
	try {
		safe(lockpath, 'file', 0600);
		let journal = read_client_enrollment(directory), pending = journal.pending;
		if (type(expected_generation) != 'int' || expected_generation !== journal.ledger.generation || pending == null)
			die('stale credential provisioning');
		let device = filter(pending.state.publication.devices, item => item.id == pending.id)[0];
		let record = stage(directory, pending.id, device.token_sha256);
		let previous = account_secret(record.id), encoded = '0s' + b64enc(record.password);
		if (previous != null && previous != encoded) die('existing IKE account conflict');
		let nonce = random_secret();
		input = '/var/run/ikev2-manager-user-' + nonce + '.in';
		let body = 'provision\n' + record.id + '\n' + record.password + '\n';
		let file = open(input, 'wxe', 0600);
		if (file == null) die('credential input unavailable');
		let written = file.write(body), closed = file.close();
		if (written != length(body) || !closed) die('credential input unavailable');
		safe(input, 'file', 0600);
		// Only the random staging filename is an argument. Password and policy
		// go through the existing restrictive-policy-first user transaction.
		command('/usr/libexec/ikev2-manager user-owned-input ' + nonce + ' >/dev/null');
		if (lstat(input) != null) { safe(input, 'file', 0600); unlink(input); }
		input = null;
		if (account_secret(record.id) != encoded) die('credential loading mismatch');
		verify_policy(record.id);
		lock.close();
		return { version: 1, id: record.id, credential_loaded: true };
	} catch (error) {
		if (input != null && lstat(input) != null) {
			// A caller cannot supply this generated filename. Refuse unsafe
			// metadata rather than following a replacement while cleaning up.
			let info = lstat(input);
			if (info.type == 'file' && info.uid == 0 && info.mode == 0600 && info.nlink == 1) unlink(input);
		}
		lock.close();
		die('credential provisioning refused or unavailable');
	}
};

export function cleanup_client_credentials(directory, id, expected_generation) {
	identity(id); safe(directory, 'directory', 0700);
	let lockpath = directory + '/enrollment.lock';
	safe(lockpath, 'file', 0600);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null) die('credential lock unavailable');
	if (!lock.lock('xn')) { lock.close(); die('enrollment is busy'); }
	let input = null;
	try {
		safe(lockpath, 'file', 0600);
		let journal = read_client_enrollment(directory);
		// An abandoned registration, or a registered device that has since
		// been removed: the retirement is checked against the state below.
		let invited = filter(journal.ledger.invitations, item => item.id == id)[0], published = read_client_state(directory);
		if (type(expected_generation) != 'int' || expected_generation !== journal.ledger.generation || journal.pending != null ||
			invited == null || !(invited.status == 'aborted' ||
			(invited.status == 'completed' && index(published.retired_ids, id) >= 0)))
			die('credential cleanup not authorized');
		let base = directory + '/credentials', path = base + '/' + id + '.json';
		safe(base, 'directory', 0700); safe(base + '/' + id + '.issued', 'file', 0600);
		if (lstat(path) != null) {
			let record = read_record(path);
			if (record.id != id) die('credential cleanup identity conflict');
			let state = read_client_state(directory), device = filter(state.publication.devices, item => item.id == id)[0];
			if (device != null && (index(state.retired_ids, id) < 0 || device.token_sha256 != record.token_sha256))
				die('credential cleanup publication conflict');
			let secret = account_secret(id);
			if (secret != null) {
				if (secret != '0s' + b64enc(record.password)) die('credential cleanup account conflict');
				// Existing deletion unloads the credential before ending only this
				// user's sessions, then removes its restrictive policy.
				let nonce = random_secret();
				input = '/var/run/ikev2-manager-user-' + nonce + '.in';
				let body = 'remove\n' + id + '\n' + record.password + '\n', file = open(input, 'wxe', 0600);
				if (file == null) die('credential cleanup input unavailable');
				let written = file.write(body), closed = file.close();
				if (written != length(body) || !closed) die('credential cleanup input unavailable');
				try { command('/usr/libexec/ikev2-manager user-owned-input ' + nonce + ' >/dev/null'); }
				catch (error) { if (lstat(input) != null) { safe(input, 'file', 0600); unlink(input); } die('credential cleanup operation failed'); }
				if (lstat(input) != null) { safe(input, 'file', 0600); unlink(input); }
				input = null;
				if (account_secret(id) != null) die('credential cleanup incomplete');
			}
			safe(path, 'file', 0600);
			if (!unlink(path)) die('credential cleanup record unavailable');
			durable();
		} else if (account_secret(id) != null) die('missing credential ownership proof');
		// The issued marker is retained: deleting the secret is not permission
		// to generate another credential for this burned identity.
		lock.close();
		return { version: 1, id: id, credential_removed: true };
	} catch (error) {
		if (input != null && lstat(input) != null) {
			let info = lstat(input);
			if (info.type == 'file' && info.uid == 0 && info.mode == 0600 && info.nlink == 1) unlink(input);
		}
		lock.close();
		die('credential cleanup refused or unavailable');
	}
};
