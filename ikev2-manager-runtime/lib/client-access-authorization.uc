// Compile the router guard from an authenticated SA snapshot and server-owned
// assignments. Neither input may come from the enrolling desktop client.
'use strict';
import { compile_client_policy, validate_client_subnet } from './client-access.uc';
import { authenticated_client_sessions } from './client-access-sessions.uc';

function refuse() {
	die('client-access-authorization: invalid authorization snapshot');
}

function fields(object, names) {
	if (type(object) != 'object' || length(keys(object)) != length(names))
		refuse();
	for (let name in names)
		if (object[name] == null)
			refuse();
}

function address(value) {
	if (type(value) != 'string')
		refuse();
	let parts = split(value, '.');
	if (length(parts) != 4)
		refuse();
	let number = 0;
	for (let part in parts) {
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || +part > 255)
			refuse();
		number = number * 256 + +part;
	}
	return number;
}

function identity(value) {
	if (type(value) != 'string' || !match(value, /^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$/))
		refuse();
	return value;
}

export function compile_client_authorization(input) {
	fields(input, [ 'version', 'pool', 'policies', 'users', 'sessions', 'lease_seconds' ]);
	if (input.version !== 1 || type(input.lease_seconds) != 'int' ||
		input.lease_seconds < 5 || input.lease_seconds > 120)
		refuse();
	fields(input.pool, [ 'first', 'last' ]);
	let first = address(input.pool.first), last = address(input.pool.last);
	if (first > last || type(input.policies) != 'array' || !length(input.policies) ||
		type(input.users) != 'array' || type(input.sessions) != 'array')
		refuse();
	let policies = {}, users = {}, owners = {}, ambiguous = {}, subnet = null;
	let destinations = {}, names = {};
	for (let document in input.policies) {
		let compiled = compile_client_policy(document);
		if (policies[document.id] || (subnet != null && subnet != document.virtual_subnet))
			refuse();
		policies[document.id] = compiled;
		subnet = document.virtual_subnet;
		for (let resource in document.resources) {
			let target = `${resource.domain}|${document.exit}`;
			if ((destinations[resource.address] && destinations[resource.address] != target) ||
				(names[resource.domain] && names[resource.domain] != resource.address))
				refuse();
			destinations[resource.address] = target;
			names[resource.domain] = resource.address;
		}
	}
	let subnet_parts = split(subnet, '/'), virtual_first = address(subnet_parts[0]), size = 1;
	for (let bit = +subnet_parts[1]; bit < 32; bit++)
		size *= 2;
	if (first <= virtual_first + size - 1 && last >= virtual_first)
		refuse();
	for (let user in input.users) {
		fields(user, [ 'identity', 'policy' ]);
		identity(user.identity);
		if (type(user.policy) != 'string' || !policies[user.policy] || users[user.identity])
			refuse();
		users[user.identity] = user.policy;
	}
	let bindings = {};
	for (let session in input.sessions) {
		fields(session, [ 'identity', 'address', 'reqid', 'spi_in', 'spi_out' ]);
		identity(session.identity);
		let number = address(session.address);
		if (type(session.reqid) != 'int' || session.reqid < 1 || session.reqid > 4294967295)
			refuse();
		for (let spi in [ session.spi_in, session.spi_out ])
			if (type(spi) != 'string' || !match(spi, /^[a-f0-9]{8}$/) || spi == '00000000')
				refuse();
		if (number < first || number > last)
			continue;
		if (owners[session.address] && owners[session.address] != session.identity)
			ambiguous[session.address] = true;
		owners[session.address] = session.identity;
		for (let binding in [ `in|${session.reqid}|${session.spi_in}`, `out|${session.reqid}|${session.spi_out}` ]) {
			let previous = bindings[binding];
			if (previous && (previous.identity != session.identity || previous.address != session.address)) {
				ambiguous[previous.address] = true;
				ambiguous[session.address] = true;
			}
			bindings[binding] = session;
		}
	}
	let tuples = { tcp: {}, udp: {} }, inbound = { tcp: {}, udp: {} }, outbound = { tcp: {}, udp: {} };
	for (let session in input.sessions) {
		let vip = session.address, policy = users[session.identity], number = address(vip);
		if (number < first || number > last || ambiguous[vip] || !policy)
			continue;
		for (let resource in policies[policy].policy.resources)
			for (let transport in resource.transports)
				for (let port in transport.ports) {
					let tuple = `${vip} . ${resource.address} . ${port}`;
					tuples[transport.protocol][tuple] = true;
					inbound[transport.protocol][`${session.reqid} . 0x${session.spi_in} . ${tuple}`] = true;
					outbound[transport.protocol][`${session.reqid} . 0x${session.spi_out} . ${tuple}`] = true;
				}
	}
	let admitted = {};
	for (let session in input.sessions) {
		let number = address(session.address);
		if (number >= first && number <= last && !ambiguous[session.address] && users[session.identity])
			admitted[`${session.address}|${session.reqid}|${session.spi_in}|${session.spi_out}`] = session;
	}
	let nft = 'table inet ikev2_client_access {\n';
	nft += '  chain ikev2_manager_owned { }\n';
	for (let protocol in [ 'tcp', 'udp' ]) {
		let elements = sort(keys(tuples[protocol]));
		nft += `  set allow_${protocol} {\n    type ipv4_addr . ipv4_addr . inet_service\n`;
		nft += `    flags timeout\n    timeout ${input.lease_seconds}s\n`;
		if (length(elements)) nft += `    elements = { ${join(', ', elements)} }\n`;
		nft += '  }\n';
	}
	// Scalar SA checks and timed address grants form one atomic table. Named
	// address types also survive nft's reconstruction of expiring set elements.
	nft += '  chain prerouting {\n    type filter hook prerouting priority -165; policy accept;\n';
	nft += `    ip daddr ${subnet} jump authorize\n  }\n`;
	nft += '  chain authorize {\n    iifname != "ipsec-in" counter drop\n';
	for (let key in sort(keys(admitted))) {
		let session = admitted[key];
		nft += `    ip saddr ${session.address} ipsec in reqid ${session.reqid} ipsec in spi 0x${session.spi_in} jump authorize_services\n`;
	}
	nft += '    counter drop\n  }\n';
	nft += '  chain authorize_services {\n';
	for (let protocol in [ 'tcp', 'udp' ])
		nft += `    meta l4proto ${protocol} ip saddr . ip daddr . ${protocol} dport @allow_${protocol} meta mark set 0x00800000 counter accept\n`;
	nft += '    counter drop\n  }\n';
	// Replies are closed before XFRM and checked against the outbound SA after
	// XFRM supplies its metadata during the subsequent postrouting traversal.
	nft += '  chain output {\n    type filter hook output priority -165; policy accept;\n';
	nft += `    ip saddr ${subnet} jump authorize_reply\n  }\n`;
	nft += '  chain authorize_reply {\n    oifname != "ipsec-in" counter drop\n';
	for (let protocol in [ 'tcp', 'udp' ])
		nft += `    meta l4proto ${protocol} ip daddr . ip saddr . ${protocol} sport @allow_${protocol} meta mark set 0x00800000 counter accept\n`;
	nft += '    counter drop\n  }\n';
	nft += '  chain postrouting {\n    type filter hook postrouting priority 0; policy accept;\n';
	nft += `    ip saddr ${subnet} jump authorize_outbound\n  }\n`;
	nft += '  chain authorize_outbound {\n    oifname "ipsec-in" return\n';
	for (let key in sort(keys(admitted))) {
		let session = admitted[key];
		nft += `    ip daddr ${session.address} ipsec out reqid ${session.reqid} ipsec out spi 0x${session.spi_out} jump authorize_reply_services\n`;
	}
	nft += '    counter drop\n  }\n';
	nft += '  chain authorize_reply_services {\n';
	for (let protocol in [ 'tcp', 'udp' ])
		nft += `    meta l4proto ${protocol} ip daddr . ip saddr . ${protocol} sport @allow_${protocol} meta mark set 0x00800000 counter accept\n`;
	nft += '    counter drop\n  }\n}\n';
	return { version: 1, virtual_subnet: subnet, tcp: sort(keys(tuples.tcp)), udp: sort(keys(tuples.udp)),
		tcp_in: sort(keys(inbound.tcp)), tcp_out: sort(keys(outbound.tcp)),
		udp_in: sort(keys(inbound.udp)), udp_out: sort(keys(outbound.udp)),
		ambiguous_addresses: length(keys(ambiguous)), sessions: map(keys(admitted), key => admitted[key]), nft: nft };
};


export function compile_client_denial(subnet) {
	validate_client_subnet(subnet);
	let nft = 'table inet ikev2_client_access {\n  chain ikev2_manager_owned { }\n';
	for (let protocol in [ 'tcp', 'udp' ])
		nft += `  set allow_${protocol} { type ipv4_addr . ipv4_addr . inet_service; flags timeout; timeout 15s; }\n`;
	for (let hook in [ 'prerouting', 'output', 'postrouting' ]) {
		let direction = hook == 'prerouting' ? 'daddr' : 'saddr';
		let priority = hook == 'postrouting' ? 0 : -165;
		nft += `  chain ${hook} { type filter hook ${hook} priority ${priority}; policy accept; ip ${direction} ${subnet} counter drop; }\n`;
	}
	nft += '}\n';
	return { version: 1, virtual_subnet: subnet, nft: nft, tcp: [], udp: [] };
};


// The controller reads API publication from its protected local state and SA
// evidence from local VICI. Device IDs are the separately provisioned EAP IDs.
export function reconcile_client_authorization(input) {
	fields(input, [ 'version', 'pool', 'api', 'snapshot', 'lease_seconds' ]);
	if (input.version !== 1) refuse();
	fields(input.api, [ 'version', 'devices' ]);
	if (input.api.version !== 1 || type(input.api.devices) != 'array' || length(input.api.devices) > 512)
		refuse();
	let policies = {}, documents = [], ids = {}, hashes = {}, users = [];
	for (let device in input.api.devices) {
		fields(device, [ 'id', 'token_sha256', 'enabled', 'policy' ]);
		if (type(device.id) != 'string' || !match(device.id, /^[a-z][a-z0-9-]{0,47}$/) || ids[device.id] ||
			type(device.token_sha256) != 'string' || !match(device.token_sha256, /^[a-f0-9]{64}$/) || hashes[device.token_sha256] ||
			type(device.enabled) != 'bool') refuse();
		ids[device.id] = true;
		hashes[device.token_sha256] = true;
		let policy = compile_client_policy(device.policy).policy;
		let serialized = sprintf('%J', policy);
		if (policies[policy.id] != null && policies[policy.id] != serialized) refuse();
		if (policies[policy.id] == null) push(documents, policy);
		policies[policy.id] = serialized;
		if (device.enabled) push(users, { identity: device.id, policy: policy.id });
	}
	return compile_client_authorization({ version: 1, pool: input.pool,
		policies: documents, users: users, sessions: authenticated_client_sessions(input.snapshot),
		lease_seconds: input.lease_seconds });
};
