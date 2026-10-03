// Answers questions about the active strongSwan SAs from one `swanmon list-sas`
// snapshot on stdin. The shell helpers used to match the `swanctl --raw` text
// with regular expressions; a field order, a nested block or a second
// connection listed after a client silently changed the answer. The JSON form
// is read by key instead.
//
// Exit status: 0 yes or printed, 1 no, 2 the snapshot could not be read.
//
//   installed IKE CHILD    a CHILD_SA named CHILD of IKE is INSTALLED
//   present IKE            an IKE_SA of that connection exists, in any state
//   local-vips IKE         the virtual addresses assigned to this side
//   sessions IKE           "identity<TAB>address" for each EAP client
//   loopback-connecting IKE
//                          a CONNECTING IKE_SA bound to a loopback address
//   tunnels                "index<TAB>installed<TAB>address" for each outbound
//                          tunnel with an IKE_SA: proxy-out is 1, proxy-out-N
//                          is N; installed is 1 when its CHILD_SA is, address
//                          its first virtual IPv4 or -

'use strict';

import { stdin } from 'fs';

function fail_read() {
	exit(2);
}

let text = stdin.read('all');
let snapshot = null;
try {
	snapshot = json(text || '');
}
catch (e) {
	fail_read();
}
if (type(snapshot) != 'object' || type(snapshot.data) != 'array')
	fail_read();
if (type(snapshot.errors) == 'array' && length(snapshot.errors) > 0)
	fail_read();

// Every IKE_SA of connection NAME, in listing order.
function ike_sas(name) {
	let found = [];
	for (let entry in snapshot.data) {
		if (type(entry) != 'object')
			continue;
		let sa = entry[name];
		if (type(sa) == 'object')
			push(found, sa);
	}
	return found;
}

function list(value) {
	if (type(value) == 'array')
		return value;
	if (type(value) == 'string' && length(value) > 0)
		return [ value ];
	return [];
}

let command = ARGV[0];
let ike = ARGV[1];
if (!command || (!ike && command != 'tunnels')) {
	warn('usage: sa.uc {installed IKE CHILD|present IKE|local-vips IKE|sessions IKE|session-ids IKE IDENTITY|loopback-connecting IKE|tunnels}\n');
	exit(2);
}

// Every outbound tunnel in one pass over one snapshot: the watcher asks once
// per pass whatever the number of tunnels.
if (command == 'tunnels') {
	let seen = {};
	for (let entry in snapshot.data) {
		if (type(entry) != 'object')
			continue;
		for (let name, sa in entry) {
			let m = match(name, /^proxy-out(-([2-7]))?$/);
			if (!m || type(sa) != 'object')
				continue;
			let index = m[2] || '1';
			let child = index == '1' ? 'proxy4' : `proxy4-${index}`;
			let installed = false;
			if (type(sa['child-sas']) == 'object')
				for (let key, c in sa['child-sas'])
					if (type(c) == 'object' && c.name == child && c.state == 'INSTALLED')
						installed = true;
			let address = '-';
			for (let vip in list(sa['local-vips']))
				if (address == '-' && match(vip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/))
					address = vip;
			let line = seen[index];
			// A second IKE_SA of the same connection, during a reauthentication
			// or a make-before-break rekey: either one installed is enough.
			if (line && line.installed)
				continue;
			seen[index] = { installed: installed, address: address };
		}
	}
	for (let index in sort(keys(seen)))
		print(index, '\t', seen[index].installed ? 1 : 0, '\t', seen[index].address, '\n');
	exit(0);
}

let sas = ike_sas(ike);

if (command == 'installed') {
	let child = ARGV[2];
	if (!child)
		exit(2);
	for (let sa in sas) {
		if (type(sa['child-sas']) != 'object')
			continue;
		for (let key, c in sa['child-sas'])
			if (type(c) == 'object' && c.name == child && c.state == 'INSTALLED')
				exit(0);
	}
	exit(1);
}
else if (command == 'present') {
	exit(length(sas) > 0 ? 0 : 1);
}
else if (command == 'local-vips') {
	let printed = false;
	for (let sa in sas)
		for (let address in list(sa['local-vips'])) {
			print(address, '\n');
			printed = true;
		}
	exit(printed ? 0 : 1);
}
else if (command == 'sessions') {
	// A client is admitted by its EAP identity and the first address it was
	// given; a session without either has nothing to admit.
	for (let sa in sas) {
		let identity = sa['remote-eap-id'];
		let addresses = list(sa['remote-vips']);
		if (type(identity) != 'string' || length(identity) == 0 || length(addresses) == 0)
			continue;
		if (match(identity, /[\t\n]/) || match(addresses[0], /[\t\n]/))
			continue;
		print(identity, '\t', addresses[0], '\n');
	}
	exit(0);
}
else if (command == 'session-ids') {
	// The IKE SAs of one EAP identity, to end them when the user is removed or
	// its password changes.
	let identity = ARGV[2];
	if (type(identity) != 'string' || length(identity) == 0)
		exit(2);
	for (let sa in sas) {
		let id = sa.uniqueid;
		if (sa['remote-eap-id'] == identity && type(id) == 'string' && match(id, /^[0-9]+$/))
			print(id, '\n');
	}
	exit(0);
}
else if (command == 'loopback-connecting') {
	for (let sa in sas) {
		let host = sa['local-host'];
		if (sa.state == 'CONNECTING' && type(host) == 'string' &&
		    (match(host, /^127\./) || host == '::1'))
			exit(0);
	}
	exit(1);
}

warn(sprintf('sa.uc: unknown command %s\n', command));
exit(2);
