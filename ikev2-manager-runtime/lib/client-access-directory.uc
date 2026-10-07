// Who is behind a device. None of this decides access: the owner and the note
// are the administrator's words, the computer's name and system are what the
// client says about itself, and the session comes from the local daemon. It is
// kept apart from the committed state so that describing a device can never
// change what the device may reach.
'use strict';
import { lstat, open, readfile, writefile, chmod, rename, mkdir, unlink } from 'fs';

function text(value, limit) {
	// Text on one line, counted in bytes: the page allows 80 and 160
	// characters, each of which may take four. What a page shows must carry
	// neither markup nor control characters from another origin.
	if (type(value) != 'string' || length(value) > limit) return false;
	for (let i = 0; i < length(value); i++) {
		let code = ord(value, i);
		if (code < 32 || code == 127 || code == 60 || code == 62) return false;
	}
	return true;
}
function identifier(value) { return type(value) == 'string' && (length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null) != null; }
function private_file(path, limit) {
	let info = lstat(path);
	if (info == null) return null;
	if (info.type != 'file' || info.uid != 0 || (info.mode & 0077) != 0 || info.nlink != 1 || info.size > limit) die('unsafe directory file');
	return readfile(path, limit);
}
function replace_file(path, value) {
	let raw = sprintf('%J\n', value);
	if (!writefile(path + '.new', raw) || !chmod(path + '.new', 0600) || !rename(path + '.new', path)) die('unable to record');
}

export function read_client_labels(directory) {
	let raw = private_file(directory + '/labels.json', 262144);
	if (raw == null) return {};
	let labels = json(raw), result = {};
	if (type(labels) != 'object' || labels.version !== 1 || type(labels.devices) != 'object') die('invalid labels');
	for (let id, label in labels.devices)
		if (identifier(id) && type(label) == 'object' && text(label.owner, 320) && text(label.note, 640))
			result[id] = { owner: label.owner, note: label.note };
	return result;
};

export function write_client_label(directory, id, owner, note) {
	if (!identifier(id) || !text(owner, 320) || !text(note, 640)) die('invalid label');
	let labels = read_client_labels(directory);
	if (owner == '' && note == '') delete labels[id];
	else labels[id] = { owner: owner, note: note };
	if (length(keys(labels)) > 1024) die('too many labels');
	replace_file(directory + '/labels.json', { version: 1, devices: labels });
};

// What a client says about itself with an authenticated request. Each field
// is kept only in the exact shape a client is expected to send.
export function record_client_seen(directory, id, headers, remote, now) {
	if (!identifier(id) || type(now) != 'int') return;
	let info = lstat(directory);
	if (info == null && mkdir(directory, 0700)) info = lstat(directory);
	if (info?.type != 'directory' || info.uid != 0 || (info.mode & 0077) != 0) return;
	let host = headers['x-client-host'], system = headers['x-client-system'], version = headers['x-client-version'];
	replace_file(directory + '/' + id + '.json', {
		host: type(host) == 'string' && (length(host) <= 63 ? match(host, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) : null) ? host : null,
		system: type(system) == 'string' && (length(system) <= 40 ? match(system, /^(Windows|macOS) [0-9][0-9.]*$/) : null) ? system : null,
		client: type(version) == 'string' && match(version, /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/) ? version : null,
		from: type(remote) == 'string' && (length(remote) <= 45 ? match(remote, /^[0-9a-fA-F.:][0-9a-fA-F.:]+$/) : null) ? remote : null,
		at: now });
};

function read_seen(directory, id) {
	let raw = null;
	try { raw = private_file(directory + '/' + id + '.json', 4096); } catch (error) { raw = null; }
	if (raw == null) return null;
	let seen = json(raw);
	return type(seen) == 'object' && type(seen.at) == 'int' ? seen : null;
}

// The sessions the local daemon holds for inbound accounts, by account name.
export function client_device_sessions(snapshot) {
	let sessions = {};
	if (type(snapshot) != 'object' || type(snapshot.data) != 'array') return sessions;
	for (let entry in snapshot.data) {
		let sa = type(entry) == 'object' ? (entry['ikev2-in'] ?? entry['ikev2-in-managed']) : null;
		if (type(sa) != 'object' || sa.state != 'ESTABLISHED') continue;
		let identity = sa['remote-eap-id'] ?? sa['remote-id'];
		if (!identifier(identity)) continue;
		sessions[identity] = { tunnel_address: type(sa['remote-vips']) == 'array' ? sa['remote-vips'][0] : null,
			remote_address: type(sa['remote-host']) == 'string' ? sa['remote-host'] : null,
			seconds: match(sa.established ?? '', /^[0-9]{1,10}$/) ? +sa.established : null };
	}
	return sessions;
};

// The administrator's view of one device, added to what the state says.
export function describe_client_device(device, labels, seen_directory, sessions, now) {
	let label = labels[device.id], seen = read_seen(seen_directory, device.id), session = sessions[device.id];
	device.owner = label?.owner ?? '';
	device.note = label?.note ?? '';
	device.host = seen?.host;
	device.system = seen?.system;
	device.client = seen?.client;
	device.seen_seconds = seen ? (now >= seen.at ? now - seen.at : 0) : null;
	device.seen_from = seen?.from;
	device.online = session != null;
	device.tunnel_address = session?.tunnel_address;
	device.remote_address = session?.remote_address;
	device.connected_seconds = session?.seconds;
	return device;
};

export function forget_client_device(directory, seen_directory, id) {
	if (!identifier(id)) return;
	let labels = read_client_labels(directory);
	if (id in labels) { delete labels[id]; replace_file(directory + '/labels.json', { version: 1, devices: labels }); }
	unlink(seen_directory + '/' + id + '.json');
};
