// A device's own account of its state, sent when the administrator asks for
// it. Kept in memory only, one per device; it describes and decides nothing.
'use strict';
import { lstat, mkdir, readfile, writefile, chmod, rename, unlink } from 'fs';

const DIRECTORY = '/var/run/ikev2-client-reports';
export const CLIENT_REPORT_LIMIT = 32768;

function identifier(value) { return type(value) == 'string' && (length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null) != null; }

function ready() {
	let info = lstat(DIRECTORY);
	if (info == null && mkdir(DIRECTORY, 0700)) info = lstat(DIRECTORY);
	return info?.type == 'directory' && info.uid == 0 && (info.mode & 0077) == 0;
}

function own_file(path, limit) {
	let info = lstat(path);
	if (info == null || info.type != 'file' || info.uid != 0 || (info.mode & 0077) != 0 || info.nlink != 1 || info.size > limit) return null;
	return readfile(path, limit);
}

function replace_file(path, raw) {
	return writefile(path + '.new', raw) != null && chmod(path + '.new', 0600) && rename(path + '.new', path);
}

// A request waits a day for the device, then lapses.
export function client_report_wanted(id, now) {
	if (!identifier(id)) return false;
	let asked = own_file(DIRECTORY + '/' + id + '.want', 32);
	return asked != null && match(asked, /^[0-9]+\n$/) != null && now - int(asked) < 86400 && now >= int(asked);
};

export function request_client_report(id, now) {
	if (!identifier(id) || !ready() || !replace_file(DIRECTORY + '/' + id + '.want', now + '\n')) die('unable to ask for a report');
};

// Only what parses as one JSON object is kept, written again by this side.
export function store_client_report(id, text, now) {
	if (!identifier(id) || type(text) != 'string' || length(text) > CLIENT_REPORT_LIMIT || !ready()) return false;
	let report = null;
	try { report = json(text); } catch (error) { report = null; }
	if (type(report) != 'object') return false;
	if (!replace_file(DIRECTORY + '/' + id + '.json', sprintf('%J\n', { version: 1, id: id, received_at: now, report: report }))) return false;
	unlink(DIRECTORY + '/' + id + '.want');
	return true;
};

export function read_client_report(id) {
	return identifier(id) ? own_file(DIRECTORY + '/' + id + '.json', 2 * CLIENT_REPORT_LIMIT) : null;
};

// For the administrator's list: whether a report is awaited, and how old the
// one in hand is.
export function describe_client_report(device, now) {
	device.report_wanted = client_report_wanted(device.id, now);
	let info = identifier(device.id) ? lstat(DIRECTORY + '/' + device.id + '.json') : null;
	device.report_seconds = info?.type == 'file' ? max(0, now - info.mtime) : null;
	return device;
};

export function forget_client_report(id) {
	if (!identifier(id)) return;
	unlink(DIRECTORY + '/' + id + '.want');
	unlink(DIRECTORY + '/' + id + '.json');
};
