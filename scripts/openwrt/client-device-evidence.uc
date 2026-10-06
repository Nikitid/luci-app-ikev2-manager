// Real ucode/digest behavior; this does not fabricate kernel or proxy readiness.
'use strict';
import { readfile } from 'fs';
import { reconcile_client_authorization } from '/usr/libexec/ikev2-manager.d/client-access-authorization.uc';
import { build_client_device_evidence, select_client_device_evidence } from '/usr/libexec/ikev2-manager.d/client-access-device-evidence.uc';
import { client_policy_response } from '/usr/libexec/ikev2-manager.d/client-access-api.uc';
function require(value, name) { if (!value) die('device readiness: ' + name); }
function copy(value) { return json(sprintf('%J', value)); }
function refuses(fn, name) {
 let refused = false;
 try { fn(); } catch (error) { refused = true; }
 require(refused, name + ' was accepted');
}
let policy = json(readfile('/src/desktop-clients/fixtures/policies.json'))[0].policy;
policy.id = 'alice';
let state = { generation: 7, publication: { exit: '1' }, api: { version: 1,
 devices: [ { id: 'alice', token_sha256: sprintf('%064d', 0), enabled: true, policy: policy } ] } };
let snapshot = { errors: [], data: [ { 'ikev2-in': { version: '2', state: 'ESTABLISHED',
 'remote-eap-id': 'alice', 'remote-vips': [ '10.25.0.10' ], 'child-sas': { net: {
 name: 'net', state: 'INSTALLED', mode: 'TUNNEL', protocol: 'ESP', 'if-id-in': '0000002b', 'if-id-out': '0000002b',
 reqid: '12', 'spi-in': '01234567', 'spi-out': '89abcdef', 'remote-ts': [ '10.25.0.10/32' ] } } } } ] };
function compile(snapshot, api) {
 return reconcile_client_authorization({ version: 1, pool: { first: '10.25.0.10', last: '10.25.0.20' }, api: api,
  snapshot: snapshot, lease_seconds: 15 });
}
let authorized = compile(snapshot, state.api);
require(length(authorized.sessions) == 1, 'authenticated admission');
let plan = { generation: 7, exit: '1', mode: 'ready', sessions: authorized.sessions };
let fingerprint = sprintf('%064d', 0), now = 1000;
let evidence = build_client_device_evidence(state, plan, fingerprint, now);
let selected = select_client_device_evidence(state, evidence, 'alice', '10.25.0.10', now + 2);
require(selected.state == 'ready' && selected.id == 'alice' && selected.revision == 1 && selected.expires_at == 1005 &&
 length(keys(selected)) == 8 && match(selected.policy_sha256, /^[a-f0-9]{64}$/), 'bounded own receipt');
refuses(() => select_client_device_evidence(state, evidence, 'alice', '10.25.0.10', now + 4), 'expired snapshot');
refuses(() => select_client_device_evidence(state, evidence, 'alice', '10.25.0.10', now - 1), 'clock rollback');
refuses(() => select_client_device_evidence(state, evidence, 'bob', '10.25.0.10', now), 'other identity');
refuses(() => select_client_device_evidence(state, evidence, 'alice', '10.25.0.11', now), 'different SA address');
let changed = copy(state); changed.generation++;
refuses(() => select_client_device_evidence(changed, evidence, 'alice', '10.25.0.10', now), 'new publication');
changed = copy(state); changed.api.devices[0].enabled = false;
refuses(() => select_client_device_evidence(changed, evidence, 'alice', '10.25.0.10', now), 'revocation');
changed = copy(state); changed.api.devices[0].policy.revision++;
refuses(() => select_client_device_evidence(changed, evidence, 'alice', '10.25.0.10', now), 'different revision');
changed = copy(state); changed.api.devices[0].policy.resources[0].domain = 'changed.example.com';
refuses(() => select_client_device_evidence(changed, evidence, 'alice', '10.25.0.10', now), 'same revision changed content');
let duplicate = copy(evidence); push(duplicate.devices, copy(duplicate.devices[0]));
refuses(() => select_client_device_evidence(state, duplicate, 'alice', '10.25.0.10', now), 'duplicate binding');
let malformed = copy(evidence); malformed.extra = true;
refuses(() => select_client_device_evidence(state, malformed, 'alice', '10.25.0.10', now), 'unexpected evidence field');
let incomplete = copy(snapshot); incomplete.data[0]['ikev2-in']['child-sas'].net['if-id-in'] = '0000002a';
let denied = copy(plan); denied.sessions = compile(incomplete, state.api).sessions;
require(length(denied.sessions) == 0, 'foreign XFRM excluded');
let closed = build_client_device_evidence(state, denied, fingerprint, now);
refuses(() => select_client_device_evidence(state, closed, 'alice', '10.25.0.10', now), 'no authenticated SA');
let rekey = copy(snapshot), replacement = copy(snapshot.data[0]);
replacement['ikev2-in']['child-sas'].net.reqid = '13'; replacement['ikev2-in']['child-sas'].net['spi-in'] = '01234568';
replacement['ikev2-in']['child-sas'].net['spi-out'] = '89abcdee'; push(rekey.data, replacement);
let renewed = copy(plan); renewed.sessions = compile(rekey, state.api).sessions;
require(length(renewed.sessions) == 2 && length(build_client_device_evidence(state, renewed, fingerprint, now).devices) == 1, 'rekey deduplication');
print('device readiness: admission, policy binding, expiration, revocation, identity, address, schema and rekey passed\n');
if (length(ARGV) == 1) {
 let env = { HTTPS: 'on', REQUEST_METHOD: 'GET', REQUEST_URI: '/client/v1/readiness', headers: {} };
 require(client_policy_response(env, ARGV[0]).status == 401, 'unauthenticated readiness');
 env.headers.authorization = 'Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 require(client_policy_response(env, ARGV[0]).status == 400, 'missing address');
 env.headers['x-client-address'] = '10.25.0.10';
 let response = client_policy_response(env, ARGV[0]);
 require(response.status == 503 && response.body.error == 'path_unavailable', 'missing installed proof');
 env.headers.authorization = 'Bearer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
 require(client_policy_response(env, ARGV[0]).status == 401, 'disabled token');
 env.headers.authorization = 'Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 env.REQUEST_URI = '/client/v1/policy';
 require(client_policy_response(env, ARGV[0]).status == 200, 'existing policy retrieval');
 print('device readiness API: authentication, address, absent path, revocation and policy retrieval passed\n');
}
