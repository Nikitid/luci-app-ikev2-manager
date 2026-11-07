// Addresses a person adds for themselves. The administrator allows it for a
// person's devices with a limit and the ports they open; each device then
// keeps its own list of sites and networks, published as a service of that
// device alone ("own-" and the device's identifier, which no catalogue
// service can be called: catalogue identifiers have no hyphen).
//
// What a person may add is narrower than what a service of the administrator
// may carry: public names and public networks only, so nobody reaches the
// router's own networks or another private network through their own list.
'use strict';

function fail(message) {
	die(`client-access-own: ${message}`);
}

// A refusal of one entry a person wrote: why, and the entry as written, so
// the device can say which one and what is wrong with it.
function refuse(reason, entry) {
	die(`client-access-own: [${reason}] ${type(entry) == 'string' ? entry : ''}`);
}

// The reason and entry of a refusal, or null for any other error.
export function own_refusal(error) {
	let found = match(type(error) == 'object' ? `${error.message}` : `${error}`, /client-access-own: \[([a-z_]+)\] ?(.*)$/);
	return found ? { reason: found[1], entry: found[2] } : null;
};

export const OWN_PREFIX = 'own-';
export const OWN_LIMIT = 32;

export function own_service_id(device) {
	if (type(device) != 'string' || !(length(device) <= 44 ? match(device, /^[a-z][a-z0-9-]*$/) : null))
		fail('this device cannot keep its own addresses');
	return OWN_PREFIX + device;
};

export function is_own_service(id) {
	return type(id) == 'string' && substr(id, 0, length(OWN_PREFIX)) == OWN_PREFIX;
};

// The administrator's rule: how many entries and which ports.
export function check_own_rule(rule) {
	if (type(rule) != 'object' || length(keys(rule)) != 2 || !('limit' in rule) || !('ports' in rule))
		fail('invalid rule');
	if (type(rule.limit) != 'int' || rule.limit < 1 || rule.limit > OWN_LIMIT)
		fail('invalid limit');
	if (type(rule.ports) != 'array' || length(rule.ports) < 1 || length(rule.ports) > 16)
		fail('invalid ports');
	let seen = {};
	for (let port in rule.ports) {
		if (type(port) != 'int' || port < 1 || port > 65535 || seen[`${port}`]) fail('invalid port');
		seen[`${port}`] = true;
	}
	return { limit: rule.limit, ports: sort(slice(rule.ports), (a, b) => a - b) };
};

function number(text, entry) {
	let parts = split(text, '.'), value = 0;
	if (length(parts) != 4) refuse('invalid_network', entry);
	for (let part in parts) {
		if (!(length(part) <= 3 ? match(part, /^(0|[1-9][0-9]*)$/) : null) || +part > 255) refuse('invalid_network', entry);
		value = value * 256 + +part;
	}
	return value;
}

function text_of(value) {
	let octets = [];
	for (let place = 0; place < 4; place++) {
		unshift(octets, value % 256);
		value = (value - value % 256) / 256;
	}
	return join('.', octets);
}

// Ranges no person's list may touch, each with the reason a device shows:
// unroutable and this host, private, shared, the benchmarking range FakeIP
// uses, documentation and multicast.
const RESERVED = [
	[ '0.0.0.0', 8, 'local' ], [ '10.0.0.0', 8, 'private' ], [ '100.64.0.0', 10, 'shared' ], [ '127.0.0.0', 8, 'local' ],
	[ '169.254.0.0', 16, 'local' ], [ '172.16.0.0', 12, 'private' ], [ '192.0.0.0', 24, 'local' ],
	[ '192.0.2.0', 24, 'documentation' ], [ '192.168.0.0', 16, 'private' ], [ '198.18.0.0', 15, 'fake_ip' ],
	[ '198.51.100.0', 24, 'documentation' ], [ '203.0.113.0', 24, 'documentation' ], [ '224.0.0.0', 3, 'multicast' ]
];

function span(prefix) {
	let size = 1;
	for (let bit = prefix; bit < 32; bit++) size *= 2;
	return size;
}

// One network as a person wrote it: an address alone is the host, a range is
// set at its base. Nothing wider than /16.
export function own_network(value) {
	if (type(value) != 'string' || length(value) > 18) refuse('invalid_network', value);
	let parts = split(trim(value), '/');
	if (length(parts) > 2) refuse('invalid_network', value);
	let prefix = length(parts) == 2 ? (match(parts[1], /^[0-9]{1,2}$/) ? +parts[1] : -1) : 32;
	if (prefix < 16 || prefix > 32) refuse('network_size', value);
	let size = span(prefix), first = number(parts[0], value);
	first -= first % size;
	let last = first + size - 1;
	for (let item in RESERVED) {
		let base = number(item[0]), end = base + span(item[1]) - 1;
		if (first <= end && last >= base) refuse(item[2], value);
	}
	return `${text_of(first)}/${prefix}`;
};

export function own_domain(value) {
	if (type(value) != 'string') refuse('invalid_site', value);
	let name = lc(trim(value));
	// A link is taken for its host.
	name = replace(replace(name, /^[a-z][a-z0-9+.-]*:\/\//, ''), /[\/?#:].*$/, '');
	name = replace(name, /\.$/, '');
	if (length(name) > 253 || length(split(name, '.')) < 2 || match(name, /^[0-9.]+$/)) refuse('invalid_site', value);
	for (let label in split(name, '.'))
		if (!(length(label) <= 63 ? match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) : null)) refuse('invalid_site', value);
	let labels = split(name, '.'), top = labels[length(labels) - 1];
	if (index([ 'local', 'lan', 'home', 'internal', 'localhost', 'arpa', 'test', 'invalid', 'example' ], top) >= 0)
		refuse('local_name', value);
	return name;
};

// What a device sends: its sites and networks, checked and in a stable order,
// within the administrator's limit. The server's own names never go into the
// tunnel: the tunnel is reached through them.
export function check_own_entries(input, rule, server) {
	if (type(input) != 'object' || length(keys(input)) != 2 || type(input.domains) != 'array' || type(input.networks) != 'array')
		fail('invalid list');
	if (length(input.domains) + length(input.networks) > rule.limit) refuse('over_limit', '');
	let domains = {}, networks = {};
	for (let item in input.domains) {
		let name = own_domain(item);
		if (name == server?.address || name == server?.remote_id) refuse('server_name', item);
		domains[name] = true;
	}
	for (let item in input.networks) networks[own_network(item)] = true;
	return { domains: sort(keys(domains)), networks: sort(keys(networks)) };
};

// The service a device's own list becomes, or null when the list is empty.
export function own_service(device, entries, rule) {
	if (!length(entries.domains) && !length(entries.networks)) return null;
	let service = { id: own_service_id(device), client_access: true, domains: entries.domains,
		transports: [ { protocol: 'tcp', ports: rule.ports }, { protocol: 'udp', ports: rule.ports } ] };
	if (length(entries.networks)) service.networks = entries.networks;
	return service;
};
