'use strict';
import { chmod, readfile, writefile, unlink, symlink, open, rename, mkdir } from 'fs';
import { sha256 } from 'digest';
import { issue_client_invitation } from '/usr/libexec/ikev2-manager.d/client-access-invitation.uc';
import { read_client_state, publish_client_state } from '/usr/libexec/ikev2-manager.d/client-access-store.uc';
import { read_client_enrollment, write_client_enrollment, finalize_client_enrollment, abandon_client_enrollment } from '/usr/libexec/ikev2-manager.d/client-access-enrollment-store.uc';

let directory = ARGV[0], source = read_client_state('/etc/ikev2-manager/clients');
let desired = json(sprintf('%J', source.publication));
delete desired.allocations;
for (let device in desired.devices) delete device.previous_policy;
publish_client_state(directory, desired, 0, true);
function check(condition, message) { if (!condition) die(message); }
function refused(action, message) {
	let failed = false;
	try { action(); } catch (error) { failed = true; }
	check(failed, message);
}
// Real entropy and durable issuance on installed OpenWrt userland.
let issuer_directory = directory + '/issuer';
check(mkdir(issuer_directory, 0700), 'issuer fixture directory failed');
publish_client_state(issuer_directory, desired, 0, true);
let issuer_request = { version: 1, expected_generation: 0,
 endpoint: 'https://' + source.publication.server.address + ':8443/client/v1/enroll',
 id: 'issued-laptop', selected_services: [ source.publication.services[0].id ], lifetime_seconds: 600 };
let issued = issue_client_invitation(issuer_directory, issuer_request, 1000);
let issued_token = split(issued.invitation, '#')[1];
check(match(issued_token, /^[a-f0-9]{64}$/) != null, 'issuer token format failed');
let stored = read_client_enrollment(issuer_directory);
check(stored.ledger.invitations[0].token_sha256 == sha256(issued_token), 'issuer digest mismatch');
check(index(readfile(issuer_directory + '/invitations.json'), issued_token) < 0, 'issuer persisted raw token');
check(issued.expires_at == 1600 && issued.generation == 1, 'issuer expiry or generation failed');
check(read_client_state(issuer_directory).generation == 1, 'issuer changed traffic admission');
refused(() => issue_client_invitation(issuer_directory, issuer_request, 1001), 'stale issuer accepted');
issuer_request.expected_generation = 1; issuer_request.id = 'issued-second';
let second_issued = issue_client_invitation(issuer_directory, issuer_request, 1001);
check(second_issued.invitation != issued.invitation, 'issuer reused token');
check(unlink(issuer_directory + '/invitations.json'), 'issuer history fixture failed');
issuer_request.expected_generation = 0; issuer_request.id = 'issued-third';
refused(() => issue_client_invitation(issuer_directory, issuer_request, 1002), 'issuer reset lost history');

let token = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
let issue = { version: 1, expected_generation: 0, operation: 'issue', payload: {
	id: 'laptop', token_sha256: sha256(token), selected_services: [ source.publication.services[0].id ], lifetime_seconds: 600 } };
let first = write_client_enrollment(directory, issue, 1000, true);
check(first.ledger.generation == 1 && first.pending == null, 'invitation issuance failed');
check(index(readfile(directory + '/invitations.json'), token) < 0, 'raw invitation was stored');
refused(() => write_client_enrollment(directory, issue, 1000, true), 'enrollment reinitialized');
refused(() => write_client_enrollment(directory, issue, 1000, false), 'stale invitation writer accepted');
let reserve = { version: 1, expected_generation: 1, operation: 'reserve', payload: {
	invitation_sha256: sha256(token), device_token_sha256: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' } };
let lock = open(directory + '/enrollment.lock', 'r');
check(lock.lock('xn'), 'test enrollment lock failed');
refused(() => write_client_enrollment(directory, reserve, 1100, false), 'concurrent enrollment accepted');
lock.close();
let unrelated = directory + '/unrelated';
check(writefile(unrelated, 'keep') && chmod(unrelated, 0600), 'test enrollment target failed');
check(symlink(unrelated, directory + '/invitations.pending'), 'test enrollment symlink failed');
refused(() => write_client_enrollment(directory, reserve, 1100, false), 'enrollment staging symlink accepted');
check(readfile(unrelated) == 'keep', 'enrollment overwrote unrelated file');
unlink(directory + '/invitations.pending');
let reserved = write_client_enrollment(directory, reserve, 1100, false);
check(reserved.ledger.invitations[0].status == 'reserved' && reserved.pending != null, 'reservation was not journaled');
check(!filter(reserved.pending.state.api.devices, device => device.id == 'laptop')[0].enabled, 'reservation admitted device');
check(read_client_state(directory).generation == 1, 'reservation prematurely changed admission');
check(read_client_enrollment(directory).ledger.generation == 2, 'reservation did not survive read');
reserve.expected_generation = 2;
refused(() => write_client_enrollment(directory, reserve, 1101, false), 'interrupted enrollment replayed');
check(chmod(directory + '/invitations.json', 0644), 'test enrollment mode failed');
refused(() => read_client_enrollment(directory), 'unsafe enrollment mode accepted');
check(chmod(directory + '/invitations.json', 0600), 'test enrollment mode restore failed');
let retained = directory + '/invitations.retained';
check(rename(directory + '/invitations.json', retained), 'test enrollment move failed');
check(symlink(retained, directory + '/invitations.json'), 'test enrollment read symlink failed');
refused(() => read_client_enrollment(directory), 'enrollment read symlink accepted');
unlink(directory + '/invitations.json');
check(system('ln ' + retained + ' ' + directory + '/invitations.json') == 0, 'test enrollment hardlink failed');
refused(() => read_client_enrollment(directory), 'enrollment hardlink accepted');
unlink(directory + '/invitations.json');
check(rename(retained, directory + '/invitations.json'), 'test enrollment restore move failed');
let raw = readfile(directory + '/invitations.json');
unlink(directory + '/invitations.json');
refused(() => write_client_enrollment(directory, issue, 1200, true), 'missing enrollment history reinitialized');
refused(() => write_client_enrollment(directory, reserve, 1200, false), 'missing enrollment history accepted');
check(writefile(directory + '/invitations.json', raw) && chmod(directory + '/invitations.json', 0600), 'test enrollment restore failed');
check(chmod(directory, 0755), 'test enrollment directory mode failed');
refused(() => read_client_enrollment(directory), 'unsafe enrollment directory accepted');
check(chmod(directory, 0700), 'test enrollment directory restore failed');
// Publishing a disabled device can complete after the journal has survived
// interruption, without creating admission or resurrecting the invitation.
refused(() => finalize_client_enrollment(directory, 1, 1200), 'stale finalization accepted');
let finalized = finalize_client_enrollment(directory, 2, 1200);
check(finalized.policy.id == 'laptop' && finalized.generation == 3, 'finalization failed');
check(read_client_enrollment(directory).pending == null &&
	read_client_enrollment(directory).ledger.invitations[0].status == 'completed', 'completion was not durable');
check(!filter(read_client_state(directory).api.devices, device => device.id == 'laptop')[0].enabled,
	'finalization enabled device');
refused(() => finalize_client_enrollment(directory, 3, 1201), 'completed enrollment replayed');
reserve.expected_generation = 3;
refused(() => write_client_enrollment(directory, reserve, 1201, false), 'completed invitation reused');

function desired_from(state) {
	let value = json(sprintf('%J', state.publication));
	delete value.allocations;
	for (let device in value.devices) delete device.previous_policy;
	return value;
}
function pending_fixture(name) {
	let path = directory + '/' + name;
	check(mkdir(path, 0700), 'test recovery directory failed');
	publish_client_state(path, desired_from(source), 0, true);
	issue.expected_generation = 0;
	write_client_enrollment(path, issue, 1000, true);
	reserve.expected_generation = 1;
	write_client_enrollment(path, reserve, 1100, false);
	return path;
}
let rebase = pending_fixture('rebase'), state = read_client_state(rebase);
let changed = desired_from(state);
push(changed.services[0].domains, 'central-update.example.com');
publish_client_state(rebase, changed, state.generation, false);
let publication_lock = open(rebase + '/publication.lock', 'r');
check(publication_lock.lock('xn'), 'test publication lock failed');
refused(() => finalize_client_enrollment(rebase, 2, 1200), 'busy publication accepted');
publication_lock.close();
check(read_client_enrollment(rebase).pending != null && read_client_state(rebase).generation == 2,
	'failed publication lost its reservation');
let rebased = finalize_client_enrollment(rebase, 2, 1201);
check(length(filter(rebased.policy.resources, resource => resource.domain == 'central-update.example.com')) == 1,
	'enrollment reverted central domain update');
check(read_client_state(rebase).generation == 3, 'enrollment rebase generation failed');

let recovery = pending_fixture('recovery'), journal = read_client_enrollment(recovery);
// Simulate a crash between the publication rename and journal completion.
publish_client_state(recovery, desired_from(journal.pending.state), 1, false);
state = read_client_state(recovery);
changed = desired_from(state);
push(changed.services[0].domains, 'post-publication.example.com');
publish_client_state(recovery, changed, state.generation, false);
let recovered = finalize_client_enrollment(recovery, 2, 1300);
check(read_client_state(recovery).generation == 3 &&
	length(filter(recovered.policy.resources, resource => resource.domain == 'post-publication.example.com')) == 1,
	'publication recovery overwrote current state');

let conflict = pending_fixture('conflict');
journal = read_client_enrollment(conflict);
changed = desired_from(journal.pending.state);
filter(changed.devices, item => item.id == 'laptop')[0].token_sha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
publish_client_state(conflict, changed, 1, false);
let before_conflict = readfile(conflict + '/state.json');
refused(() => finalize_client_enrollment(conflict, 2, 1200), 'conflicting device credentials overwritten');
check(readfile(conflict + '/state.json') == before_conflict && read_client_enrollment(conflict).pending != null,
	'conflicting publication changed during enrollment');

let enabled = pending_fixture('enabled');
journal = read_client_enrollment(enabled);
changed = desired_from(journal.pending.state);
filter(changed.devices, item => item.id == 'laptop')[0].enabled = true;
publish_client_state(enabled, changed, 1, false);
refused(() => finalize_client_enrollment(enabled, 2, 1200), 'enabled device passed disabled finalization');

let revoked = pending_fixture('revoked');
state = read_client_state(revoked);
changed = desired_from(state);
changed.services[0].client_access = false;
for (let device in changed.devices)
	device.selected_services = filter(device.selected_services, id => id != changed.services[0].id);
publish_client_state(revoked, changed, state.generation, false);
refused(() => finalize_client_enrollment(revoked, 2, 1200), 'revoked service enrolled');
check(read_client_enrollment(revoked).pending != null && read_client_state(revoked).generation == 2,
	'revoked enrollment changed committed state');
refused(() => abandon_client_enrollment(revoked, 1, 1200), 'stale abandonment accepted');
check(abandon_client_enrollment(revoked, 2, 1200).generation == 3 &&
	read_client_enrollment(revoked).pending == null && read_client_state(revoked).generation == 2,
	'unpublished reservation abandonment changed publication');
reserve.expected_generation = 3;
refused(() => write_client_enrollment(revoked, reserve, 1201, false), 'aborted invitation reused');

let aborted_publication = pending_fixture('aborted-publication');
journal = read_client_enrollment(aborted_publication);
publish_client_state(aborted_publication, desired_from(journal.pending.state), 1, false);
let history = read_client_state(aborted_publication).publication.allocations;
abandon_client_enrollment(aborted_publication, 2, 1300);
state = read_client_state(aborted_publication);
check(index(state.retired_ids, 'laptop') >= 0 && !filter(state.api.devices, item => item.id == 'laptop')[0].enabled &&
	sprintf('%J', state.publication.allocations) == sprintf('%J', history), 'abandonment lost device history or authorization');
check(read_client_enrollment(aborted_publication).ledger.invitations[0].status == 'aborted', 'abandonment did not burn invitation');
refused(() => abandon_client_enrollment(conflict, 2, 1300), 'abandonment modified conflicting credentials');
check(readfile(conflict + '/state.json') == before_conflict, 'abandonment overwrote unrelated device');
print('client-enrollment-store: PASS\n');
