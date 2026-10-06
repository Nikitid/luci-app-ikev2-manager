// A single snapshot owns allocation history, device revisions and API output.
'use strict';
import { compile_client_publication } from './client-access-publication.uc';

function fields(value, expected) {
	if (type(value) != 'object' || length(keys(value)) != length(expected))
		die('invalid client state fields');
	for (let key in expected)
		if (!(key in value))
			die('missing client state field');
}

function bounded(snapshot) {
	if (length(sprintf('%J', snapshot)) > 16777215)
		die('client snapshot exceeds size limit');
	return snapshot;
}

export function validate_client_state(snapshot) {
	fields(snapshot, [ 'version', 'generation', 'publication', 'api', 'retired_ids' ]);
	if (snapshot.version !== 1 || type(snapshot.generation) != 'int' ||
		snapshot.generation < 1 || snapshot.generation > 2147483647 ||
		type(snapshot.retired_ids) != 'array')
		die('invalid client snapshot version or generation');
	let compiled = compile_client_publication(snapshot.publication);
	if (sprintf('%J', compiled.api) != sprintf('%J', snapshot.api) ||
		sprintf('%J', compiled.allocations) != sprintf('%J', snapshot.publication.allocations))
		die('inconsistent client snapshot');
	let devices = {}, retired = {};
	for (let index, device in snapshot.publication.devices) {
		devices[device.id] = device;
		if (sprintf('%J', device.previous_policy) != sprintf('%J', snapshot.api.devices[index].policy))
			die('missing committed device history');
	}
	for (let id in snapshot.retired_ids) {
		let device = devices[id];
		if (type(id) != 'string' || retired[id] || device == null ||
			device.enabled || length(device.selected_services))
			die('invalid retired client identity');
		retired[id] = true;
	}
	return bounded(snapshot);
};

export function prepare_client_state(input) {
	fields(input, [ 'version', 'expected_generation', 'previous', 'desired' ]);
	if (input.version !== 1 || type(input.expected_generation) != 'int')
		die('invalid client state request');
	let previous = input.previous;
	if (previous != null)
		validate_client_state(previous);
	let generation = previous?.generation ?? 0;
	if (input.expected_generation != generation || generation == 2147483647)
		die('stale or exhausted client state generation');
	let desired = json(sprintf('%J', input.desired));
	fields(desired, [ 'version', 'server', 'virtual_subnet', 'exit', 'services', 'devices' ]);
	if (type(desired.devices) != 'array')
		die('invalid desired devices');
	if (previous != null && (desired.server?.address != previous.publication.server.address ||
		desired.server?.remote_id != previous.publication.server.remote_id ||
		desired.virtual_subnet != previous.publication.virtual_subnet))
		die('cannot change enrolled server or address pool');
	let old = {}, seen = {}, retired = {};
	for (let device in previous?.publication?.devices ?? [])
		old[device.id] = device;
	for (let id in previous?.retired_ids ?? [])
		retired[id] = true;
	for (let device in desired.devices) {
		fields(device, [ 'id', 'token_sha256', 'enabled', 'selected_services' ]);
		if (type(device.id) != 'string' || retired[device.id] || seen[device.id])
			die('duplicate or retired client identity');
		seen[device.id] = true;
		device.previous_policy = old[device.id]?.previous_policy;
	}
	for (let id, device in old) {
		if (seen[id])
			continue;
		retired[id] = true;
		push(desired.devices, { id: id, token_sha256: device.token_sha256,
			enabled: false, selected_services: [], previous_policy: device.previous_policy });
	}
	desired.allocations = previous?.publication?.allocations ?? [];
	let compiled = compile_client_publication(desired);
	desired.allocations = compiled.allocations;
	for (let index, device in desired.devices)
		device.previous_policy = compiled.api.devices[index].policy;
	return validate_client_state({ version: 1, generation: generation + 1,
		publication: desired, api: compiled.api, retired_ids: sort(keys(retired)) });
};
