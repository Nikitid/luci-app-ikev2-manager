// Device-facing policy retrieval. Provisioning and publication own the state;
// an HTTP request can neither select another identity nor mutate configuration.
'use strict';
import { read_client_state } from './client-access-store.uc';
import { sha256 } from 'digest';
import { readfile } from 'fs';
import { record_client_seen, read_client_labels } from './client-access-directory.uc';
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

// What the device shows its user: the services it was assigned and the other
// services published to clients, by name and size. Domain lists stay in the
// policy, which carries only what this device may reach.
function device_services(publication, device, directory) {
	let assigned = filter(publication.devices, item => item.id == device.id);
	if (length(assigned) != 1 || type(assigned[0].selected_services) != 'array' || type(publication.services) != 'array')
		die('inconsistent device assignment');
	let selected = [], available = [];
	for (let service in publication.services) {
		if (!service.client_access)
			continue;
		push(index(assigned[0].selected_services, service.id) >= 0 ? selected : available,
			{ id: service.id, domains: length(service.domains) });
	}
	let by_id = (a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
	// Whether the device keeps its services blocked while the tunnel is down.
	// That is the rule; the administrator may lift it for a person.
	let block = true;
	try { block = !(read_client_labels(directory)[device.id]?.open ?? false); } catch (error) { }
	return { version: 1, id: device.id, revision: device.policy.revision,
		selected: sort(selected, by_id), available: sort(available, by_id), block_without_tunnel: block };
}

export function client_policy_response(env, directory, seen_directory) {
	if (env.HTTPS != 'on')
		return reply(403, 'tls_required');
	let readiness = env.REQUEST_URI == '/client/v1/readiness', services = env.REQUEST_URI == '/client/v1/services';
	let release = env.REQUEST_URI == '/client/v1/release';
	if (!readiness && !services && !release && env.REQUEST_URI != '/client/v1/policy')
		return reply(404, 'not_found');
	if (env.REQUEST_METHOD != 'GET')
		return reply(405, 'method_not_allowed');
	let headers = env.headers ?? {};
	if (headers['transfer-encoding'] != null ||
		(headers['content-length'] != null && headers['content-length'] != '0'))
		return reply(400, 'body_not_allowed');
	let authorization = headers.authorization;
	if (type(authorization) != 'string' || !(length(authorization) == 71 ? match(authorization, /^Bearer [a-f0-9]+$/) : null))
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
				type(device.id) != 'string' || !(length(device.id) <= 48 ? match(device.id, /^[a-z][a-z0-9-]*$/) : null) ||
				type(device.token_sha256) != 'string' || !(length(device.token_sha256) == 64 ? match(device.token_sha256, /^[a-f0-9]+$/) : null) ||
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
		if (services)
			return { status: 200, body: device_services(committed.publication, selected, directory) };
		if (release) {
			// The clients are released with this package under the same
			// version. Only the number leaves the router; a client builds
			// the download address itself.
			let installed = replace(readfile('/usr/share/ikev2-manager/version') ?? '', /\s+$/, '');
			if (!match(installed, /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/)) return reply(503, 'release_unavailable');
			return { status: 200, body: { version: 1, release: installed } };
		}
		// Validation rejects unknown fields before returning any policy content.
		let compiled = compile_client_policy(selected.policy);
		if (length(sprintf('%J', compiled.policy)) > 1048576)
			return reply(503, 'policy_unavailable');
		// What the device says about itself, for the administrator's list.
		// Never a reason to refuse the policy.
		if (seen_directory != null)
			try { record_client_seen(seen_directory, selected.id, headers, env.REMOTE_ADDR, time()); } catch (error) { };
		return { status: 200, body: compiled.policy };
	} catch (error) {
		return reply(503, readiness ? 'path_unavailable' : services ? 'services_unavailable' : 'policy_unavailable');
	};
};
