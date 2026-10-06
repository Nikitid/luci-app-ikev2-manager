// Server-owned fixtures for the isolated encrypted controller scenario.
'use strict';
import { writefile, readfile, chmod } from 'fs';
import { publish_client_state, read_client_state } from '/usr/libexec/ikev2-manager.d/client-access-store.uc';
let directory = ARGV[0], mode = ARGV[1], snapshot_path = ARGV[2];
if (mode == 'seed') {
	let hostname = ARGV[3] || 'vpn.example.com';
	let desired = { version: 1, server: { address: hostname, remote_id: hostname },
		virtual_subnet: '172.31.254.0/24', exit: '1',
		services: [ { id: 'api', client_access: true, domains: [ 'api.example.com' ],
			transports: [ { protocol: 'tcp', ports: [ 4443, 4445 ] }, { protocol: 'udp', ports: [ 4444 ] } ] } ],
		devices: [ { id: 'alice', token_sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
			enabled: true, selected_services: [ 'api' ] } ] };
	publish_client_state(directory, desired, 0, true);
} else if (mode == 'revoke' || mode == 'enable' || mode == 'add-domain') {
	let state = read_client_state(directory), desired = state.publication;
	delete desired.allocations;
	for (let device in desired.devices) delete device.previous_policy;
	if (mode == 'add-domain') push(desired.services[0].domains, 'alt.api.example.com');
	else desired.devices[0].enabled = mode == 'enable';
	publish_client_state(directory, desired, state.generation, false);
} else if (mode == 'valid-sa' || mode == 'unknown-sa') {
	let snapshot = { errors: [], data: [ { 'ikev2-in': {
		version: '2', state: 'ESTABLISHED', 'remote-eap-id': mode == 'valid-sa' ? 'alice' : 'unknown',
		'remote-vips': [ '10.25.0.10' ], 'child-sas': { 'net-1': {
			name: 'net', state: 'INSTALLED', mode: 'TUNNEL', protocol: 'ESP',
			'if-id-in': '0000002b', 'if-id-out': '0000002b', reqid: '12',
			'spi-in': '00000100', 'spi-out': '00000200', 'remote-ts': [ '10.25.0.10/32' ]
		} }
	} } ] };
	if (!writefile(snapshot_path, sprintf('%J\n', snapshot)) || !chmod(snapshot_path, 0600))
		die('Unable to publish session fixture');
} else if (mode == 'invalid-state') {
	let state = json(readfile(directory + '/state.json'));
	state.api.devices[0].enabled = false;
	if (!writefile(directory + '/state.json', sprintf('%J\n', state)))
		die('Unable to corrupt isolated fixture');
} else die('Unknown controller fixture mode');
