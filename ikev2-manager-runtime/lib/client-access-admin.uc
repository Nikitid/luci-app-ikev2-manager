// Administrative edits derive domains and retain credentials on the server.
'use strict';
import { validate_client_state, prepare_client_state } from './client-access-state.uc';
import { check_client_offer, check_client_choices, client_effective_services, client_choices_within } from './client-access-offer.uc';
import { OWN_PREFIX, OWN_LIMIT, own_service_id, is_own_service, check_own_rule, check_own_entries, own_service } from './client-access-own.uc';

// The count was checked against the person's limit where the list came in.
const OWN_RULE_LIMIT = OWN_LIMIT;

// A device with an offer reaches what follows from it and its choices.
function follow_offer(device) {
 device.choices = client_choices_within(device.offer, device.choices);
 device.selected_services = client_effective_services(device.offer, device.choices);
}

// The service of a device's own addresses stays given to it whatever its
// person is offered: required, and going the ordinary way without the tunnel,
// like the person's own traffic.
function keep_own(device, services) {
 let id = length(device.id) <= 44 ? own_service_id(device.id) : null;
 let has = id != null && length(filter(services, service => service.id == id)) > 0;
 if ('offer' in device) {
  device.offer = filter(device.offer, entry => !is_own_service(entry.id));
  if (has) push(device.offer, { id: id, required: true, closed: 'no' });
  follow_offer(device);
 } else {
  device.selected_services = filter(device.selected_services, service => !is_own_service(service));
  if (has) device.selected_services = sort([ ...device.selected_services, id ]);
 }
}

function fields(value, names) {
 if (type(value) != 'object' || length(keys(value)) != length(names)) die('invalid administrative fields');
 for (let name in names) if (!(name in value)) die('missing administrative field');
}
function identifier(value) {
 if (type(value) != 'string' || !(length(value) <= 48 ? match(value, /^[a-z][a-z0-9-]*$/) : null)) die('invalid administrative identity');
}
function service_id(value) {
 if (type(value) != 'string' || !(length(value) <= 48 ? match(value, /^[a-z0-9][a-z0-9_-]*$/) : null)) die('invalid catalog identity');
}
function desired_state(state) {
 let desired = json(sprintf('%J', state.publication));
 delete desired.allocations;
 desired.devices = filter(desired.devices, device => index(state.retired_ids, device.id) < 0);
 for (let device in desired.devices) delete device.previous_policy;
 return desired;
}

// What the committed state asks for, ready to be changed and proposed again:
// without what the store derives, and without retired devices, which the store
// carries by itself and refuses to be handed back.
export function client_desired_state(state) { return desired_state(state); };

export function client_admin_catalog_ids(state, request) {
 validate_client_state(state);
 fields(request, [ 'version', 'expected_generation', 'operation', 'payload' ]);
 if (request.version !== 1 || request.expected_generation !== state.generation) die('stale administrative request');
 if (request.operation == 'configure-service') {
  // Networks are asked for: a service with hundreds of them, or one already
  // published without, is not changed by their mere existence.
  fields(request.payload, 'networks' in request.payload ? [ 'id', 'client_access', 'transports', 'networks' ] : [ 'id', 'client_access', 'transports' ]);
  service_id(request.payload.id);
  if (is_own_service(request.payload.id)) die('a device keeps its own addresses itself');
  if (type(request.payload.client_access) != 'bool') die('invalid service availability');
  if ('networks' in request.payload && type(request.payload.networks) != 'bool') die('invalid service networks');
  if (!request.payload.client_access) {
   if (!length(filter(state.publication.services, service => service.id == request.payload.id))) die('unknown service');
   return [];
  }
  return [ request.payload.id ];
 }
 if (request.operation == 'assign-device') {
  // The owner and the note describe the device; they are optional here and
  // recorded apart from the state.
  fields(request.payload, 'owner' in request.payload ? [ 'id', 'enabled', 'selected_services', 'owner', 'note' ] : [ 'id', 'enabled', 'selected_services' ]);
  identifier(request.payload.id);
  if (type(request.payload.enabled) != 'bool' || type(request.payload.selected_services) != 'array') die('invalid device assignment');
  for (let id in request.payload.selected_services) service_id(id);
  return [];
 }
 if (request.operation == 'assign-devices') {
  // One person's devices share a decision: the same switch, the same
  // services, the same owner and note.
  // Optional with them: where links are sent and whether services stay
  // blocked without the tunnel.
  // Given as an offer - required and optional services, each with its rule
  // without the tunnel - or, as before, as a plain list of services.
  let offered = 'offer' in request.payload;
  let named = [ 'ids', 'enabled', offered ? 'offer' : 'selected_services', 'owner', 'note' ];
  if (offered) {
   check_client_offer(request.payload.offer, null);
   if (length(filter(request.payload.offer, entry => is_own_service(entry.id)))) die('a device keeps its own addresses itself');
  }
  if ('email' in request.payload) push(named, 'email');
  if ('block_without_tunnel' in request.payload) {
   push(named, 'block_without_tunnel');
   if (type(request.payload.block_without_tunnel) != 'bool') die('invalid device assignment');
  }
  // A device may differ from the others of its person: its own services.
  if ('per_device' in request.payload) {
   if (offered) die('invalid device assignment');
   push(named, 'per_device');
   let own = request.payload.per_device;
   if (type(own) != 'object' || length(keys(own)) != length(request.payload.ids)) die('invalid device assignment');
   for (let id in request.payload.ids) {
    if (type(own[id]) != 'array') die('invalid device assignment');
    for (let service in own[id]) service_id(service);
   }
  }
  // Whether the device sends only its services into the tunnel or everything.
  if ('mode' in request.payload) {
   push(named, 'mode');
   if (index([ 'services', 'full' ], request.payload.mode) < 0) die('invalid device assignment');
  }
  fields(request.payload, named);
  if (type(request.payload.ids) != 'array' || !length(request.payload.ids) || length(request.payload.ids) > 16) die('invalid device list');
  let seen = {};
  for (let id in request.payload.ids) { identifier(id); if (seen[id]) die('invalid device list'); seen[id] = true; }
  if (type(request.payload.enabled) != 'bool' || (!offered && type(request.payload.selected_services) != 'array')) die('invalid device assignment');
  for (let id in request.payload.selected_services ?? []) service_id(id);
  return [];
 }
 // What one device keeps of its own: its sites and networks, and the ports
 // its person was allowed.
 if (request.operation == 'device-own') {
  fields(request.payload, [ 'id', 'domains', 'networks', 'ports' ]);
  identifier(request.payload.id);
  own_service_id(request.payload.id);
  return [];
 }
 // What one device chose of its offer: the optional services it turned on and
 // those it blocks without the tunnel where that is the person's to choose.
 if (request.operation == 'device-choices') {
  fields(request.payload, [ 'id', 'on', 'closed' ]);
  identifier(request.payload.id);
  return [];
 }
 if (request.operation == 'remove-device') {
  fields(request.payload, [ 'id' ]);
  identifier(request.payload.id);
  return [];
 }
 if (request.operation == 'assign-service') {
  fields(request.payload, [ 'id', 'devices' ]);
  service_id(request.payload.id);
  if (is_own_service(request.payload.id)) die('a device keeps its own addresses itself');
  if (type(request.payload.devices) != 'array' || length(request.payload.devices) > 512) die('invalid device list');
  let seen = {};
  for (let id in request.payload.devices) { identifier(id); if (seen[id]) die('invalid device list'); seen[id] = true; }
  return [];
 }
 if (request.operation == 'refresh-catalog') {
  fields(request.payload, []);
  return map(filter(state.publication.services, service => service.client_access && !is_own_service(service.id)), service => service.id);
 }
 die('unknown administrative operation');
};

// Of the services a request reads from the catalog, those whose networks are
// read as well: one asked to carry them, or one that carries them and is not
// asked to stop.
export function client_admin_network_ids(state, request) {
 let ids = client_admin_catalog_ids(state, request);
 if (request.operation == 'configure-service' && 'networks' in request.payload)
  return request.payload.networks ? ids : [];
 return filter(ids, id => length(filter(state.publication.services, service => service.id == id && 'networks' in service)));
};

// A network as the catalog writes it, set at its own base address.
function base_network(text) {
 let parts = split(text, '/'), octets = map(split(parts[0], '.'), octet => +octet);
 let prefix = +parts[1], number = ((octets[0] * 256 + octets[1]) * 256 + octets[2]) * 256 + octets[3], size = 1;
 for (let bit = prefix; bit < 32; bit++) size *= 2;
 number -= number % size;
 let out = [];
 for (let place = 0; place < 4; place++) { unshift(out, number % 256); number = (number - number % 256) / 256; }
 return join('.', out) + '/' + prefix;
}

export function prepare_client_admin(state, request, catalog) {
 let targets = client_admin_catalog_ids(state, request), domains = {}, networks = {};
 if (type(catalog) != 'array' || length(catalog) != length(targets)) die('incomplete catalog snapshot');
 for (let record in catalog) {
  fields(record, 'networks' in record ? [ 'id', 'domains', 'networks' ] : [ 'id', 'domains' ]);
  if (index(targets, record.id) < 0 || record.id in domains || type(record.domains) != 'array' ||
   ('networks' in record && type(record.networks) != 'array') || !(length(record.domains) || length(record.networks ?? [])))
   die('invalid catalog snapshot');
  domains[record.id] = record.domains;
  if ('networks' in record) {
   if (!length(record.networks)) die('the service publishes no networks');
   if (length(record.networks) > 64) die('the service publishes more than 64 networks');
   networks[record.id] = uniq(map(record.networks, base_network));
  }
 }
 let desired = desired_state(state), payload = request.payload;
 if (request.operation == 'configure-service') {
  let was = filter(desired.services, service => service.id == payload.id)[0];
  let updated = { id: payload.id, client_access: payload.client_access,
   domains: payload.client_access ? domains[payload.id] : was.domains, transports: payload.transports }, found = false;
  // Closing a service keeps its networks as they were; opening one takes them
  // only when they were asked for.
  if (payload.client_access ? payload.id in networks : was != null && 'networks' in was)
   updated.networks = payload.client_access ? networks[payload.id] : was.networks;
  for (let index, service in desired.services) {
   if (service.id != payload.id) continue;
   desired.services[index] = updated; found = true;
  }
  if (!found) push(desired.services, updated);
  if (!payload.client_access)
   for (let device in desired.devices) {
    if ('offer' in device) {
     device.offer = filter(device.offer, entry => entry.id != payload.id);
     follow_offer(device);
    } else device.selected_services = filter(device.selected_services, id => id != payload.id);
   }
 } else if (request.operation == 'assign-device') {
  let found = false;
  for (let device in desired.devices) {
   if (device.id != payload.id) continue;
   found = true; device.enabled = payload.enabled;
   // A device with an offer is switched here; what it reaches is its
   // person's offer and its own choices.
   if ('offer' in device) {
    if (sprintf('%J', sort(slice(payload.selected_services))) != sprintf('%J', device.selected_services)) die('the device follows an offer');
   } else {
    device.selected_services = payload.selected_services;
    keep_own(device, desired.services);
   }
  }
  if (!found) die('unknown or retired device');
 } else if (request.operation == 'assign-devices') {
  for (let id in payload.ids) {
   let device = filter(desired.devices, item => item.id == id)[0];
   if (device == null) die('unknown or retired device');
   device.enabled = payload.enabled;
   if ('offer' in payload) {
    device.offer = payload.offer;
    follow_offer(device);
   } else {
    // A plain list leaves the offer behind.
    delete device.offer; delete device.choices;
    device.selected_services = payload.per_device?.[id] ?? payload.selected_services;
   }
   keep_own(device, desired.services);
  }
 } else if (request.operation == 'device-own') {
  let device = filter(desired.devices, item => item.id == payload.id)[0];
  if (device == null) die('unknown or retired device');
  let rule = check_own_rule({ limit: OWN_RULE_LIMIT, ports: payload.ports });
  let entries = check_own_entries({ domains: payload.domains, networks: payload.networks }, rule, desired.server);
  let id = own_service_id(payload.id), service = own_service(payload.id, entries, rule);
  desired.services = filter(desired.services, item => item.id != id);
  if (service != null) push(desired.services, service);
  keep_own(device, desired.services);
 } else if (request.operation == 'device-choices') {
  let device = filter(desired.devices, item => item.id == payload.id)[0];
  if (device == null) die('unknown or retired device');
  if (!('offer' in device)) die('the device has no offer to choose from');
  device.choices = check_client_choices({ on: payload.on, closed: payload.closed }, device.offer);
  device.choices = { on: sort(slice(device.choices.on)), closed: sort(slice(device.choices.closed)) };
  device.selected_services = client_effective_services(device.offer, device.choices);
 } else if (request.operation == 'assign-service') {
  // One service for many devices at once: exactly the devices named have it.
  if (!length(filter(desired.services, service => service.id == payload.id && service.client_access))) die('service is not published');
  for (let device in desired.devices) {
   let wanted = index(payload.devices, device.id) >= 0, has = index(device.selected_services, payload.id) >= 0;
   if ('offer' in device) {
    // On a device with an offer, given this way the service is required and
    // blocked without the tunnel, as every service was before offers.
    let entry = filter(device.offer, item => item.id == payload.id)[0];
    if (wanted && entry == null) push(device.offer, { id: payload.id, required: true, closed: 'yes' });
    else if (wanted && !entry.required) entry.required = true;
    else if (!wanted && entry != null) device.offer = filter(device.offer, item => item.id != payload.id);
    follow_offer(device);
   } else if (wanted && !has) push(device.selected_services, payload.id);
   else if (!wanted && has) device.selected_services = filter(device.selected_services, id => id != payload.id);
  }
 } else if (request.operation == 'remove-device') {
  // Leaving a device out retires it: its identity is spent for good, so a
  // lost invitation or an old key can never bring it back under that name.
  if (!length(filter(desired.devices, device => device.id == payload.id))) die('unknown or retired device');
  desired.devices = filter(desired.devices, device => device.id != payload.id);
  // Its own addresses go with it.
  desired.services = filter(desired.services, service => service.id != OWN_PREFIX + payload.id);
 } else {
  for (let service in desired.services) {
   if (!service.client_access || is_own_service(service.id)) continue;
   service.domains = domains[service.id];
   if (service.id in networks) service.networks = networks[service.id];
  }
 }
 // Validate the complete proposal, including permissions and retained history,
 // before a filesystem writer can commit it.
 prepare_client_state({ version: 1, expected_generation: state.generation, previous: state, desired: desired });
 return { changed: sprintf('%J', desired) != sprintf('%J', desired_state(state)), desired: desired };
};

// Of a snapshot the publisher committed; nothing here is compiled again.
export function inspect_client_admin(state) {
 return { version: 1, generation: state.generation, server: state.publication.server,
  virtual_subnet: state.publication.virtual_subnet, exit: state.publication.exit,
  services: map(state.publication.services, service => ({ id: service.id, client_access: service.client_access,
   domain_count: length(service.domains), network_count: length(service.networks ?? []), transports: service.transports })),
  devices: map(filter(state.publication.devices, device => index(state.retired_ids, device.id) < 0),
   device => {
    let shown = { id: device.id, enabled: device.enabled, selected_services: device.selected_services,
     revision: device.previous_policy.revision };
    if ('offer' in device) { shown.offer = device.offer; shown.choices = device.choices ?? { on: [], closed: [] }; }
    return shown;
   }), retired: length(state.retired_ids) };
};
