// Root-owned atomic snapshot publication. No HTTP request can call the writer.
'use strict';
import { open, lstat, rename, unlink } from 'fs';
import { prepare_client_state, validate_client_state } from './client-access-state.uc';

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

export function read_client_state(directory) {
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
	return validate_client_state(json(raw));
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
			previous = read_client_state(directory);
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
		lock.close();
		return snapshot.generation;
	} catch (error) {
		if (file != null)
			file.close();
		lock.close();
		die('client publication failed');
	}
};
