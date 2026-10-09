// Local administrative entry point. The device HTTP API is read-only.
'use strict';
import { stdin, lstat, mkdir, chmod, popen, open } from 'fs';
import { publish_client_state, read_client_state, read_committed_client_state } from './client-access-store.uc';

import { read_client_enrollment, write_client_enrollment } from './client-access-enrollment-store.uc';
import { client_admin_catalog_ids, prepare_client_admin, inspect_client_admin } from './client-access-admin.uc';
import { read_client_labels, write_client_label, client_device_sessions, describe_client_device, forget_client_device, read_profile_owners, write_profile_owners, set_account_rights, read_person_limits, write_person_limit } from './client-access-directory.uc';
import { cleanup_client_credentials } from './client-access-credentials.uc';
import { record_client_event, read_client_events } from './client-access-journal.uc';
import { client_views_generation, write_client_views } from './client-access-view.uc';
import { request_client_report, read_client_report, describe_client_report, forget_client_report } from './client-access-report.uc';
import { read_client_link, forget_client_link } from './client-access-link.uc';

let seen_directory = '/var/run/ikev2-client-seen';

let directory = '/etc/ikev2-manager/clients';
try {
	if (ARGV[0] == 'status' && length(ARGV) == 1) {
		let state = read_committed_client_state(directory);
		print(`generation=${state.generation}\n`);
		print(`devices=${length(state.api.devices)}\n`);
		print(`enabled=${length(filter(state.api.devices, device => device.enabled))}\n`);
		print(`retired=${length(state.retired_ids)}\n`);
		print(`allocations=${length(state.publication.allocations)}\n`);
	} else if (ARGV[0] == 'inspect' && length(ARGV) == 1) {
  let state_now = read_committed_client_state(directory);
  let inspected = inspect_client_admin(state_now);
  let labels = read_client_labels(directory), sessions = {}, now = time();
  let daemon = popen('/usr/sbin/swanmon list-sas 2>/dev/null', 'r');
  let listed = daemon?.read(16777217), listing = daemon?.close();
  if (listing == 0 && type(listed) == 'string' && length(listed) <= 16777216)
   try { sessions = client_device_sessions(json(listed)); } catch (error) { sessions = {}; }
  for (let device in inspected.devices) describe_client_report(describe_client_device(device, labels, seen_directory, sessions, now), now);
  // Places a link still holds open: the administrator sees who has not
  // registered yet and until when the link works.
  let ledger = lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null ? null : read_client_enrollment(directory).ledger;
  inspected.enrollment_generation = ledger == null ? 0 : ledger.generation;
  inspected.waiting = [];
  for (let item in (ledger?.invitations ?? []))
   if (item.status == 'issued' && item.expires_at > now)
    push(inspected.waiting, { id: item.id, selected_services: item.selected_services, expires_seconds: item.expires_at - now,
     owner: labels[item.id]?.owner ?? '', note: labels[item.id]?.note ?? '', mode: labels[item.id]?.full === true ? 'full' : 'services' });
  let port_reader = popen('/sbin/uci -q get ikev2-manager.client_access.port', 'r');
  let port_raw = port_reader?.read(32), port_status = port_reader?.close();
  let api_port = port_status == 0 ? replace(port_raw ?? '', /\n$/, '') : '8443';
  // Identifiers that can never be given again: removed devices and every
  // place a link ever held. The page refuses them before asking.
  let used = {};
  for (let id in state_now.retired_ids) used[id] = true;
  for (let item in (ledger?.invitations ?? [])) used[item.id] = true;
  inspected.used_ids = keys(used);
  inspected.events = read_client_events(40);
  inspected.profile_owners = read_profile_owners(directory);
  inspected.person_limits = read_person_limits(directory);
  let approve_reader = popen('/sbin/uci -q get ikev2-manager.client_access.approve', 'r');
  inspected.approve = replace(approve_reader?.read(8) ?? '', /\n$/, '') == '1';
  approve_reader?.close();
  inspected.api_endpoint = match(api_port, /^[1-9][0-9]{3,4}$/) && int(api_port) >= 1024 && int(api_port) <= 65535 ?
   'https://' + inspected.server.address + ':' + api_port + '/client/v1/enroll' : null;
  print(sprintf('%J\n', inspected));
 } else if (ARGV[0] == 'views' && length(ARGV) == 1) {
  // Asked for by the controller: the views are made again when they are
  // missing or older than the state - after an upgrade, a restored backup or
  // an interrupted publication.
  // Views that stand for the state file in place are left alone, and the
  // state is not even opened. Otherwise the state is checked in full before
  // new views are made from it; a state that does not hold together fails
  // here, and the controller closes.
  let standing = client_views_generation(directory);
  if (standing == null) {
   let state = read_client_state(directory);
   write_client_views(directory, state);
   standing = state.generation;
  }
  print(`generation=${standing}\n`);
 } else if (ARGV[0] == 'link' && length(ARGV) == 2) {
  // The link that still holds this place open, for the administrator to
  // look at again. Only while the ledger says the place waits.
  let id = ARGV[1], now = time();
  if (type(id) != 'string' || !(length(id) <= 48 ? match(id, /^[a-z][a-z0-9-]*$/) : null)) die('invalid place');
  let ledger = lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null ? null : read_client_enrollment(directory).ledger;
  let waits = length(filter(ledger?.invitations ?? [], item => item.id == id && item.status == 'issued' && item.expires_at > now)) == 1;
  let link = waits ? read_client_link(id, now) : null;
  if (link == null) { if (!waits) forget_client_link(id); die('link is not kept'); }
  print(sprintf('%J\n', { version: 1, invitation: link.invitation, expires_seconds: link.expires_at - now, places: length(link.places) }));
 } else if ((ARGV[0] == 'report-request' || ARGV[0] == 'report') && length(ARGV) == 2) {
  // The device is asked the next time it calls, and answers by itself.
  let state = read_committed_client_state(directory), id = ARGV[1];
  if (!length(filter(state.publication.devices, device => device.id == id)) || index(state.retired_ids, id) >= 0) die('unknown device');
  if (ARGV[0] == 'report-request') {
   request_client_report(id, time());
   record_client_event('report-requested', id);
   print('requested=1\n');
  } else print(read_client_report(id) ?? '{}\n');
 } else if ((ARGV[0] == 'update' || ARGV[0] == 'refresh') && length(ARGV) == 1) {
  let state = read_client_state(directory), request;
  if (ARGV[0] == 'refresh') request = { version: 1, expected_generation: state.generation,
   operation: 'refresh-catalog', payload: {} };
  else {
   let raw = stdin.read(1048577);
   if (type(raw) != 'string' || length(raw) > 1048576) die('oversized administrative request');
   request = json(raw);
  }
  // A place a link still holds open is closed in the invitation ledger; the
  // published state has no device for it yet. The label goes with it.
  let closed = false;
  if (type(request) == 'object' && request.operation == 'close-place') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 1 || type(payload.id) != 'string' ||
    !(length(payload.id) <= 48 ? match(payload.id, /^[a-z][a-z0-9-]*$/) : null)) die('invalid place');
   let ledger = read_client_enrollment(directory).ledger;
   write_client_enrollment(directory, { version: 1, expected_generation: ledger.generation, operation: 'cancel', payload: { id: payload.id } }, time(), false);
   try { write_client_label(directory, payload.id, '', '', { email: '', open: false }); } catch (error) { }
   forget_client_link(payload.id);
   record_client_event('place-closed', payload.id);
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  // A whole link withdrawn at once: every place it still holds open.
  if (type(request) == 'object' && request.operation == 'close-places') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 1 || type(payload.ids) != 'array' ||
    !length(payload.ids) || length(payload.ids) > 5) die('invalid places');
   for (let id in payload.ids)
    if (type(id) != 'string' || !(length(id) <= 48 ? match(id, /^[a-z][a-z0-9-]*$/) : null)) die('invalid place');
   for (let id in payload.ids) {
    let ledger = read_client_enrollment(directory).ledger;
    write_client_enrollment(directory, { version: 1, expected_generation: ledger.generation, operation: 'cancel', payload: { id: id } }, time(), false);
    try { write_client_label(directory, id, '', '', { email: '', open: false }); } catch (error) { }
   }
   for (let id in payload.ids) forget_client_link(id);
   record_client_event('link-withdrawn', join(',', payload.ids));
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  // One device's mode: its services alone, or everything into the tunnel.
  if (type(request) == 'object' && request.operation == 'set-device-mode') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 2 ||
    index([ 'services', 'full' ], payload.mode) < 0 || !length(filter(state.publication.devices, device => device.id == payload.id)) ||
    index(state.retired_ids, payload.id) >= 0) die('invalid device mode');
   let label = read_client_labels(directory)[payload.id], full = payload.mode == 'full';
   if ((label?.full ?? false) != full) {
    write_client_label(directory, payload.id, label?.owner ?? '', label?.note ?? '', { full: full });
    // Rights only while the device is open.
    set_account_rights(payload.id, full && filter(state.publication.devices, device => device.id == payload.id)[0].enabled);
    record_client_event(full ? 'mode-full' : 'mode-services', payload.id);
   }
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  // The name the administrator gives a device, or none to show the computer's own.
  if (type(request) == 'object' && request.operation == 'rename-device') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 2 || type(payload.name) != 'string' ||
    !length(filter(state.publication.devices, device => device.id == payload.id)) || index(state.retired_ids, payload.id) >= 0) die('invalid device name');
   let label = read_client_labels(directory)[payload.id];
   write_client_label(directory, payload.id, label?.owner ?? '', label?.note ?? '', { title: payload.name });
   record_client_event('device-renamed', payload.id);
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  // Which ordinary VPN profiles belong to a person: a description, kept
  // beside the labels; the published state knows nothing of it.
  if (type(request) == 'object' && request.operation == 'assign-profiles') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 2) die('invalid profile owner');
   write_profile_owners(directory, payload.owner, payload.profiles);
   record_client_event('profiles-set', payload.owner + ' ' + join(',', payload.profiles));
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  // How many Waypoint devices a person may have.
  if (type(request) == 'object' && request.operation == 'set-person-limit') {
   let payload = request.payload;
   if (request.version !== 1 || type(payload) != 'object' || length(keys(payload)) != 2) die('invalid device limit');
   write_person_limit(directory, payload.owner, payload.limit);
   record_client_event('devices-limit', payload.owner + ' ' + payload.limit);
   print(`generation=${state.generation}\nchanged=1\n`);
   closed = true;
  }
  if (!closed) {
  let ids = client_admin_catalog_ids(state, request), catalog = [];
  for (let id in ids) {
   // IDs have already passed the strict identifier grammar. No submitted
   // path, URL, credential or command can reach the child process.
   let child = popen('/usr/libexec/ikev2-domains-community client-service-domains ' + id, 'r');
   if (!child) die('catalog unavailable');
   let body = child.read(1048577), status = child.close();
   if (status != 0 || type(body) != 'string' || length(body) > 1048576) die('catalog unavailable');
   push(catalog, { id: id, domains: filter(split(body, '\n'), name => length(name)) });
  }
  let prepared = prepare_client_admin(state, request, catalog);
  let generation = prepared.changed ? publish_client_state(directory, prepared.desired, state.generation, false) : state.generation;
  if (request.operation == 'assign-device' && 'owner' in request.payload)
   write_client_label(directory, request.payload.id, request.payload.owner, request.payload.note);
  if (request.operation == 'assign-devices')
   for (let id in request.payload.ids) {
    let was = read_client_labels(directory)[id]?.full ?? false, full = 'mode' in request.payload ? request.payload.mode == 'full' : was;
    write_client_label(directory, id, request.payload.owner, request.payload.note,
     { email: request.payload.email, open: 'block_without_tunnel' in request.payload ? !request.payload.block_without_tunnel : null, full: full });
    // A closed device has no rights whatever its mode: the account of a
    // device that sends everything would otherwise stay a working VPN user.
    if (full || was) set_account_rights(id, full && request.payload.enabled);
    if (full != was) record_client_event(full ? 'mode-full' : 'mode-services', id);
   }
  if (request.operation == 'remove-device') {
   // The account goes with the device; its sessions end with the account.
   // A device registered before this journal existed has no record to clean.
   forget_client_device(directory, seen_directory, request.payload.id);
   forget_client_report(request.payload.id);
   try { cleanup_client_credentials(directory, request.payload.id, read_client_enrollment(directory).ledger.generation); }
   catch (error) { warn('client-access-control: the removed device kept its account\n'); }
  }
  if (request.operation == 'assign-devices')
   record_client_event(request.payload.enabled ? 'access-set' : 'access-closed', join(',', request.payload.ids) + ' services ' + join(',', request.payload.selected_services) +
    (request.payload.block_without_tunnel === false ? ' not-blocked-without-tunnel' : ''));
  else if (request.operation == 'assign-device') record_client_event(request.payload.enabled ? 'access-set' : 'access-closed', request.payload.id);
  else if (request.operation == 'remove-device') record_client_event('device-removed', request.payload.id);
  else if (request.operation == 'assign-service') record_client_event('service-assigned', request.payload.id + ' devices ' + length(request.payload.devices));
  else if (request.operation == 'configure-service') record_client_event(request.payload.client_access ? 'service-published' : 'service-withdrawn', request.payload.id);
  print(`generation=${generation}\nchanged=${prepared.changed ? 1 : 0}\n`);
  }
 } else if ((ARGV[0] == 'initialize' || ARGV[0] == 'publish') && length(ARGV) == 1) {
		let raw = stdin.read(16777217);
		if (type(raw) != 'string' || length(raw) > 16777216)
			die('invalid publication size');
		let request = json(raw);
		if (type(request) != 'object' || length(keys(request)) != 3 || request.version !== 1 ||
			!('expected_generation' in request) || !('desired' in request))
			die('invalid publication request');
		if (ARGV[0] == 'initialize') {
			// A fixed path, protected ancestors and no symlink traversal. No
			// request field or environment variable can select a filesystem path.
			for (let path in [ '/etc', '/etc/ikev2-manager', directory ]) {
				let info = lstat(path);
				if (info == null && path != '/etc') {
					if (!mkdir(path, 0700) || !chmod(path, 0700))
						die('unable to create client directory');
					info = lstat(path);
				}
				if (info?.type != 'directory' || info.uid != 0 || (info.mode & 0022) != 0)
					die('unsafe publication ancestor');
			}
		}
		let generation = publish_client_state(directory, request.desired, request.expected_generation, ARGV[0] == 'initialize');
		print(`generation=${generation}\n`);
	} else {
		warn('usage: client-access-control.uc initialize|publish|status|inspect|update|refresh\n');
		exit(2);
	}
} catch (error) {
	// Never include submitted device keys, domains or private addresses.
	warn('client-access-control: state unavailable or publication refused\n');
	exit(1);
}
