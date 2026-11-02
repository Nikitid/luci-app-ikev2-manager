// Remote clients for the stand's full mode, published through the application's
// own store: two people on Waypoint and one published service. Synthetic only.
'use strict';
import { writefile, chmod } from 'fs';
import { publish_client_state } from 'client-access-store';

const directory = '/etc/ikev2-manager/clients';

function token(character) {
	let value = '';
	for (let i = 0; i < 64; i++) value += character;
	return value;
}

publish_client_state(directory, { version: 1,
	server: { address: 'vpn.example.test', remote_id: 'vpn.example.test' },
	virtual_subnet: '172.31.254.0/24', exit: '1',
	services: [
		{ id: 'openai', client_access: true, domains: [ 'api.example.test' ], transports: [ { protocol: 'tcp', ports: [ 443 ] } ] },
		{ id: 'telegram', client_access: true, domains: [ 'chat.example.test' ], transports: [ { protocol: 'tcp', ports: [ 443 ] } ] }
	],
	devices: [
		{ id: 'dave-laptop', token_sha256: token('a'), enabled: true, selected_services: [ 'openai', 'telegram' ] },
		{ id: 'erin-phone', token_sha256: token('b'), enabled: false, selected_services: [ 'telegram' ] }
	] }, 0, true);

writefile(directory + '/labels.json', sprintf('%J\n', { version: 1,
	devices: {
		'dave-laptop': { owner: 'Dave', note: 'Work laptop', email: 'dave@example.test', open: false, full: false, title: 'Laptop' },
		'erin-phone': { owner: 'Erin', note: '', email: 'erin@example.test', open: false, full: false, title: 'Phone' }
	},
	profiles: { alice: 'Dave' } }));
chmod(directory + '/labels.json', 0600);
