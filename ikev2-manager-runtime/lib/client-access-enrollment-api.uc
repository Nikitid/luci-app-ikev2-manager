// Dedicated enrollment endpoints. No administrative identity, service list,
// filesystem path, clock or command is accepted from the HTTP caller.
'use strict';
import { sha256 } from 'digest';
import { read_client_enrollment, write_client_enrollment } from './client-access-enrollment-store.uc';
import { read_client_state } from './client-access-store.uc';
import { bootstrap_client_credentials } from './client-access-credentials.uc';

function reply(status, error) { return { status: status, body: { error: error } }; }
function same_hash(a, b) {
	let difference = 0;
	for (let i = 0; i < 64; i++) difference |= ord(substr(a, i, 1)) ^ ord(substr(b, i, 1));
	return difference == 0;
}
function token(value) { return type(value) == 'string' && match(value, /^[a-f0-9]{64}$/) != null; }
function pending(id) { return { status: 202, body: { version: 1, state: 'pending', id: id } }; }

export function client_enrollment_response(env, directory) {
	if (env.HTTPS != 'on') return reply(403, 'tls_required');
	let claim = env.REQUEST_URI == '/client/v1/enroll';
	if (!claim && env.REQUEST_URI != '/client/v1/enrollment') return reply(404, 'not_found');
	let method = claim ? 'POST' : 'GET';
	if (env.REQUEST_METHOD != method) return { status: 405, allow: method, body: { error: 'method_not_allowed' } };
	let headers = env.headers ?? {};
	if (headers['transfer-encoding'] != null || (headers['content-length'] != null && headers['content-length'] != '0'))
		return reply(400, 'body_not_allowed');
	let authorization = headers.authorization;
	if (type(authorization) != 'string' || !match(authorization, /^Bearer [a-f0-9]{64}$/)) return reply(401, 'unauthorized');
	let digest = sha256(substr(authorization, 7));
	try {
		let journal = read_client_enrollment(directory), now = time();
		if (now < journal.ledger.updated_at) return reply(503, 'enrollment_unavailable');
		if (claim) {
			if (!token(headers['x-device-token'])) return reply(400, 'invalid_device_token');
			let device_hash = sha256(headers['x-device-token']), invitation = null;
			for (let item in journal.ledger.invitations) if (same_hash(digest, item.token_sha256)) invitation = item;
			if (invitation == null || now >= invitation.expires_at) return reply(401, 'unauthorized');
			if (invitation.status == 'reserved' && journal.pending?.id == invitation.id) {
				let device = filter(journal.pending.state.publication.devices, item => item.id == invitation.id)[0];
				// A lost response can be retried by the same precommitted client
				// credential. A different credential cannot reuse the invitation.
				if (same_hash(device_hash, device.token_sha256)) return pending(invitation.id);
			}
			if (invitation.status != 'issued') return reply(401, 'unauthorized');
			let reserved = write_client_enrollment(directory, { version: 1, expected_generation: journal.ledger.generation,
				operation: 'reserve', payload: { invitation_sha256: digest, device_token_sha256: device_hash } }, now, false);
			return pending(reserved.pending.id);
		}
		// The polling credential is independent of the invitation. It is held
		// by the client before claiming, so an interrupted request is recoverable.
		if (journal.pending != null) {
			let device = filter(journal.pending.state.publication.devices, item => item.id == journal.pending.id)[0];
			let invitation = filter(journal.ledger.invitations, item => item.id == device.id)[0];
			if (same_hash(digest, device.token_sha256) && now < invitation.expires_at) return pending(device.id);
		}
		let state = read_client_state(directory), selected = null;
		for (let device in state.publication.devices) if (same_hash(digest, device.token_sha256)) selected = device;
		if (selected == null || selected.enabled || !length(selected.selected_services) || index(state.retired_ids, selected.id) >= 0)
			return reply(401, 'unauthorized');
		let invitation = filter(journal.ledger.invitations, item => item.id == selected.id && item.status == 'completed')[0];
		if (invitation == null || now >= invitation.expires_at) return reply(401, 'unauthorized');
		let policy = filter(state.api.devices, device => device.id == selected.id)[0].policy;
		let body = { version: 1, state: 'enrolled', policy: policy,
			credentials: bootstrap_client_credentials(directory, selected.id, digest) };
		if (length(sprintf('%J', body)) > 1048576) return reply(503, 'enrollment_unavailable');
		return { status: 200, body: body };
	} catch (error) { return reply(503, 'enrollment_unavailable'); }
};
