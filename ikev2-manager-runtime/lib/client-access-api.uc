// Device-facing policy retrieval. Provisioning and publication own the state;
// an HTTP request can neither select another identity nor mutate configuration.
'use strict';
import { read_client_state } from './client-access-store.uc';
import { sha256 } from 'digest';
import { readfile, lstat, popen, mkdir, chmod, open, rename, unlink } from 'fs';
import { check_client_choices, client_service_entries } from './client-access-offer.uc';
import { record_client_seen, read_client_labels } from './client-access-directory.uc';
import { compile_client_policy } from './client-access.uc';
import { read_client_device_evidence, read_client_device_evidence_for } from './client-access-device-evidence.uc';
import { client_views_generation, read_client_view_by_token } from './client-access-view.uc';
import { client_report_wanted, store_client_report, CLIENT_REPORT_LIMIT } from './client-access-report.uc';

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

// Smallest network containing the configured inbound pool; informational only.
export function client_tunnel_subnet(pool) {
	if (type(pool) != 'string') return '';
	let ends = split(pool, '-'), values = [];
	if (length(ends) != 2) return '';
	for (let end in ends) {
		let octets = split(end, '.'), value = 0;
		if (length(octets) != 4) return '';
		for (let octet in octets) {
			if (!match(octet, /^(0|[1-9][0-9]{0,2})$/) || int(octet) > 255) return '';
			value = value * 256 + int(octet);
		}
		push(values, value);
	}
	if (values[0] > values[1]) return '';
	let prefix = 32;
	while (prefix > 0 && (values[0] >> (32 - prefix)) != (values[1] >> (32 - prefix))) prefix--;
	if (prefix < 8) return '';
	let base = (values[0] >> (32 - prefix)) << (32 - prefix);
	return sprintf('%d.%d.%d.%d/%d', (base >> 24) & 255, (base >> 16) & 255, (base >> 8) & 255, base & 255, prefix);
};

function tunnel_subnet() {
	let pipe = popen('/sbin/uci -q get ikev2-manager.server.pool4', 'r');
	if (!pipe) return '';
	let pool = pipe.read('all');
	pipe.close();
	return client_tunnel_subnet(replace(pool ?? '', /\s+$/, ''));
}

// Whether this router answers names over HTTPS at the resolver address: the
// front runs only where dnsproxy is installed. A device that is told so may
// ask that way, and still falls back to port 53.
function names_over_https() {
	return lstat('/usr/bin/dnsproxy')?.type == 'file';
}

// Whether a device keeps its services blocked while the tunnel is down, for a
// client that knows one rule for all of them: with an offer, blocked as soon
// as any service it has on is.
function blocked_without_tunnel(entries, label) {
	if (entries != null) return length(filter(entries, entry => entry.on && entry.closed)) > 0;
	return !(label?.open ?? false);
}

// The services answer. With an offer it lists every entry: on or off,
// required or not, blocked without the tunnel or not and whose choice that is.
function services_answer(id, revision, selected, available, entries, directory) {
	let label = null, mode = 'services';
	try { label = read_client_labels(directory)[id]; } catch (error) { label = null; }
	if (label?.full === true) mode = 'full';
	let body = { version: 1, id: id, revision: revision, selected: selected, available: available,
		block_without_tunnel: blocked_without_tunnel(entries, label), mode: mode,
		names_https: names_over_https(), tunnel_subnet: tunnel_subnet() };
	if (entries != null) body.entries = entries;
	return { status: 200, body: body };
}

// A device's choice of its offer, checked here and left for the publisher:
// the latest of each device, which a background pass commits. The device
// sees it take effect in its next services answer.
const CHOICES = '/var/run/ikev2-client-choices';
function accept_choice(id, offer, headers, receive) {
	let announced = headers['content-length'];
	if (type(receive) != 'function' || type(announced) != 'string' || !(length(announced) <= 4 ? match(announced, /^[1-9][0-9]*$/) : null))
		return reply(400, 'invalid_choice');
	let wanted = int(announced), text = '';
	while (length(text) < wanted) {
		let part = receive(wanted - length(text));
		if (type(part) != 'string' || !length(part)) return reply(400, 'invalid_choice');
		text += part;
	}
	let choice = null;
	try { choice = check_client_choices(json(text), offer); } catch (error) { return reply(400, 'invalid_choice'); }
	let info = lstat(CHOICES);
	if (info == null && (!mkdir(CHOICES, 0700) || !chmod(CHOICES, 0700))) return reply(503, 'choice_unavailable');
	info = lstat(CHOICES);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) return reply(503, 'choice_unavailable');
	let path = CHOICES + '/' + id + '.json', staged = path + '.new', raw = sprintf('%J\n', { on: sort(slice(choice.on)), closed: sort(slice(choice.closed)) });
	unlink(staged);
	let file = open(staged, 'wxe', 0600);
	if (file == null || file.write(raw) != length(raw) || !file.close() || !rename(staged, path)) { unlink(staged); return reply(503, 'choice_unavailable'); }
	system([ '/sbin/start-stop-daemon', '-b', '-q', '-S', '-x', '/usr/bin/ucode', '--', '/usr/libexec/ikev2-manager.d/client-access-control.uc', 'apply-choices' ]);
	return { status: 202, body: { version: 1, accepted: true } };
}

// What the device shows its user: the services it was assigned and the other
// services published to clients - with an offer, those it was offered - by
// name and size. Domain lists stay in the policy, which carries only what
// this device may reach.
function device_services(publication, id, revision, directory) {
	let assigned = filter(publication.devices, item => item.id == id);
	if (length(assigned) != 1 || type(assigned[0].selected_services) != 'array' || type(publication.services) != 'array')
		die('inconsistent device assignment');
	let own = assigned[0], selected = [], available = [];
	for (let service in publication.services) {
		if (!service.client_access)
			continue;
		let listed = index(own.selected_services, service.id) >= 0 ? selected :
			!('offer' in own) || length(filter(own.offer, entry => entry.id == service.id)) ? available : null;
		if (listed != null) push(listed, { id: service.id, domains: length(service.domains) });
	}
	let by_id = (a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
	return services_answer(id, revision, sort(selected, by_id), sort(available, by_id),
		'offer' in own ? client_service_entries(own.offer, own.choices, publication) : null, directory);
}

// The one request that carries a body: the report the administrator asked
// this device for. Exactly the announced length is read, and no more than the
// limit.
function report_body(headers, receive) {
	let announced = headers['content-length'];
	if (type(receive) != 'function' || type(announced) != 'string' || !(length(announced) <= 5 ? match(announced, /^[1-9][0-9]*$/) : null) ||
		int(announced) > CLIENT_REPORT_LIMIT)
		return null;
	let wanted = int(announced), text = '';
	while (length(text) < wanted) {
		let part = receive(wanted - length(text));
		if (type(part) != 'string' || !length(part)) return null;
		text += part;
	}
	return length(text) == wanted ? text : null;
}

// The clients are released with this package under the same version. Only
// the number leaves the router; a client builds the download address itself.
function release_answer() {
	let installed = replace(readfile('/usr/share/ikev2-manager/version') ?? '', /\s+$/, '');
	if (!match(installed, /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/)) return reply(503, 'release_unavailable');
	return { status: 200, body: { version: 1, release: installed } };
}

export function client_policy_response(env, directory, seen_directory, receive) {
	if (env.HTTPS != 'on')
		return reply(403, 'tls_required');
	let readiness = env.REQUEST_URI == '/client/v1/readiness', services = env.REQUEST_URI == '/client/v1/services';
	let release = env.REQUEST_URI == '/client/v1/release';
	let report = env.REQUEST_URI == '/client/v1/report', sending = report && env.REQUEST_METHOD == 'POST';
	let choosing = env.REQUEST_URI == '/client/v1/choices';
	if (!readiness && !services && !release && !report && !choosing && env.REQUEST_URI != '/client/v1/policy')
		return reply(404, 'not_found');
	if ((choosing && env.REQUEST_METHOD != 'POST') || (!choosing && env.REQUEST_METHOD != 'GET' && !sending))
		return { status: 405, body: { error: 'method_not_allowed' }, allow: choosing ? 'POST' : report ? 'GET, POST' : 'GET' };
	let headers = env.headers ?? {};
	if (headers['transfer-encoding'] != null ||
		(!sending && !choosing && headers['content-length'] != null && headers['content-length'] != '0'))
		return reply(400, 'body_not_allowed');
	let authorization = headers.authorization;
	if (type(authorization) != 'string' || !(length(authorization) == 71 ? match(authorization, /^Bearer [a-f0-9]+$/) : null))
		return reply(401, 'unauthorized');
	let token_hash = sha256(substr(authorization, 7));
	// The usual way: the caller's own view, one small file named by the digest
	// of its key. Without views that stand for the state file now in place -
	// before the first publication of this version, or after the file was
	// replaced by anything but the publisher - the answer comes from the state
	// below, checked in full, as it always did.
	try {
		if (client_views_generation(directory) != null) {
			let device = read_client_view_by_token(directory, token_hash);
			if (device == null) return reply(401, 'unauthorized');
			if (report && (device.enabled || device.idle)) {
				let now = time();
				if (!sending) return { status: 200, body: { version: 1, wanted: client_report_wanted(device.id, now) } };
				if (!client_report_wanted(device.id, now)) return reply(409, 'not_wanted');
				let text = report_body(headers, receive);
				if (text == null || !store_client_report(device.id, text, now)) return reply(400, 'invalid_report');
				return { status: 200, body: { version: 1, stored: true } };
			}
			// A device without a service still learns that a newer program exists.
			if (release && device.idle) return release_answer();
			// A device with an offer sees it and chooses from it, also before it
			// has turned anything on.
			if ((services || choosing) && (device.enabled || device.idle) && type(device.entries) == 'array') {
				if (choosing) return accept_choice(device.id, device.offer, headers, receive);
				return services_answer(device.id, device.revision, device.selected, device.available, device.entries, directory);
			}
			if (choosing) return reply(409, 'no_offer');
			if (!device.enabled) return device.idle ? reply(409, 'no_services') : reply(401, 'unauthorized');
			if (readiness) {
				if (type(headers['x-client-address']) != 'string') return reply(400, 'invalid_client_address');
				return { status: 200, body: read_client_device_evidence_for('/var/run/ikev2-client-access', device, headers['x-client-address'], time()) };
			}
			if (services)
				return services_answer(device.id, device.revision, device.selected, device.available, null, directory);
			if (release) return release_answer();
			let compiled = compile_client_policy(device.policy);
			if (length(sprintf('%J', compiled.policy)) > 1048576)
				return reply(503, 'policy_unavailable');
			if (seen_directory != null)
				try { record_client_seen(seen_directory, device.id, headers, env.REMOTE_ADDR, time()); } catch (error) { };
			return { status: 200, body: compiled.policy };
		}
	} catch (error) {
		return reply(503, readiness ? 'path_unavailable' : services ? 'services_unavailable' : 'policy_unavailable');
	};
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
		let idle = null;
		if (matches == 1 && selected == null) {
			// Known and not switched off, only left without a single service:
			// the device is told so, and lets go of the names it held.
			let known = filter(committed.publication?.devices ?? [], device => same_hash(token_hash, device.token_sha256))[0];
			if (known != null && known.enabled === true && type(known.selected_services) == 'array' && !length(known.selected_services))
				idle = known;
		}
		if (report && matches == 1 && (selected != null || idle != null)) {
			// A device without a service can still say what is wrong with it.
			let id = (selected ?? idle).id, now = time();
			if (!sending) return { status: 200, body: { version: 1, wanted: client_report_wanted(id, now) } };
			// Nothing is stored that was not asked for.
			if (!client_report_wanted(id, now)) return reply(409, 'not_wanted');
			let text = report_body(headers, receive);
			if (text == null || !store_client_report(id, text, now)) return reply(400, 'invalid_report');
			return { status: 200, body: { version: 1, stored: true } };
		}
		if (idle != null && release) return release_answer();
		// With an offer, as above: seen and chosen from with or without a
		// service on.
		let own = matches == 1 ? filter(committed.publication?.devices ?? [], device => same_hash(token_hash, device.token_sha256))[0] : null;
		if ((services || choosing) && (selected != null || idle != null) && own != null && 'offer' in own) {
			if (choosing) return accept_choice(own.id, own.offer, headers, receive);
			return device_services(committed.publication, own.id, selected?.policy?.revision ?? own.previous_policy?.revision ?? 1, directory);
		}
		if (choosing) return reply(409, 'no_offer');
		if (idle != null)
			return reply(409, 'no_services');
		if (matches != 1 || selected == null)
			return reply(401, 'unauthorized');
		if (readiness) {
			if (type(headers['x-client-address']) != 'string') return reply(400, 'invalid_client_address');
			return { status: 200, body: read_client_device_evidence('/var/run/ikev2-client-access', committed,
				selected.id, headers['x-client-address'], time()) };
		}
		if (services)
			return device_services(committed.publication, selected.id, selected.policy.revision, directory);
		if (release) return release_answer();
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
