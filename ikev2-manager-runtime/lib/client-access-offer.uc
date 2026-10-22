// What a person is given and what one of their devices chose of it. The
// services a device may reach - its selected_services, which admission and the
// path follow - are worked out from these two and nothing else.
//
// An offer is a list of entries: a published service, whether it is required
// or the person may turn it on, and whether it is blocked while the tunnel is
// down: always ("yes"), never ("no"), or as the person chooses ("choice").
// Choices name the optional services turned on, and the services the person
// chose to block where that is theirs to choose.
'use strict';

function fail(message) {
	die(`client-access-offer: ${message}`);
}

function exact(value, names) {
	if (type(value) != 'object' || length(keys(value)) != length(names)) fail('invalid fields');
	for (let name in names) if (!(name in value)) fail('missing field');
}

function service_id(value) {
	if (type(value) != 'string' || !(length(value) <= 48 ? match(value, /^[a-z0-9][a-z0-9_-]*$/) : null)) fail('invalid service');
	return value;
}

function id_list(value, limit) {
	if (type(value) != 'array' || length(value) > limit) fail('invalid service list');
	let seen = {};
	for (let id in value) {
		service_id(id);
		if (seen[id]) fail('duplicate service');
		seen[id] = true;
	}
	return seen;
}

// The offer, checked against the services published to clients.
export function check_client_offer(offer, published) {
	if (type(offer) != 'array' || length(offer) > 128) fail('invalid offer');
	let seen = {};
	for (let entry in offer) {
		exact(entry, [ 'id', 'required', 'closed' ]);
		service_id(entry.id);
		if (seen[entry.id]) fail('duplicate offer entry');
		if (type(entry.required) != 'bool' || index([ 'yes', 'no', 'choice' ], entry.closed) < 0) fail('invalid offer entry');
		if (type(published) == 'object' && !published[entry.id]) fail('offered service is not published');
		seen[entry.id] = entry;
	}
	return seen;
};

// Choices hold only what the offer leaves to the person.
export function check_client_choices(choices, offer) {
	let entries = check_client_offer(offer, null);
	exact(choices, [ 'on', 'closed' ]);
	let on = id_list(choices.on, 128), closed = id_list(choices.closed, 128);
	for (let id in keys(on))
		if (entries[id] == null || entries[id].required) fail('a choice turns on what is not optional');
	for (let id in keys(closed))
		if (entries[id]?.closed != 'choice') fail('a choice blocks what is not the person\'s to block');
	return choices;
};

// What a device may reach: every required service and the optional ones it
// turned on, in a stable order.
export function client_effective_services(offer, choices) {
	let on = choices?.on ?? [], result = [];
	for (let entry in offer)
		if (entry.required || index(on, entry.id) >= 0) push(result, entry.id);
	return sort(result);
};

// Choices kept through a new offer: what the offer still leaves to the
// person, nothing more.
export function client_choices_within(offer, choices) {
	let entries = {};
	for (let entry in offer) entries[entry.id] = entry;
	return { on: filter(choices?.on ?? [], id => entries[id] != null && !entries[id].required),
		closed: filter(choices?.closed ?? [], id => entries[id]?.closed == 'choice') };
};

// What the device shows: every service offered, on or off, and whether it is
// blocked without the tunnel - and whether that is the person's to change.
export function client_service_entries(offer, choices, services) {
	let size = {};
	for (let service in services) size[service.id] = { domains: length(service.domains), networks: length(service.networks ?? []) };
	let on = choices?.on ?? [], closed = choices?.closed ?? [];
	return map(sort(slice(offer), (a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0), entry => ({
		id: entry.id, required: entry.required, on: entry.required || index(on, entry.id) >= 0,
		closed: entry.closed == 'yes' || (entry.closed == 'choice' && index(closed, entry.id) >= 0),
		choose_closed: entry.closed == 'choice',
		domains: size[entry.id]?.domains ?? 0, networks: size[entry.id]?.networks ?? 0 }));
};
