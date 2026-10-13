// A link that still waits for devices, kept so the administrator can look at
// it again. Beside the client state, for root alone, and no longer than the
// link works: it goes with the link's own end and as soon as the link is
// withdrawn, replaced or used up. A link lasts up to a week, and one kept in
// memory was lost with every restart of the router while it still worked. The
// ledger, which decides whether a link works, keeps digests and never the
// link; a backup carries neither this directory nor anything from it.
'use strict';
import { lstat, mkdir, readfile, writefile, chmod, rename, unlink, lsdir, rmdir } from 'fs';

const DIRECTORY = '/etc/ikev2-manager/clients/links';
// Where earlier versions kept them, in memory.
const EARLIER = '/var/run/ikev2-client-links';

function identifier(value) { return type(value) == 'string' && (length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null) != null; }

function ready() {
	let info = lstat(DIRECTORY);
	if (info == null && mkdir(DIRECTORY, 0700)) info = lstat(DIRECTORY);
	if (!(info?.type == 'directory' && info.uid == 0 && (info.mode & 0077) == 0)) return false;
	// Links issued before an upgrade move over once, checked like any other.
	let earlier = lstat(EARLIER);
	if (earlier?.type == 'directory' && earlier.uid == 0 && (earlier.mode & 0077) == 0) {
		for (let name in lsdir(EARLIER) ?? []) {
			let from = EARLIER + '/' + name, file = lstat(from);
			if (match(name, /^[a-z][a-z0-9-]*\.json$/) && file?.type == 'file' && file.uid == 0 && (file.mode & 0077) == 0 &&
				file.nlink == 1 && file.size <= 4096 && lstat(DIRECTORY + '/' + name) == null) {
				let raw = readfile(from, 4096);
				if (type(raw) == 'string' && writefile(DIRECTORY + '/' + name + '.new', raw) != null &&
					chmod(DIRECTORY + '/' + name + '.new', 0600)) rename(DIRECTORY + '/' + name + '.new', DIRECTORY + '/' + name);
			}
			unlink(from);
		}
		rmdir(EARLIER);
	}
	return true;
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
	if (!identifier(place) || !ready()) return null;
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
	if (!identifier(place) || !ready()) return;
	for (let name in lsdir(DIRECTORY) ?? []) {
		if (!match(name, /\.json$/)) continue;
		let link = kept(name);
		if (link == null || index(link.places, place) >= 0) unlink(DIRECTORY + '/' + name);
	}
};

// Which places have a link that can still be shown: the page says so before
// anybody presses the button.
// `waiting`: the places the ledger still holds open. A link none of whose
// places waits any more - every one used or withdrawn - is of no use to
// anybody and is not kept a moment longer.
export function kept_client_places(now, waiting) {
	let places = {};
	if (!ready()) return places;
	for (let name in lsdir(DIRECTORY) ?? []) {
		if (!match(name, /\.json$/)) continue;
		let link = kept(name);
		if (link == null || link.expires_at <= now || !length(filter(link.places, place => waiting[place] === true))) {
			unlink(DIRECTORY + '/' + name);
			continue;
		}
		for (let place in link.places) places[place] = true;
	}
	return places;
};
