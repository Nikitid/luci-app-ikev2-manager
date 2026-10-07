// Invitation transitions. The writer must commit reservation before creating
// an IKE credential. Reservation publishes a disabled device, never admission.
'use strict';
import { validate_client_state, prepare_client_state } from './client-access-state.uc';

function fields(value, names) {
	if (type(value) != 'object' || length(keys(value)) != length(names))
		die('invalid enrollment fields');
	for (let name in names)
		if (!(name in value)) die('missing enrollment field');
}

function integer(value, minimum, maximum) {
	if (type(value) != 'int' || value < minimum || value > maximum)
		die('invalid enrollment number');
}

function hash(value) {
	if (type(value) != 'string' || !(length(value) == 64 ? match(value, /^[a-f0-9]+$/) : null))
		die('invalid enrollment digest');
}

function identity(value) {
	if (type(value) != 'string' || !(length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null))
		die('invalid enrollment identity');
}

function services(values) {
	if (type(values) != 'array' || !length(values) || length(values) > 512)
		die('invalid enrollment services');
	let seen = {};
	for (let value in values) {
		if (type(value) != 'string' || !(length(value) <= 48 ? match(value, /^[a-z0-9][a-z0-9_-]*$/) : null) || seen[value])
			die('invalid enrollment service identity');
		seen[value] = true;
	}
}

export function validate_client_invitations(ledger) {
	fields(ledger, [ 'version', 'generation', 'updated_at', 'invitations' ]);
	if (ledger.version !== 1) die('invalid enrollment version');
	integer(ledger.generation, 0, 2147483647);
	integer(ledger.updated_at, 0, 9007199254740991);
	if (type(ledger.invitations) != 'array' || length(ledger.invitations) > 512)
		die('invalid enrollment ledger');
	let ids = {}, hashes = {};
	for (let item in ledger.invitations) {
		fields(item, [ 'id', 'token_sha256', 'selected_services', 'issued_at', 'expires_at', 'status' ]);
		identity(item.id); hash(item.token_sha256); services(item.selected_services);
		integer(item.issued_at, 1, ledger.updated_at);
		integer(item.expires_at, item.issued_at + 60, item.issued_at + 3600);
		if (index([ 'issued', 'reserved', 'cancelled', 'completed', 'aborted' ], item.status) < 0 || ids[item.id] || hashes[item.token_sha256])
			die('duplicate or invalid enrollment invitation');
		ids[item.id] = true; hashes[item.token_sha256] = true;
	}
	if (ledger.generation == 0 && (ledger.updated_at != 0 || length(ledger.invitations)))
		die('invalid initial enrollment ledger');
	return ledger;
};

function desired_state(state) {
	let desired = json(sprintf('%J', state.publication));
	delete desired.allocations;
	desired.devices = filter(desired.devices, device => index(state.retired_ids, device.id) < 0);
	for (let device in desired.devices) delete device.previous_policy;
	return desired;
}

function eligible(state, id, selected) {
	if (length(filter(state.publication.devices, device => device.id == id)))
		die('existing or retired enrollment identity');
	for (let id in selected)
		if (!length(filter(state.publication.services, service => service.id == id && service.client_access)))
			die('enrollment service unavailable');
}

// Administrative input contains no caller-selected secret. The issuer supplies
// a fresh digest after validating the endpoint and current service assignment.
export function prepare_client_invitation(state, request, digest) {
	validate_client_state(state);
	fields(request, [ 'version', 'expected_generation', 'endpoint', 'id', 'selected_services', 'lifetime_seconds' ]);
	if (request.version !== 1) die('invalid invitation version');
	integer(request.expected_generation, 0, 2147483646);
	identity(request.id); services(request.selected_services); hash(digest);
	integer(request.lifetime_seconds, 60, 3600);
	eligible(state, request.id, request.selected_services);
	if (type(request.endpoint) != 'string' || length(request.endpoint) > 2048)
		die('invalid invitation endpoint');
	let endpoint = match(request.endpoint, /^https:\/\/([a-z0-9.-]+)(:([0-9]{1,5}))?\/client\/v1\/enroll$/);
	if (endpoint == null || endpoint[1] != state.publication.server.address ||
		(endpoint[3] != null && (int(endpoint[3]) < 1 || int(endpoint[3]) > 65535 || sprintf('%d', int(endpoint[3])) != endpoint[3])))
		die('invitation endpoint does not match server');
	return { version: 1, expected_generation: request.expected_generation, operation: 'issue', payload: {
		id: request.id, token_sha256: digest, selected_services: request.selected_services,
		lifetime_seconds: request.lifetime_seconds } };
};

export function prepare_client_enrollment(input) {
	fields(input, [ 'ledger', 'state', 'request', 'now' ]);
	let ledger = validate_client_invitations(input.ledger), state = validate_client_state(input.state);
	integer(input.now, 1, 9007199254737391);
	if (input.now < ledger.updated_at) die('enrollment clock moved backwards');
	let request = input.request;
	fields(request, [ 'version', 'expected_generation', 'operation', 'payload' ]);
	if (request.version !== 1 || request.expected_generation !== ledger.generation || ledger.generation == 2147483647)
		die('stale enrollment request');
	let next = json(sprintf('%J', ledger)), payload = request.payload, proposed = null;
	if (request.operation == 'issue') {
		fields(payload, [ 'id', 'token_sha256', 'selected_services', 'lifetime_seconds' ]);
		identity(payload.id); hash(payload.token_sha256); services(payload.selected_services);
		integer(payload.lifetime_seconds, 60, 3600);
		eligible(state, payload.id, payload.selected_services);
		if (length(filter(state.publication.devices, device => device.token_sha256 == payload.token_sha256)))
			die('enrollment token matches device credential');
		if (length(next.invitations) == 512 || length(filter(next.invitations,
			item => item.id == payload.id || item.token_sha256 == payload.token_sha256)))
			die('enrollment identity or token already issued');
		push(next.invitations, { id: payload.id, token_sha256: payload.token_sha256,
			selected_services: payload.selected_services, issued_at: input.now,
			expires_at: input.now + payload.lifetime_seconds, status: 'issued' });
	} else if (request.operation == 'reserve') {
		fields(payload, [ 'invitation_sha256', 'device_token_sha256' ]);
		hash(payload.invitation_sha256); hash(payload.device_token_sha256);
		// The HTTPS handler hashes the bearer token before calling this pure
		// transition. Submitted HTTP bodies cannot supply this internal field.
		let digest = payload.invitation_sha256, found = null;
		// Inspect all invitations; do not return submitted tokens in diagnostics.
		for (let item in next.invitations) {
			let difference = 0;
			for (let i = 0; i < 64; i++)
				difference |= ord(substr(digest, i, 1)) ^ ord(substr(item.token_sha256, i, 1));
			if (difference == 0) found = item;
		}
		if (found == null || found.status != 'issued' || input.now >= found.expires_at)
			die('invitation unavailable');
		eligible(state, found.id, found.selected_services);
		if (length(filter(next.invitations, item => item.token_sha256 == payload.device_token_sha256)) || length(filter(state.publication.devices,
			device => device.token_sha256 == payload.device_token_sha256)))
			die('enrollment credential already used');
		let desired = desired_state(state);
		push(desired.devices, { id: found.id, token_sha256: payload.device_token_sha256,
			enabled: false, selected_services: found.selected_services });
		proposed = prepare_client_state({ version: 1, expected_generation: state.generation,
			previous: state, desired: desired });
		found.status = 'reserved';
	} else if (request.operation == 'cancel') {
		fields(payload, [ 'id' ]); identity(payload.id);
		let found = filter(next.invitations, item => item.id == payload.id)[0];
		if (found == null || found.status != 'issued') die('invitation unavailable');
		found.status = 'cancelled';
	} else die('unknown enrollment operation');
	next.generation++;
	next.updated_at = input.now;
	return { ledger: validate_client_invitations(next), proposed_state: proposed };
};
