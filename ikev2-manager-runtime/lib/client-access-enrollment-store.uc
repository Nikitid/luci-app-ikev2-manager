// Root-only invitation journal. Reservation survives interruption before any
// external credential/publication operation; replay can never recreate it.
'use strict';
import { lstat, open, rename, unlink } from 'fs';
import { prepare_client_enrollment, validate_client_invitations } from './client-access-enrollment.uc';
import { read_client_state, publish_client_state } from './client-access-store.uc';
import { validate_client_state, prepare_client_state } from './client-access-state.uc';

function safe_directory(directory) {
	let info = lstat(directory);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700)
		die('unsafe enrollment directory');
}

function safe_file(path) {
	let info = lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1)
		die('unsafe enrollment file');
	return info;
}

function durable() {
	if (system('/bin/sync') != 0) die('unable to synchronize enrollment');
}

function validate(journal) {
	if (type(journal) != 'object' || length(keys(journal)) != 3 || journal.version !== 1 ||
		!('ledger' in journal) || !('pending' in journal)) die('invalid enrollment journal');
	validate_client_invitations(journal.ledger);
	if (journal.pending != null) {
		let pending = journal.pending;
		if (type(pending) != 'object' || length(keys(pending)) != 2 ||
			!('id' in pending) || !('state' in pending)) die('invalid pending enrollment');
		validate_client_state(pending.state);
		let invitation = filter(journal.ledger.invitations, item => item.id == pending.id && item.status == 'reserved')[0];
		let device = filter(pending.state.publication.devices, device => device.id == pending.id)[0];
		if (invitation == null || device == null || device.enabled ||
			length(filter(journal.ledger.invitations, item => item.token_sha256 == device.token_sha256)) ||
			sprintf('%J', device.selected_services) != sprintf('%J', invitation.selected_services))
			die('enrollment pending identity mismatch');
	}
	return journal;
}

function commit_journal(directory, journal, initialize) {
	validate(journal);
	let temporary = directory + '/invitations.pending';
	if (lstat(temporary) != null) {
		safe_file(temporary);
		if (!unlink(temporary)) die('unable to remove interrupted enrollment');
	}
	let raw = sprintf('%J\n', journal);
	if (length(raw) > 16777216) die('enrollment journal exceeds size limit');
	let file = open(temporary, 'wxe', 0600);
	if (file == null) die('unable to stage enrollment');
	let written = file.write(raw), closed = file.close();
	if (written != length(raw) || !closed) die('unable to stage enrollment');
	safe_file(temporary);
	durable();
	if (initialize) {
		let marker = directory + '/enrollment-initialized';
		let sentinel = open(marker, 'wxe', 0600);
		if (sentinel == null || sentinel.write('1\n') != 2 || !sentinel.close()) die('unable to initialize enrollment');
		durable();
	}
	if (!rename(temporary, directory + '/invitations.json')) die('unable to commit enrollment');
	durable();
}

export function read_client_enrollment(directory) {
	safe_directory(directory);
	let path = directory + '/invitations.json', info = safe_file(path);
	if (info.size < 1 || info.size > 16777216) die('invalid enrollment journal size');
	let file = open(path, 're');
	if (file == null) die('unable to read enrollment journal');
	let raw = file.read(16777217);
	file.close();
	if (type(raw) != 'string' || length(raw) > 16777216) die('invalid enrollment journal size');
	return validate(json(raw));
};

export function write_client_enrollment(directory, request, now, initialize) {
	safe_directory(directory);
	if (type(initialize) != 'bool') die('invalid enrollment initialization');
	let lockpath = directory + '/enrollment.lock';
	if (lstat(lockpath) != null) safe_file(lockpath);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null) die('unable to open enrollment lock');
	if (!lock.lock('xn')) { lock.close(); die('enrollment is busy'); }
	try {
		safe_file(lockpath);
		let path = directory + '/invitations.json', marker = directory + '/enrollment-initialized';
		let previous;
		if (initialize) {
			if (lstat(path) != null || lstat(marker) != null) die('enrollment already initialized');
			previous = { version: 1, ledger: { version: 1, generation: 0, updated_at: 0, invitations: [] }, pending: null };
		} else {
			safe_file(marker);
			previous = read_client_enrollment(directory);
		}
		if (previous.pending != null) die('enrollment requires recovery');
		let prepared = prepare_client_enrollment({ ledger: previous.ledger,
			state: read_client_state(directory), request: request, now: now });
		let pending = null;
		if (prepared.proposed_state != null) {
			let id = filter(prepared.ledger.invitations, item => item.token_sha256 == request.payload.invitation_sha256)[0].id;
			pending = { id: id, state: prepared.proposed_state };
		}
		let journal = validate({ version: 1, ledger: prepared.ledger, pending: pending });
		commit_journal(directory, journal, initialize);
		lock.close();
		return journal;
	} catch (error) {
		lock.close();
		die('enrollment refused or unavailable');
	}
};

// Completes the disabled publication only. Credential provisioning and client
// protection activation are separate gates; this operation cannot enable access.
export function finalize_client_enrollment(directory, expected_generation, now) {
	safe_directory(directory);
	let lockpath = directory + '/enrollment.lock';
	safe_file(lockpath);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null) die('unable to open enrollment lock');
	if (!lock.lock('xn')) { lock.close(); die('enrollment is busy'); }
	try {
		safe_file(lockpath);
		safe_file(directory + '/enrollment-initialized');
		let journal = read_client_enrollment(directory);
		if (type(expected_generation) != 'int' || expected_generation !== journal.ledger.generation ||
			journal.ledger.generation == 2147483647 || type(now) != 'int' ||
			now < journal.ledger.updated_at || now > 9007199254737391 || journal.pending == null)
			die('stale enrollment finalization');
		let pending = journal.pending;
		let device = filter(pending.state.publication.devices, device => device.id == pending.id)[0];
		let current = read_client_state(directory);
		let existing = filter(current.publication.devices, item => item.id == pending.id)[0];
		if (existing != null) {
			// A crash after publication but before journal completion is safe to
			// recover, including centrally updated domains. Never overwrite it.
			if (existing.enabled || index(current.retired_ids, pending.id) >= 0 ||
				existing.token_sha256 != device.token_sha256 ||
				sprintf('%J', existing.selected_services) != sprintf('%J', device.selected_services))
				die('enrollment publication conflict');
		} else {
			// Catalog publication may have advanced while registration ran.
			// Rebase the new disabled device on current history, never the old
			// whole snapshot. CAS still rejects another concurrent publisher.
			for (let id in device.selected_services)
				if (!length(filter(current.publication.services, item => item.id == id && item.client_access)))
					die('enrollment service unavailable');
			let desired = json(sprintf('%J', current.publication));
			delete desired.allocations;
			desired.devices = filter(desired.devices, item => index(current.retired_ids, item.id) < 0);
			for (let item in desired.devices) delete item.previous_policy;
			let new_device = json(sprintf('%J', device));
			delete new_device.previous_policy;
			push(desired.devices, new_device);
			journal.pending.state = prepare_client_state({ version: 1, expected_generation: current.generation,
				previous: current, desired: desired });
			commit_journal(directory, journal, false);
			publish_client_state(directory, desired, current.generation, false);
			current = read_client_state(directory);
		}
		let committed = filter(current.publication.devices, item => item.id == pending.id)[0];
		if (committed == null || committed.enabled || index(current.retired_ids, pending.id) >= 0 ||
			committed.token_sha256 != device.token_sha256 ||
			sprintf('%J', committed.selected_services) != sprintf('%J', device.selected_services))
			die('enrollment changed during finalization');
		let policy = filter(current.api.devices, item => item.id == pending.id)[0].policy;
		filter(journal.ledger.invitations, item => item.id == pending.id)[0].status = 'completed';
		journal.ledger.generation++;
		journal.ledger.updated_at = now;
		journal.pending = null;
		commit_journal(directory, journal, false);
		lock.close();
		return { generation: journal.ledger.generation, policy: policy };
	} catch (error) {
		lock.close();
		die('enrollment finalization refused or unavailable');
	}
};

// Explicit administrative abandonment retires only the matching device key.
// External IKE credentials require separate cleanup by their provisioning owner.
export function abandon_client_enrollment(directory, expected_generation, now) {
	safe_directory(directory);
	let lockpath = directory + '/enrollment.lock';
	safe_file(lockpath);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null) die('unable to open enrollment lock');
	if (!lock.lock('xn')) { lock.close(); die('enrollment is busy'); }
	try {
		safe_file(lockpath);
		safe_file(directory + '/enrollment-initialized');
		let journal = read_client_enrollment(directory);
		if (type(expected_generation) != 'int' || expected_generation !== journal.ledger.generation ||
			journal.ledger.generation == 2147483647 || type(now) != 'int' ||
			now < journal.ledger.updated_at || now > 9007199254737391 || journal.pending == null)
			die('stale enrollment abandonment');
		let pending = journal.pending;
		let proposed = filter(pending.state.publication.devices, item => item.id == pending.id)[0];
		let current = read_client_state(directory);
		let existing = filter(current.publication.devices, item => item.id == pending.id)[0];
		if (existing != null) {
			if (existing.token_sha256 != proposed.token_sha256) die('enrollment publication conflict');
			if (index(current.retired_ids, pending.id) < 0) {
				let desired = json(sprintf('%J', current.publication));
				delete desired.allocations;
				desired.devices = filter(desired.devices, item => item.id != pending.id && index(current.retired_ids, item.id) < 0);
				for (let item in desired.devices) delete item.previous_policy;
				publish_client_state(directory, desired, current.generation, false);
			}
		}
		filter(journal.ledger.invitations, item => item.id == pending.id)[0].status = 'aborted';
		journal.ledger.generation++;
		journal.ledger.updated_at = now;
		journal.pending = null;
		commit_journal(directory, journal, false);
		lock.close();
		return { generation: journal.ledger.generation };
	} catch (error) {
		lock.close();
		die('enrollment abandonment refused or unavailable');
	}
};

