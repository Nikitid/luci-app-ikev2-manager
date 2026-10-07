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
function token(value) { return type(value) == 'string' && (length(value) == 64 ? match(value, /^[a-f0-9]+$/) : null) != null; }
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
	if (type(authorization) != 'string' || !(length(authorization) == 71 ? match(authorization, /^Bearer [a-f0-9]+$/) : null)) return reply(401, 'unauthorized');
	let digest = sha256(substr(authorization, 7));
	try {
		let journal = read_client_enrollment(directory), now = time();
		if (now < journal.ledger.updated_at) return reply(503, 'enrollment_unavailable');
		if (claim) {
			if (!token(headers['x-device-token'])) return reply(400, 'invalid_device_token');
			let device_hash = sha256(headers['x-device-token']), invitation = null;
			// A link is one invitation, or up to five places for one person's
			// devices, each keyed by a digest of the link and the place.
			let digests = [ digest ], bearer = substr(authorization, 7);
			for (let place = 1; place <= 5; place++) push(digests, sha256(bearer + ':' + place));
			for (let wanted in digests) {
				for (let item in journal.ledger.invitations) {
					if (!same_hash(wanted, item.token_sha256) || now >= item.expires_at) continue;
					// A lost response can be retried by the same precommitted
					// client credential; a different one cannot reuse the place.
					if (item.status == 'reserved' && journal.pending?.id == item.id) {
						let device = filter(journal.pending.state.publication.devices, entry => entry.id == item.id)[0];
						if (same_hash(device_hash, device.token_sha256)) return pending(item.id);
					}
					if (item.status == 'issued' && invitation == null) invitation = item;
				}
			}
			if (invitation == null) return reply(401, 'unauthorized');
			let reserved = write_client_enrollment(directory, { version: 1, expected_generation: journal.ledger.generation,
				operation: 'reserve', payload: { invitation_sha256: invitation.token_sha256, device_token_sha256: device_hash } }, now, false);
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
		// The device is opened as soon as it is registered, so the bundle stays
		// retrievable by its own key for the life of the invitation: a lost
		// answer can be asked for again.
		if (selected == null || !length(selected.selected_services) || index(state.retired_ids, selected.id) >= 0)
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
