// Local administrative entry point. The device HTTP API is read-only.
'use strict';
import { stdin, lstat, mkdir, chmod, popen } from 'fs';
import { publish_client_state, read_client_state } from './client-access-store.uc';

import { read_client_enrollment } from './client-access-enrollment-store.uc';
import { client_admin_catalog_ids, prepare_client_admin, inspect_client_admin } from './client-access-admin.uc';

let directory = '/etc/ikev2-manager/clients';
try {
	if (ARGV[0] == 'status' && length(ARGV) == 1) {
		let state = read_client_state(directory);
		print(`generation=${state.generation}\n`);
		print(`devices=${length(state.api.devices)}\n`);
		print(`enabled=${length(filter(state.api.devices, device => device.enabled))}\n`);
		print(`retired=${length(state.retired_ids)}\n`);
		print(`allocations=${length(state.publication.allocations)}\n`);
	} else if (ARGV[0] == 'inspect' && length(ARGV) == 1) {
  let inspected = inspect_client_admin(read_client_state(directory));
  for (let service in inspected.services) {
   if (!service.client_access) continue;
   let reader = popen('/usr/libexec/ikev2-domains-community client-service-hosts-get ' + service.id, 'r');
   let listed = reader?.read(16385), status = reader?.close();
   service.hosts = status == 0 && type(listed) == 'string' ? filter(split(listed, '\n'), name => length(name)) : [];
  }
  inspected.enrollment_generation = lstat(directory + '/invitations.json') == null && lstat(directory + '/enrollment-initialized') == null ? 0 : read_client_enrollment(directory).ledger.generation;
  let port_reader = popen('/sbin/uci -q get ikev2-manager.client_access.port', 'r');
  let port_raw = port_reader?.read(32), port_status = port_reader?.close();
  let api_port = port_status == 0 ? replace(port_raw ?? '', /\n$/, '') : '8443';
  inspected.api_endpoint = match(api_port, /^[1-9][0-9]{3,4}$/) && int(api_port) >= 1024 && int(api_port) <= 65535 ?
   'https://' + inspected.server.address + ':' + api_port + '/client/v1/enroll' : null;
  print(sprintf('%J\n', inspected));
 } else if ((ARGV[0] == 'update' || ARGV[0] == 'refresh') && length(ARGV) == 1) {
  let state = read_client_state(directory), request;
  if (ARGV[0] == 'refresh') request = { version: 1, expected_generation: state.generation,
   operation: 'refresh-catalog', payload: {} };
  else {
   let raw = stdin.read(1048577);
   if (type(raw) != 'string' || length(raw) > 1048576) die('oversized administrative request');
   request = json(raw);
  }
  let ids = client_admin_catalog_ids(state, request), catalog = [];
  if (request.operation == 'configure-service' && request.payload.client_access && 'hosts' in request.payload) {
   // The catalog helper owns the list and checks every name against it.
   let writer = popen('/usr/libexec/ikev2-domains-community client-service-hosts-set ' + request.payload.id, 'w');
   if (!writer) die('catalog unavailable');
   writer.write(join('\n', request.payload.hosts) + '\n');
   if (writer.close() != 0) die('host names refused');
  }
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
  print(`generation=${generation}\nchanged=${prepared.changed ? 1 : 0}\n`);
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
