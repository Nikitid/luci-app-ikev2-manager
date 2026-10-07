// Outgoing mail for invitation links: the server's settings, kept root-only,
// and one message at a time handed to msmtp. The password never appears in
// what is shown, in process arguments or in a job's status.
'use strict';
import { open, lstat, unlink, popen, readfile, access } from 'fs';
import { record_client_event } from './client-access-journal.uc';

const STORE = '/etc/ikev2-manager/mail.json';
const TOOL = '/usr/bin/msmtp';

function fields(object, names) {
	if (type(object) != 'object' || length(keys(object)) != length(names)) die('invalid mail fields');
	for (let name in names) if (!(name in object)) die('missing mail field');
}

function address(value) {
	return type(value) == 'string' && length(value) <= 254 && match(value, /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$/) != null;
}

// One line of text for a header or a setting: no control characters, so
// nothing can start a line of its own.
function line(value, limit) {
	if (type(value) != 'string' || length(value) > limit) return false;
	for (let i = 0; i < length(value); i++) {
		let code = ord(value, i);
		if (code < 32 || code == 127) return false;
	}
	return true;
}

function stored() {
	let info = lstat(STORE);
	if (info == null) return null;
	if (info.type != 'file' || info.uid != 0 || (info.mode & 0077) != 0 || info.size > 8192) die('unsafe mail settings');
	let settings = json(readfile(STORE));
	fields(settings, [ 'version', 'host', 'port', 'security', 'user', 'password', 'from' ]);
	return settings;
}

function validate(settings) {
	if (settings.version !== 1 || type(settings.host) != 'string' || length(settings.host) > 253 ||
		!match(settings.host, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) ||
		type(settings.port) != 'int' || settings.port < 1 || settings.port > 65535 ||
		index([ 'starttls', 'ssl' ], settings.security) < 0 ||
		!line(settings.user, 254) || !line(settings.password, 512) || index(settings.password, '"') >= 0 ||
		index(settings.user, '"') >= 0 || !address(settings.from))
		die('invalid mail settings');
	return settings;
}

function write_private(path, text) {
	unlink(path);
	let file = open(path, 'wxe', 0600);
	if (file == null || file.write(text) != length(text) || !file.close()) die('unable to write mail file');
}

// RFC 2047: a header that is not plain ASCII travels as base64.
function header(text) {
	for (let i = 0; i < length(text); i++) if (ord(text, i) > 126) return '=?UTF-8?B?' + b64enc(text) + '?=';
	return text;
}

try {
	if (ARGV[0] == 'show' && length(ARGV) == 1) {
		let settings = stored();
		print(sprintf('%J\n', { version: 1, available: access(TOOL, 'x') == true, configured: settings != null,
			host: settings?.host ?? '', port: settings?.port ?? 587, security: settings?.security ?? 'starttls',
			user: settings?.user ?? '', from: settings?.from ?? '', has_password: length(settings?.password ?? '') > 0 }));
	} else if (ARGV[0] == 'save' && length(ARGV) == 1) {
		let request = json(open('/dev/stdin', 're').read(8193));
		fields(request, [ 'version', 'host', 'port', 'security', 'user', 'password', 'from' ]);
		// An empty password field keeps the one already stored.
		if (request.password == null) request.password = stored()?.password ?? '';
		write_private(STORE, sprintf('%J\n', validate(request)));
	} else if (ARGV[0] == 'send' && length(ARGV) == 2) {
		if (!(length(ARGV[1]) <= 64 ? match(ARGV[1], /^[0-9]+-[0-9]+$/) : null)) die('invalid mail job');
		let request = json(open('/dev/stdin', 're').read(16385));
		fields(request, [ 'version', 'to', 'subject', 'body' ]);
		if (request.version !== 1 || !address(request.to) || !line(request.subject, 200) ||
			type(request.body) != 'string' || length(request.body) > 8192) die('invalid mail message');
		let settings = stored();
		if (settings == null) die('mail is not set up');
		validate(settings);
		if (access(TOOL, 'x') != true) die('mail tool is not installed');
		let config = '/var/run/ikev2-client-admin/mail-' + ARGV[1] + '.conf';
		write_private(config, 'account default\nhost ' + settings.host + '\nport ' + settings.port +
			'\ntls on\ntls_starttls ' + (settings.security == 'starttls' ? 'on' : 'off') +
			'\ntls_trust_file /etc/ssl/certs/ca-certificates.crt\ntimeout 30\nfrom ' + settings.from +
			(length(settings.user) ? '\nauth on\nuser ' + settings.user + '\npassword "' + settings.password + '"' : '\nauth off') + '\n');
		let status = 1;
		try {
			// Addresses are in the checked form above and the paths are ours.
			let mail = popen(TOOL + ' --file=' + config + ' -- ' + request.to + ' >/dev/null 2>&1', 'w');
			if (mail == null) die('mail tool unavailable');
			mail.write('From: ' + settings.from + '\r\nTo: ' + request.to + '\r\nSubject: ' + header(request.subject) +
				'\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n');
			let encoded = b64enc(request.body);
			for (let at = 0; at < length(encoded); at += 76) mail.write(substr(encoded, at, 76) + '\r\n');
			status = mail.close();
		} catch (error) { unlink(config); die('mail was not sent'); }
		unlink(config);
		if (status != 0) die('mail was not accepted');
		record_client_event('mail-sent', request.to);
	} else {
		warn('usage: client-access-mail.uc show|save|send JOB\n'); exit(2);
	}
} catch (error) {
	warn('client-access-mail: refused or unavailable\n'); exit(1);
}
