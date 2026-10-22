// Compile server-owned service assignments into device-specific API policies.
// The state store commits allocation history and API output in one snapshot.
'use strict';
import { prepare_client_catalog, check_client_policy, validate_client_base } from './client-access.uc';
import { check_client_offer, check_client_choices, client_effective_services } from './client-access-offer.uc';

function fields(value, expected) {
	if (type(value) != 'object' || length(keys(value)) != length(expected))
		die('invalid publication fields');
	for (let key in expected)
		if (!(key in value))
			die('missing publication field');
}

function canonical_resources(resources) {
	// The caller's own order is left as it is.
	return map(sort(slice(resources), (a, b) => a.domain < b.domain ? -1 : a.domain > b.domain ? 1 : 0), resource => ({
		id: resource.id, domain: resource.domain, address: resource.address,
		transports: map(sort(resource.transports, (a, b) => a.protocol < b.protocol ? -1 : a.protocol > b.protocol ? 1 : 0),
			transport => ({ protocol: transport.protocol, ports: sort(transport.ports) }))
	}));
}

export function compile_client_publication(input) {
	fields(input, [ 'version', 'server', 'virtual_subnet', 'exit', 'services', 'allocations', 'devices' ]);
	if (type(input.allocations) != 'array')
		die('invalid publication allocations');
	// A failed proposal must never mutate the caller's allocation registry,
	// the one thing written into here; the rest is only read. The whole
	// proposal used to be copied, which at fifty devices cost a second a time.
	let proposal = { version: input.version, server: input.server, virtual_subnet: input.virtual_subnet, exit: input.exit,
		services: input.services, allocations: slice(input.allocations), devices: input.devices };
	if (proposal.version !== 1 || type(proposal.devices) != 'array' || length(proposal.devices) > 512)
		die('invalid publication version or device count');
	validate_client_base(proposal.server, proposal.virtual_subnet, proposal.exit);
	let catalog = { version: 1, virtual_subnet: proposal.virtual_subnet,
		services: proposal.services, allocations: proposal.allocations, selected_services: [] };
	let assigned = prepare_client_catalog(catalog), allocations = {};
	for (let allocation in assigned.allocations)
		allocations[allocation.domain] = allocation.address;
	let ids = {}, hashes = {}, devices = [], published = {};
	for (let service in proposal.services)
		if (service.client_access) published[service.id] = true;
	for (let device in proposal.devices) {
		// What the person was given and what this device chose of it, where
		// the device has an offer; then its services follow from those alone.
		let named = [ 'id', 'token_sha256', 'enabled', 'selected_services', 'previous_policy' ];
		if ('offer' in device) push(named, 'offer');
		if ('choices' in device) push(named, 'choices');
		fields(device, named);
		if ('choices' in device && !('offer' in device))
			die('choices without an offer');
		if ('offer' in device) {
			check_client_offer(device.offer, published);
			if ('choices' in device) check_client_choices(device.choices, device.offer);
			if (type(device.selected_services) != 'array' ||
				sprintf('%J', sort(slice(device.selected_services))) != sprintf('%J', client_effective_services(device.offer, device.choices)))
				die('services do not follow from the offer');
		}
		if (type(device.id) != 'string' || !(length(device.id) <= 48 ? match(device.id, /^[a-z][a-z0-9-]*$/) : null) || ids[device.id] ||
			type(device.token_sha256) != 'string' || !(length(device.token_sha256) == 64 ? match(device.token_sha256, /^[a-f0-9]+$/) : null) || hashes[device.token_sha256] ||
			type(device.enabled) != 'bool' || type(device.selected_services) != 'array')
			die('invalid or duplicate publication device');
		ids[device.id] = true;
		hashes[device.token_sha256] = true;
		let previous = device.previous_policy;
		if (previous != null) {
			// The policy a device last had was compiled when it was made. It is
			// compiled again only for a device that is let in: a closed or
			// removed one admits nobody and is never served, and every removed
			// device stays in the state for good - compiling all of them made
			// each save slower with each device ever removed.
			if (device.enabled) check_client_policy(previous);
			if (type(previous) != 'object' || type(previous.server) != 'object' || type(previous.resources) != 'array') die('invalid retained policy');
			if (previous.id != device.id || previous.virtual_subnet != proposal.virtual_subnet ||
				previous.server.address != proposal.server?.address || previous.server.remote_id != proposal.server?.remote_id)
				die('publication changes enrolled identity or address pool');
			for (let resource in previous.resources)
				if (allocations[resource.domain] != resource.address)
					die('publication lost or changed an existing allocation');
		}
		let selected = { resources: assigned.select(device.selected_services), networks: assigned.networks(device.selected_services) };
		let reaches = length(selected.resources) + length(selected.networks) > 0;
		let enabled = device.enabled && reaches;
		let policy;
		if (!reaches) {
			if (previous == null)
				die('initial device policy requires assigned resources');
			// No empty policy is accepted by clients. Revoke retrieval and retain
			// the last intent so an offline client keeps its existing local guard.
			policy = previous;
		} else {
			// Networks make it version 2; without them it stays what every
			// client so far accepts.
			policy = { version: length(selected.networks) ? 2 : 1, id: device.id, revision: previous?.revision ?? 1,
				server: proposal.server, virtual_subnet: proposal.virtual_subnet,
				exit: proposal.exit, resources: selected.resources };
			if (length(selected.networks))
				policy.networks = selected.networks;
			check_client_policy(policy);
			// Written the same, they are the same; only when they are not is
			// the order they were written in set aside.
			if (previous != null && (previous.exit != policy.exit || previous.version != policy.version ||
				sprintf('%J', previous.networks ?? []) != sprintf('%J', policy.networks ?? []) ||
				(sprintf('%J', previous.resources) != sprintf('%J', policy.resources) &&
				sprintf('%J', canonical_resources(previous.resources)) != sprintf('%J', canonical_resources(policy.resources))))) {
				if (previous.revision == 2147483647)
					die('publication revision exhausted');
				policy.revision++;
			}
		}
		push(devices, { id: device.id, token_sha256: device.token_sha256, enabled: enabled, policy: policy });
	}
	let api = { version: 1, devices: devices };
	if (length(sprintf('%J', api)) > 8388608)
		die('publication exceeds API state limit');
	return { allocations: assigned.allocations, api: api };
};
