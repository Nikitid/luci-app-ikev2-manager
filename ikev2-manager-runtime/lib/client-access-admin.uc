// Administrative edits derive domains and retain credentials on the server.
'use strict';
import { validate_client_state, prepare_client_state } from './client-access-state.uc';

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
  fields(request.payload, [ 'id', 'client_access', 'transports' ]);
  service_id(request.payload.id);
  if (type(request.payload.client_access) != 'bool') die('invalid service availability');
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
  let named = [ 'ids', 'enabled', 'selected_services', 'owner', 'note' ];
  if ('email' in request.payload) push(named, 'email');
  if ('block_without_tunnel' in request.payload) {
   push(named, 'block_without_tunnel');
   if (type(request.payload.block_without_tunnel) != 'bool') die('invalid device assignment');
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
  if (type(request.payload.enabled) != 'bool' || type(request.payload.selected_services) != 'array') die('invalid device assignment');
  for (let id in request.payload.selected_services) service_id(id);
  return [];
 }
 if (request.operation == 'remove-device') {
  fields(request.payload, [ 'id' ]);
  identifier(request.payload.id);
  return [];
 }
 if (request.operation == 'refresh-catalog') {
  fields(request.payload, []);
  return map(filter(state.publication.services, service => service.client_access), service => service.id);
 }
 die('unknown administrative operation');
};

export function prepare_client_admin(state, request, catalog) {
 let targets = client_admin_catalog_ids(state, request), domains = {};
 if (type(catalog) != 'array' || length(catalog) != length(targets)) die('incomplete catalog snapshot');
 for (let record in catalog) {
  fields(record, [ 'id', 'domains' ]);
  if (index(targets, record.id) < 0 || record.id in domains || type(record.domains) != 'array' || !length(record.domains))
   die('invalid catalog snapshot');
  domains[record.id] = record.domains;
 }
 let desired = desired_state(state), payload = request.payload;
 if (request.operation == 'configure-service') {
  let updated = { id: payload.id, client_access: payload.client_access,
   domains: payload.client_access ? domains[payload.id] : filter(desired.services, service => service.id == payload.id)[0].domains, transports: payload.transports }, found = false;
  for (let index, service in desired.services) {
   if (service.id != payload.id) continue;
   desired.services[index] = updated; found = true;
  }
  if (!found) push(desired.services, updated);
  if (!payload.client_access)
   for (let device in desired.devices)
    device.selected_services = filter(device.selected_services, id => id != payload.id);
 } else if (request.operation == 'assign-device') {
  let found = false;
  for (let device in desired.devices) {
   if (device.id != payload.id) continue;
   found = true; device.enabled = payload.enabled; device.selected_services = payload.selected_services;
  }
  if (!found) die('unknown or retired device');
 } else if (request.operation == 'assign-devices') {
  for (let id in payload.ids) {
   let device = filter(desired.devices, item => item.id == id)[0];
   if (device == null) die('unknown or retired device');
   device.enabled = payload.enabled; device.selected_services = payload.selected_services;
  }
 } else if (request.operation == 'remove-device') {
  // Leaving a device out retires it: its identity is spent for good, so a
  // lost invitation or an old key can never bring it back under that name.
  if (!length(filter(desired.devices, device => device.id == payload.id))) die('unknown or retired device');
  desired.devices = filter(desired.devices, device => device.id != payload.id);
 } else {
  for (let service in desired.services)
   if (service.client_access) service.domains = domains[service.id];
 }
 // Validate the complete proposal, including permissions and retained history,
 // before a filesystem writer can commit it.
 prepare_client_state({ version: 1, expected_generation: state.generation, previous: state, desired: desired });
 return { changed: sprintf('%J', desired) != sprintf('%J', desired_state(state)), desired: desired };
};

export function inspect_client_admin(state) {
 validate_client_state(state);
 return { version: 1, generation: state.generation, server: state.publication.server,
  virtual_subnet: state.publication.virtual_subnet, exit: state.publication.exit,
  services: map(state.publication.services, service => ({ id: service.id, client_access: service.client_access,
   domain_count: length(service.domains), transports: service.transports })),
  devices: map(filter(state.publication.devices, device => index(state.retired_ids, device.id) < 0),
   device => ({ id: device.id, enabled: device.enabled, selected_services: device.selected_services,
    revision: device.previous_policy.revision })), retired: length(state.retired_ids) };
};
