// What each device is answered with, laid out one small file per device when
// the state is published. The device API reads the one file of the caller,
// and the controller the files of the devices that are connected: neither
// reads, let alone compiles, the whole state for every request. The state
// stays the only truth; the views are rebuilt from it and never the reverse.
'use strict';
import { sha256 } from 'digest';
import { lstat, mkdir, open, rename, unlink, rmdir, symlink, readlink, lsdir } from 'fs';

function generation_of(name) {
	let found = type(name) == 'string' && length(name) <= 24 ? match(name, /^views-([1-9][0-9]*)$/) : null;
	return found == null ? null : +found[1];
}

// The directory the link names, if it is one this module made.
function current(directory) {
	let link = lstat(directory + '/views');
	if (link == null) return null;
	if (link.type != 'link' || link.uid != 0) die('unsafe client views');
	let name = readlink(directory + '/views');
	if (generation_of(name) == null) die('unsafe client views');
	let info = lstat(directory + '/' + name);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe client views');
	return name;
}

function put(path, value) {
	let file = open(path, 'wxe', 0600), raw = sprintf('%J\n', value);
	if (file == null || file.write(raw) != length(raw) || !file.close()) die('unable to write a client view');
}

function clear(path) {
	for (let name in lsdir(path) ?? []) unlink(path + '/' + name);
	rmdir(path);
}

// Which file the views were made from. A state file that is not that very
// file - replaced, edited, restored - makes them void: whoever reads then
// falls back to the state itself, which is checked in full.
function origin(directory) {
	let folder = lstat(directory), info = lstat(directory + '/state.json');
	if (folder?.type != 'directory' || folder.uid != 0 || folder.mode != 0700 ||
		info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1) return null;
	return { inode: info.inode, size: info.size, mtime: info.mtime };
}

// The generation the views stand for, or null when there are none or they
// were made from another state file than the one now in place.
export function client_views_generation(directory) {
	let name = current(directory);
	if (name == null) return null;
	let now = origin(directory), meta = null;
	try { meta = json(open(directory + '/' + name + '/meta.json', 're').read(4096)); } catch (error) { meta = null; }
	if (now == null || type(meta?.state) != 'object' || meta.state.inode !== now.inode || meta.state.size !== now.size ||
		meta.state.mtime !== now.mtime || meta.generation !== generation_of(name)) return null;
	return meta.generation;
};

export function write_client_views(directory, state) {
	let name = 'views-' + state.generation, path = directory + '/' + name;
	let retired = {}, published = {}, open_devices = {};
	for (let id in state.retired_ids) retired[id] = true;
	for (let device in state.publication.devices) published[device.id] = device;
	if (lstat(path) != null) clear(path);
	if (!mkdir(path, 0700)) die('unable to create client views');
	let made_from = origin(directory);
	if (made_from == null) die('unsafe client state');
	put(path + '/meta.json', { version: 1, generation: state.generation, exit: state.publication.exit, state: made_from });
	for (let device in state.api.devices) {
		if (retired[device.id]) continue;
		let own = published[device.id], selected = [], available = [];
		for (let service in state.publication.services) {
			if (!service.client_access) continue;
			push(index(own.selected_services, service.id) >= 0 ? selected : available, { id: service.id, domains: length(service.domains) });
		}
		let by_id = (a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
		let document = { version: 1, generation: state.generation, exit: state.publication.exit, id: device.id,
			// Let in now; and known and not switched off, only without a service.
			enabled: device.enabled, idle: own.enabled === true && !length(own.selected_services),
			revision: device.policy.revision, policy: device.enabled ? device.policy : null,
			// The state given here was checked in full by whoever read or made it.
			policy_sha256: device.enabled ? sha256(sprintf('%J', device.policy)) : null,
			selected: sort(selected, by_id), available: sort(available, by_id) };
		put(path + '/t-' + device.token_sha256 + '.json', document);
		put(path + '/i-' + device.id + '.json', document);
	}
	// One rename moves every reader from the old set to the new one.
	unlink(directory + '/views.new');
	if (!symlink(name, directory + '/views.new') || !rename(directory + '/views.new', directory + '/views')) die('unable to publish client views');
	for (let other in lsdir(directory) ?? [])
		if (other != name && generation_of(other) != null) clear(directory + '/' + other);
};

function read(directory, file) {
	let name = current(directory);
	if (name == null) return null;
	let path = directory + '/' + name + '/' + file, info = lstat(path);
	if (info == null) return null;
	if (info.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1 || info.size < 2 || info.size > 4194304) die('unsafe client view');
	let handle = open(path, 're');
	if (handle == null) die('unreadable client view');
	let raw = handle.read(4194305);
	handle.close();
	let value = json(raw);
	if (type(value) != 'object' || value.version !== 1 || type(value.generation) != 'int') die('invalid client view');
	return value;
}

// By the digest of the key a device presents: the file name is that digest,
// so nothing of another device is opened.
export function read_client_view_by_token(directory, token_sha256) {
	if (type(token_sha256) != 'string' || !(length(token_sha256) == 64 ? match(token_sha256, /^[a-f0-9]+$/) : null)) return null;
	let device = read(directory, 't-' + token_sha256 + '.json');
	return device != null && type(device.id) == 'string' && type(device.enabled) == 'bool' ? device : null;
};

export function read_client_view_by_id(directory, id) {
	if (type(id) != 'string' || !(length(id) <= 48 ? match(id, /^[a-z][a-z0-9-]*$/) : null)) return null;
	let device = read(directory, 'i-' + id + '.json');
	return device != null && device.id === id && type(device.enabled) == 'bool' ? device : null;
};
