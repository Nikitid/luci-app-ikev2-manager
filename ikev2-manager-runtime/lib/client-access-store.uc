// Root-owned atomic snapshot publication. No HTTP request can call the writer.
'use strict';
import { open, lstat, rename, unlink } from 'fs';
import { prepare_client_state, validate_client_state } from './client-access-state.uc';
import { write_client_views } from './client-access-view.uc';

function directory_safe(directory) {
	let info = lstat(directory);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700)
		die('unsafe client state directory');
}

function regular_safe(path) {
	let info = lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1)
		die('unsafe client state file');
	return info;
}

function durable() {
	// fs.file.flush() is only fflush(). BusyBox sync additionally commits the
	// file and directory metadata; both sides of rename need this barrier.
	if (system('/bin/sync') != 0)
		die('unable to synchronize client state');
}

function committed(directory) {
	directory_safe(directory);
	let path = directory + '/state.json', info = regular_safe(path);
	if (info.size < 1 || info.size > 16777216)
		die('invalid client state size');
	let file = open(path, 're');
	if (file == null)
		die('unable to open client state');
	let raw = file.read(16777217);
	file.close();
	if (type(raw) != 'string' || length(raw) > 16777216)
		die('unable to read client state');
	return json(raw);
}

// For whoever is about to change the state: everything in it is compiled
// again and compared, so a change is never built on a snapshot that does not
// hold together.
export function read_client_state(directory) {
	return validate_client_state(committed(directory));
};

// For whoever only reads: the device API on every request, the controller
// every two seconds, the administrator's page. The file can only have been
// put there by the publisher, whole and already checked - the directory and
// the file belong to root alone and are replaced by rename - so its shape is
// confirmed and its content is not compiled again. Compiling it on every read
// cost the router more with each device and each domain.
export function read_committed_client_state(directory) {
	let snapshot = committed(directory);
	if (type(snapshot) != 'object' || snapshot.version !== 1 || type(snapshot.generation) != 'int' || snapshot.generation < 1 ||
		type(snapshot.retired_ids) != 'array' || type(snapshot.publication) != 'object' || type(snapshot.api) != 'object' ||
		type(snapshot.publication.devices) != 'array' || type(snapshot.publication.services) != 'array' ||
		type(snapshot.publication.allocations) != 'array' || type(snapshot.api.devices) != 'array' ||
		length(snapshot.api.devices) != length(snapshot.publication.devices))
		die('invalid client snapshot');
	return snapshot;
};

export function publish_client_state(directory, desired, expected_generation, initialize) {
	directory_safe(directory);
	if (type(initialize) != 'bool')
		die('invalid client initialization mode');
	let lockpath = directory + '/publication.lock';
	if (lstat(lockpath) != null)
		regular_safe(lockpath);
	let lock = open(lockpath, 'ae', 0600);
	if (lock == null)
		die('unable to open publication lock');
	if (!lock.lock('xn')) {
		lock.close();
		die('client publication is busy');
	}
	let temporary = directory + '/state.pending', file = null;
	try {
		regular_safe(lockpath);
		let marker = directory + '/initialized';
		let previous;
		if (initialize) {
			if (lstat(marker) != null || lstat(directory + '/state.json') != null)
				die('client state is already initialized');
			previous = null;
		} else {
			regular_safe(marker);
			// Missing or invalid committed history must never allocate anew.
			// It is checked in full once, where the new state is prepared.
			previous = committed(directory);
		}
		let snapshot = prepare_client_state({ version: 1, expected_generation: expected_generation,
			previous: previous, desired: desired });
		if (lstat(temporary) != null) {
			regular_safe(temporary);
			if (!unlink(temporary))
				die('unable to remove interrupted publication');
		}
		file = open(temporary, 'wxe', 0600);
		let raw = sprintf('%J\n', snapshot);
		if (file == null || file.write(raw) != length(raw))
			die('unable to stage client state');
		if (!file.close())
			die('unable to close staged client state');
		file = null;
		regular_safe(temporary);
		durable();
		if (initialize) {
			let sentinel = open(marker, 'wxe', 0600);
			if (sentinel == null || sentinel.write('1\n') != 2 || !sentinel.close())
				die('unable to initialize client state');
			// If interrupted here, initialization is refused until history is
			// explicitly recovered, rather than silently reusing old addresses.
			durable();
		}
		if (!rename(temporary, directory + '/state.json'))
			die('unable to commit client state');
		durable();
		// What each device is answered with follows the state at once. Should
		// this step be interrupted, the controller notices the older views and
		// makes them again; the state itself is already committed.
		try { write_client_views(directory, snapshot); } catch (error) { warn('client-access-store: device views were not refreshed\n'); }
		lock.close();
		return snapshot.generation;
	} catch (error) {
		if (file != null)
			file.close();
		lock.close();
		die('client publication failed');
	}
};
