// A link that still waits for devices, kept so the administrator can look at
// it again. In memory only and for root alone: it is gone with a restart, with
// the link's own end, and as soon as the link is withdrawn or replaced. The
// ledger, which decides whether a link works, keeps digests and never the link.
'use strict';
import { lstat, mkdir, readfile, writefile, chmod, rename, unlink, lsdir } from 'fs';

const DIRECTORY = '/var/run/ikev2-client-links';

function identifier(value) { return type(value) == 'string' && (length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null) != null; }

function ready() {
	let info = lstat(DIRECTORY);
	if (info == null && mkdir(DIRECTORY, 0700)) info = lstat(DIRECTORY);
	return info?.type == 'directory' && info.uid == 0 && (info.mode & 0077) == 0;
}

function kept(name) {
	let path = DIRECTORY + '/' + name, info = lstat(path);
	if (info == null || info.type != 'file' || info.uid != 0 || (info.mode & 0077) != 0 || info.nlink != 1 || info.size > 4096) return null;
	let value = null;
	try { value = json(readfile(path, 4096)); } catch (error) { value = null; }
	if (type(value) != 'object' || value.version !== 1 || type(value.places) != 'array' || type(value.expires_at) != 'int' ||
		type(value.invitation) != 'string' || length(value.invitation) > 2048) return null;
	return value;
}

// `places`: the identifiers the link holds open, one for each device.
export function keep_client_link(id, places, invitation, expires_at) {
	if (!identifier(id) || type(places) != 'array' || !length(places) || length(places) > 5 || !ready()) return false;
	for (let place in places) if (!identifier(place)) return false;
	let path = DIRECTORY + '/' + id + '.json';
	return writefile(path + '.new', sprintf('%J\n', { version: 1, places: places, invitation: invitation, expires_at: expires_at })) != null &&
		chmod(path + '.new', 0600) && rename(path + '.new', path);
};

// The link that holds this place open, while it lasts.
export function read_client_link(place, now) {
	if (!identifier(place) || lstat(DIRECTORY) == null || !ready()) return null;
	for (let name in lsdir(DIRECTORY) ?? []) {
		if (!match(name, /\.json$/)) continue;
		let link = kept(name);
		if (link == null || link.expires_at <= now) { unlink(DIRECTORY + '/' + name); continue; }
		if (index(link.places, place) >= 0) return link;
	}
	return null;
};

// A place closed or replaced takes the whole link with it: the other places
// of that link are closed by the same action.
export function forget_client_link(place) {
	if (!identifier(place) || lstat(DIRECTORY) == null || !ready()) return;
	for (let name in lsdir(DIRECTORY) ?? []) {
		if (!match(name, /\.json$/)) continue;
		let link = kept(name);
		if (link == null || index(link.places, place) >= 0) unlink(DIRECTORY + '/' + name);
	}
};
