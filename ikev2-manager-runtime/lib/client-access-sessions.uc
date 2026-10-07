// Read only authenticated, installed inbound IKEv2 evidence from local VICI.
// A watcher must bind grants to this kernel SA evidence, not only a reused VIP.
'use strict';

function ipv4(value) {
	if (type(value) != 'string') return false;
	let parts = split(value, '.');
	if (length(parts) != 4) return false;
	for (let part in parts)
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || +part > 255) return false;
	return true;
}

export function authenticated_client_sessions(snapshot) {
	if (type(snapshot) != 'object' || type(snapshot.data) != 'array' ||
		type(snapshot.errors) != 'array' || length(snapshot.errors) || length(snapshot.data) > 4096)
		die('invalid local SA snapshot');
	let sessions = [];
	for (let entry in snapshot.data) {
		if (type(entry) != 'object') die('invalid local SA entry');
		// Both inbound connections authenticate the same accounts; the managed
		// one differs only in the networks it offers.
		let sa = entry['ikev2-in'] ?? entry['ikev2-in-managed'];
		if (sa == null) continue;
		if (type(sa) != 'object') die('invalid inbound SA entry');
		// VICI omits remote-eap-id when the authenticated EAP identity equals
		// remote-id. An explicit different EAP identity always takes precedence.
		let identity = index(keys(sa), 'remote-eap-id') >= 0 ? sa['remote-eap-id'] : sa['remote-id'];
		if (sa.version != '2' || index([ 'ESTABLISHED', 'REKEYING', 'REKEYED' ], sa.state) < 0 ||
			type(identity) != 'string' || !(length(identity) <= 128 ? match(identity, /^[A-Za-z0-9][A-Za-z0-9_.@-]*$/) : null) ||
			type(sa['remote-vips']) != 'array' || length(sa['remote-vips']) != 1 ||
			!ipv4(sa['remote-vips'][0]) || type(sa['child-sas']) != 'object') continue;
		let address = sa['remote-vips'][0];
		for (let key, child in sa['child-sas']) {
			if (type(child) != 'object' || child.name != 'net' || index([ 'INSTALLED', 'UPDATING', 'REKEYING', 'REKEYED' ], child.state) < 0 ||
				child.mode != 'TUNNEL' || child.protocol != 'ESP' ||
				child['if-id-in'] != '0000002b' || child['if-id-out'] != '0000002b' ||
				type(child.reqid) != 'string' || !match(child.reqid, /^[1-9][0-9]{0,9}$/) || +child.reqid > 4294967295 ||
				type(child['spi-in']) != 'string' || !match(child['spi-in'], /^[a-f0-9]{8}$/) || child['spi-in'] == '00000000' ||
				type(child['spi-out']) != 'string' || !match(child['spi-out'], /^[a-f0-9]{8}$/) || child['spi-out'] == '00000000' ||
				type(child['remote-ts']) != 'array' || length(child['remote-ts']) != 1 ||
				(child['remote-ts'][0] != address && child['remote-ts'][0] != address + '/32')) continue;
			push(sessions, { identity: identity, address: address, reqid: +child.reqid,
				spi_in: child['spi-in'], spi_out: child['spi-out'] });
		}
	}
	return sessions;
};
