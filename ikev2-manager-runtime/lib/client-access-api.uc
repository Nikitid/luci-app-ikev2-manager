// Device-facing policy retrieval. Provisioning and publication own the state;
// an HTTP request can neither select another identity nor mutate configuration.
'use strict';
import { read_client_state } from './client-access-store.uc';
import { sha256 } from 'digest';
import { compile_client_policy } from './client-access.uc';
import { read_client_device_evidence } from './client-access-device-evidence.uc';

function reply(status, error) {
	return { status: status, body: { error: error } };
}

function same_hash(a, b) {
	let difference = 0;
	for (let i = 0; i < 64; i++)
		difference |= ord(substr(a, i, 1)) ^ ord(substr(b, i, 1));
	return difference == 0;
}

function valid_fields(value, expected) {
	return type(value) == 'object' && length(keys(value)) == length(expected) &&
		length(filter(expected, key => value[key] == null)) == 0;
}

export function client_policy_response(env, directory) {
	if (env.HTTPS != 'on')
		return reply(403, 'tls_required');
	let readiness = env.REQUEST_URI == '/client/v1/readiness';
	if (!readiness && env.REQUEST_URI != '/client/v1/policy')
		return reply(404, 'not_found');
	if (env.REQUEST_METHOD != 'GET')
		return reply(405, 'method_not_allowed');
	let headers = env.headers ?? {};
	if (headers['transfer-encoding'] != null ||
		(headers['content-length'] != null && headers['content-length'] != '0'))
		return reply(400, 'body_not_allowed');
	let authorization = headers.authorization;
	if (type(authorization) != 'string' || !match(authorization, /^Bearer [a-f0-9]{64}$/))
		return reply(401, 'unauthorized');
	let token_hash = sha256(substr(authorization, 7));
	try {
		let committed = read_client_state(directory), state = committed.api;
		if (!valid_fields(state, [ 'version', 'devices' ]) || state.version !== 1 ||
			type(state.devices) != 'array' || length(state.devices) > 512)
			return reply(503, 'policy_unavailable');
		let ids = {}, hashes = {}, selected = null, matches = 0;
		for (let device in state.devices) {
			if (!valid_fields(device, [ 'id', 'token_sha256', 'enabled', 'policy' ]) ||
				type(device.id) != 'string' || !match(device.id, /^[a-z][a-z0-9-]{0,47}$/) ||
				type(device.token_sha256) != 'string' || !match(device.token_sha256, /^[a-f0-9]{64}$/) ||
				type(device.enabled) != 'bool' || ids[device.id] || hashes[device.token_sha256])
				return reply(503, 'policy_unavailable');
			ids[device.id] = true;
			hashes[device.token_sha256] = true;
			if (same_hash(token_hash, device.token_sha256)) {
				matches++;
				if (device.enabled)
					selected = device;
			}
		}
		if (matches != 1 || selected == null)
			return reply(401, 'unauthorized');
		if (readiness) {
			if (type(headers['x-client-address']) != 'string') return reply(400, 'invalid_client_address');
			return { status: 200, body: read_client_device_evidence('/var/run/ikev2-client-access', committed,
				selected.id, headers['x-client-address'], time()) };
		}
		// Validation rejects unknown fields before returning any policy content.
		let compiled = compile_client_policy(selected.policy);
		if (length(sprintf('%J', compiled.policy)) > 1048576)
			return reply(503, 'policy_unavailable');
		return { status: 200, body: compiled.policy };
	} catch (error) {
		return reply(503, readiness ? 'path_unavailable' : 'policy_unavailable');
	};
};
