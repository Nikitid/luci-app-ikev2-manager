// Device readiness derives only from successfully installed local admission.
'use strict';
import { sha256 } from 'digest';
import { lstat, open, unlink, rename } from 'fs';
import { compile_client_policy } from './client-access.uc';
import { protected_file, require_current_client_path } from './client-access-path-evidence.uc';

function fields(value, names) {
 if (type(value) != 'object' || length(keys(value)) != length(names)) die('invalid device evidence');
 for (let name in names) if (!(name in value)) die('missing device evidence');
}
function ipv4(value) {
 if (type(value) != 'string') return false;
 let parts = split(value, '.');
 if (length(parts) != 4) return false;
 for (let part in parts) if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || +part > 255) return false;
 return true;
}
function policy_digest(device) { return sha256(sprintf('%J', compile_client_policy(device.policy).policy)); }

export function build_client_device_evidence(state, plan, fingerprint, now) {
 if (plan.generation !== state.generation || plan.exit !== state.publication.exit || plan.mode != 'ready' ||
  type(plan.sessions) != 'array' || length(plan.sessions) > 4096 || type(now) != 'int' || now < 1 ||
  type(fingerprint) != 'string' || !(length(fingerprint) == 64 ? match(fingerprint, /^[a-f0-9]+$/) : null)) die('stale device evidence');
 let devices = [], seen = {};
 for (let session in plan.sessions) {
  let device = filter(state.api.devices, item => item.id == session.identity && item.enabled)[0];
  if (device == null || !ipv4(session.address)) die('unassigned device evidence');
  let key = `${device.id}|${session.address}`;
  if (seen[key]) continue;
  seen[key] = true;
  push(devices, { id: device.id, revision: device.policy.revision, policy_sha256: policy_digest(device), address: session.address });
 }
 return { version: 1, generation: state.generation, exit: plan.exit, updated_at: now, path_nft_sha256: fingerprint, devices: devices };
};

// `device` is what the publication says of the caller: its generation and
// exit, whether it is let in, its revision and the digest of its policy.
function select_evidence(device, evidence, id, address, now) {
 fields(evidence, [ 'version', 'generation', 'exit', 'updated_at', 'path_nft_sha256', 'devices' ]);
 if (evidence.version !== 1 || evidence.generation !== device.generation || evidence.exit !== device.exit ||
  type(now) != 'int' || type(evidence.updated_at) != 'int' || evidence.updated_at > now || now - evidence.updated_at > 3 ||
  type(evidence.path_nft_sha256) != 'string' || !(length(evidence.path_nft_sha256) == 64 ? match(evidence.path_nft_sha256, /^[a-f0-9]+$/) : null) ||
  type(evidence.devices) != 'array' || length(evidence.devices) > 4096 || !ipv4(address)) die('expired device evidence');
 if (device.id !== id || device.enabled !== true || type(device.revision) != 'int' || type(device.policy_sha256) != 'string') die('revoked device evidence');
 let selected = null, owners = {}, keys_seen = {};
 for (let item in evidence.devices) {
  fields(item, [ 'id', 'revision', 'policy_sha256', 'address' ]);
  if (type(item.id) != 'string' || !(length(item.id) <= 48 ? match(item.id, /^[a-z][a-z0-9-]*$/) : null) || !ipv4(item.address) ||
   type(item.revision) != 'int' || item.revision < 1 || type(item.policy_sha256) != 'string' ||
   !(length(item.policy_sha256) == 64 ? match(item.policy_sha256, /^[a-f0-9]+$/) : null)) die('invalid device binding');
  let key = `${item.id}|${item.address}`;
  if (keys_seen[key] || (owners[item.address] != null && owners[item.address] != item.id)) die('ambiguous device binding');
  keys_seen[key] = true; owners[item.address] = item.id;
  if (item.id == id && item.address == address) selected = item;
 }
 if (selected == null || selected.revision !== device.revision || selected.policy_sha256 != device.policy_sha256)
  die('different device policy');
 return { version: 1, state: 'ready', id: id, revision: selected.revision, policy_sha256: selected.policy_sha256,
  address: address, generation: evidence.generation, expires_at: evidence.updated_at + 5 };
}

function described(state, id) {
 let assigned = filter(state.api.devices, device => device.id == id && device.enabled);
 if (length(assigned) != 1) die('revoked device evidence');
 return { generation: state.generation, exit: state.publication.exit, id: id, enabled: true,
  revision: assigned[0].policy.revision, policy_sha256: policy_digest(assigned[0]) };
}

export function select_client_device_evidence(state, evidence, id, address, now) {
 return select_evidence(described(state, id), evidence, id, address, now);
};

// The same answer from the caller's own view, without the state.
export function read_client_device_evidence_for(directory, device, address, now) {
 let info = lstat(directory);
 if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe device evidence directory');
 let evidence = json(protected_file(directory + '/device-ready.json', 1048576));
 let selected = select_evidence(device, evidence, device.id, address, now);
 require_current_client_path(directory, { generation: device.generation, exit: device.exit }, evidence.path_nft_sha256);
 return selected;
};

// The same evidence from the views of the devices that are connected: `lookup`
// gives the view of one device by its identifier.
export function build_client_device_evidence_from(lookup, plan, fingerprint, now) {
 if (plan.mode != 'ready' || type(plan.generation) != 'int' ||
  type(plan.sessions) != 'array' || length(plan.sessions) > 4096 || type(now) != 'int' || now < 1 ||
  type(fingerprint) != 'string' || !(length(fingerprint) == 64 ? match(fingerprint, /^[a-f0-9]+$/) : null)) die('stale device evidence');
 let devices = [], seen = {}, known = {};
 for (let session in plan.sessions) {
  if (!(session.identity in known)) known[session.identity] = lookup(session.identity);
  let device = known[session.identity];
  if (device == null || device.enabled !== true || device.generation !== plan.generation || device.exit !== plan.exit ||
   type(device.policy_sha256) != 'string' || !ipv4(session.address)) die('unassigned device evidence');
  let key = `${device.id}|${session.address}`;
  if (seen[key]) continue;
  seen[key] = true;
  push(devices, { id: device.id, revision: device.revision, policy_sha256: device.policy_sha256, address: session.address });
 }
 return { version: 1, generation: plan.generation, exit: plan.exit, updated_at: now, path_nft_sha256: fingerprint, devices: devices };
};

// `source` is the committed state, or a function giving one device's view.
export function stamp_client_device_evidence(directory, source, plan, fingerprint, now) {
 let info = lstat(directory);
 if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe device evidence directory');
 require_current_client_path(directory, plan, fingerprint);
 let evidence = type(source) == 'function' ? build_client_device_evidence_from(source, plan, fingerprint, now) :
  build_client_device_evidence(source, plan, fingerprint, now);
 let path = directory + '/device-ready.json';
 let previous = lstat(path + '.new');
 if (previous != null) {
  if (previous.type != 'file' || previous.uid != 0 || previous.mode != 0600 || previous.nlink != 1 || !unlink(path + '.new'))
   die('unsafe unfinished device evidence write');
 }
 let file = open(path + '.new', 'wxe', 0600), raw = sprintf('%J\n', evidence);
 if (file == null) die('unable to stage device evidence');
 try {
  if (file.write(raw) != length(raw) || !file.close() || !rename(path + '.new', path)) die('unable to stamp device evidence');
 } catch (error) { file.close(); unlink(path + '.new'); die('unable to stamp device evidence'); }
};

export function read_client_device_evidence(directory, state, id, address, now) {
 let info = lstat(directory);
 if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe device evidence directory');
 let evidence = json(protected_file(directory + '/device-ready.json', 1048576));
 let selected = select_client_device_evidence(state, evidence, id, address, now);
 require_current_client_path(directory, { generation: state.generation, exit: state.publication.exit }, evidence.path_nft_sha256);
 return selected;
};
