// Root-only issuance. The raw invitation is returned after durable journal commit,
// never passed in process arguments or retained in the invitation ledger.
'use strict';
import { open, lstat, mkdir, unlink } from 'fs';
import { sha256 } from 'digest';
import { read_client_state } from './client-access-store.uc';
import { prepare_client_invitation } from './client-access-enrollment.uc';
import { write_client_enrollment } from './client-access-enrollment-store.uc';

export function issue_client_invitation(directory, request, now) {
	let random = open('/dev/urandom', 're');
	if (random == null) die('invitation entropy unavailable');
	let bytes = random.read(32);
	random.close();
	if (type(bytes) != 'string' || length(bytes) != 32) die('invitation entropy unavailable');
	let token = '';
	for (let i = 0; i < 32; i++) token += sprintf('%02x', ord(substr(bytes, i, 1)));
	let prepared = prepare_client_invitation(read_client_state(directory), request, sha256(token));
	let initialize = lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null;
	let journal = write_client_enrollment(directory, prepared, now, initialize);
	return { version: 1, id: request.id, generation: journal.ledger.generation,
		expires_at: now + request.lifetime_seconds, invitation: request.endpoint + '#' + token };
};


function private_directory(path) {
 let info = lstat(path);
 if (info == null && mkdir(path, 0700)) info = lstat(path);
 if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe invitation delivery directory');
}
function private_file(path) {
 let info = lstat(path);
 if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1) die('unsafe invitation delivery file');
 return info;
}
function delivery_directory() {
 private_directory('/var/run/ikev2-client-admin');
 private_directory('/var/run/ikev2-client-admin/invitations');
 return '/var/run/ikev2-client-admin/invitations';
}
function delivery_job(job) {
 if (type(job) != 'string' || length(job) > 64 || !match(job, /^[0-9]+-[0-9]+$/)) die('invalid invitation delivery job');
}
export function stage_client_invitation(request, now, job) {
 delivery_job(job);
 let path = delivery_directory() + '/' + job + '.json';
 let file = open(path, 'wxe', 0600);
 if (file == null) die('invitation delivery already exists');
 try {
  private_file(path);
  let result = issue_client_invitation('/etc/ikev2-manager/clients', request, now);
  let raw = sprintf('%J\n', result);
  if (length(raw) > 4096 || file.write(raw) != length(raw) || !file.close()) die('unable to stage invitation delivery');
  private_file(path);
 } catch (error) {
  file.close(); unlink(path); die('invitation delivery refused');
 }
};
export function consume_client_invitation(job, now) {
 delivery_job(job);
 let directory = delivery_directory(), lockpath = directory + '/delivery.lock';
 if (lstat(lockpath) != null) private_file(lockpath);
 let lock = open(lockpath, 'ae', 0600);
 if (lock == null || !lock.lock('xn')) die('invitation delivery busy');
 try {
  private_file(lockpath);
  let path = directory + '/' + job + '.json', info = private_file(path);
  if (info.size < 1 || info.size > 4096) die('invalid invitation delivery size');
  let file = open(path, 're');
  if (file == null) die('invitation delivery unavailable');
  let raw = file.read(4097); file.close();
  if (type(raw) != 'string' || length(raw) > 4096) die('invalid invitation delivery size');
  let result = json(raw);
  if (type(result) != 'object' || length(keys(result)) != 5 || result.version !== 1 ||
   type(result.id) != 'string' || !match(result.id, /^[a-z][a-z0-9-]{0,47}$/) ||
   type(result.generation) != 'int' || result.generation < 1 ||
   type(result.expires_at) != 'int' || type(result.invitation) != 'string' ||
   !match(result.invitation, /^https:\/\/[a-z0-9.-]+(:[0-9]{1,5})?\/client\/v1\/enroll#[a-f0-9]{64}$/))
   die('invalid invitation delivery');
  // Consume before returning: a lost RPC response cannot reveal it twice.
  if (!unlink(path)) die('unable to consume invitation delivery');
  if (result.expires_at <= now) die('invitation delivery expired');
  lock.close(); return result;
 } catch (error) { lock.close(); die('invitation delivery refused'); }
};
