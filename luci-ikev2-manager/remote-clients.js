'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared-v14 as common';

var helper = '/usr/libexec/ikev2-client-admin';
var catalogHelper = '/usr/libexec/ikev2-domains-community';

function readState() {
 return Promise.all([
  L.resolveDefault(fs.exec(helper, [ 'client-admin-show' ]), { code: 1, stdout: '' }),
  L.resolveDefault(fs.exec(catalogHelper, [ 'services' ]), { code: 1, stdout: '' }),
  L.resolveDefault(fs.exec(helper, [ 'client-admin-settings' ]), { code: 1, stdout: '' })
 ]);
}

function catalogRecords(stdout) {
 return (stdout || '').trim().split('\n').filter(Boolean).map(function(line) {
  var fields = line.split('|');
  return { id: fields[0], label: fields[1] || fields[0] };
 }).filter(function(record) { return /^[a-z0-9][a-z0-9_-]{0,47}$/.test(record.id); });
}

function ports(value) {
 var result = String(value || '').trim().split(/[\s,]+/).filter(Boolean).map(function(item) {
  if (!/^[0-9]{1,5}$/.test(item) || Number(item) < 1 || Number(item) > 65535)
   throw new Error(_('Enter port numbers from 1 to 65535, separated by spaces or commas.'));
  return Number(item);
 });
 return Array.from(new Set(result)).sort(function(a, b) { return a - b; });
}

function saveRequest(button, result, request, onSuccess) {
 var token = common.inputToken();
 return fs.write('/var/run/ikev2-client-admin-' + token + '.in', JSON.stringify(request), 384).then(function() {
  return common.runJob({
   button: button, result: result, busy: _('Saving client configuration...'),
   success: _('Client configuration saved.'), failure: _('Could not save client configuration.'),
   startPath: helper, startArgs: [ 'client-admin-update', token ],
   statusPath: helper, statusArgs: [ 'client-admin-status' ], timeout: 330000,
   onSuccess: onSuccess
  });
 }, function(error) { result.err(_('Could not stage client configuration: %s').format(error.message || error)); });
}

// Activation and the registration listener. Before the first save nothing else
// on the page exists yet, so this section is the only one offered.
function setupSection(settings, reload) {
 var result = common.inlineResult(), save;
 var enabled = E('input', { 'type': 'checkbox', 'checked': settings.enabled ? '' : null, 'aria-label': _('Accept remote clients') });
 var port = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Registration port'), 'value': String(settings.port) });
 var subnet = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Virtual subnet'),
  'value': settings.virtual_subnet || '172.31.240.0/20', 'disabled': settings.initialized ? '' : null });
 var exits = [];
 settings.tunnels.forEach(function(index) {
  exits.push([ index, settings.tunnels.length > 1 ? _('Tunnel %s, another tunnel when it fails').format(index) : _('Tunnel %s').format(index) ]);
  if (settings.tunnels.length > 1) exits.push([ index + 's', _('Tunnel %s only').format(index) ]);
 });
 var exit = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Exit tunnel') }, exits.map(function(item) {
  return E('option', { 'value': item[0], 'selected': item[0] === (settings.exit || '1') ? '' : null }, [ item[1] ]);
 }));
 var notes = [];
 if (!settings.server_enabled || !settings.server_identity)
  notes.push(E('div', { 'class': 'ikev2-note warn' }, [ _('Enable the inbound server with a DNS name first: remote clients register and connect through it.') ]));
 if (settings.custom_server)
  notes.push(E('div', { 'class': 'ikev2-note warn' }, [ _('The inbound server runs your own configuration, which this page does not change. For macOS devices add to it a connection named ikev2-in-managed that answers the identity *@managed.ikev2-manager and offers only the virtual subnet; without it a Mac refuses the tunnel, because it would carry all of its traffic.') ]));
 if (!settings.tunnels.length)
  notes.push(E('div', { 'class': 'ikev2-note warn' }, [ _('Enable an outbound tunnel first: selected services leave through it.') ]));
 save = E('button', { 'class': 'cbi-button cbi-button-positive', 'type': 'button',
  'disabled': !settings.server_identity || !settings.tunnels.length ? '' : null, 'click': function() {
  var number = Number(port.value.trim());
  if (!/^[0-9]{4,5}$/.test(port.value.trim()) || number < 1024 || number > 65535) { result.err(_('Enter a port from 1024 to 65535.')); return; }
  if (!/^[0-9]{1,3}(\.[0-9]{1,3}){3}\/(1[6-9]|2[0-8])$/.test(subnet.value.trim())) { result.err(_('Enter a private IPv4 subnet from /16 to /28, for example 172.31.240.0/20.')); return; }
  var token = common.inputToken();
  var request = { version: 1, enabled: enabled.checked, port: number, virtual_subnet: subnet.value.trim(), exit: exit.value };
  return fs.write('/var/run/ikev2-client-admin-' + token + '.in', JSON.stringify(request), 384).then(function() {
   return common.runJob({ button: save, result: result, busy: _('Applying remote client settings...'),
    success: _('Remote client settings applied.'), failure: _('Could not apply remote client settings.'),
    startPath: helper, startArgs: [ 'client-admin-setup', token ], statusPath: helper, statusArgs: [ 'client-admin-status' ],
    timeout: 330000, onSuccess: reload });
  }, function() { result.err(_('Could not stage remote client settings.')); });
 } }, [ settings.initialized ? _('Save') : _('Set up remote clients') ]);
 return common.section(settings.initialized ? _('Settings') : _('Set up remote clients'),
  settings.initialized ? null : _('Devices register over HTTPS and reach the selected services through the inbound server.'),
  E('div', {}, notes.concat([
   common.toggleRow(enabled, _('Accept remote clients'), settings.server_identity ?
    _('%s, open on WAN while this is on').format('https://' + settings.server_identity + ':' + settings.port) : null),
   E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact', 'style': 'margin-top:1.15rem' }, [
    common.fieldLabel(_('Registration port')), port,
    common.fieldLabel(_('Exit tunnel'), _('Selected services leave through it.')), exit,
    common.fieldLabel(_('Virtual subnet'), settings.initialized ?
     _('Fixed once set.') : _('Must not be used anywhere in your networks. Fixed once set.')), subnet
   ]),
   E('div', { 'class': 'ikev2-actions end' }, [ result.node, save ])
  ])));
}

function editDialog(title, form, buildRequest, reload, pageResult, unsaved) {
 var result = common.inlineResult(), save, tracker;
 var body = E('div', { 'class': 'ikev2-page' }, [
  common.styles(), form,
  E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1.2rem' }, [
   result.node,
   E('button', { 'class': 'cbi-button', 'type': 'button', 'click': ui.hideModal }, [ _('Cancel') ]),
   (save = E('button', { 'class': 'cbi-button cbi-button-positive', 'type': 'button', 'click': function() {
    var request;
    try { request = buildRequest(); } catch (error) { result.err(error.message); return; }
    return saveRequest(save, result, request, function() {
     return reload().then(function() {
      tracker.reset(); ui.hideModal(); pageResult.ok(_('Client configuration saved.'));
     });
    });
   } }, [ _('Save') ]))
  ])
 ]);
 tracker = common.trackChanges(save, [ form ]);
 // A proposal the administrator has not stored yet can be saved as it is.
 if (unsaved) save.disabled = false;
 ui.showModal(title, [ body ]);
}

function serviceDialog(record, current, generation, reload, pageResult, unsaved) {
 current = current || { client_access: false, transports: [ { protocol: 'tcp', ports: [ 443 ] } ] };
 var published = E('input', { 'type': 'checkbox', 'checked': current.client_access ? '' : null, 'aria-label': _('Available to remote clients') });
 var tcp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('TCP ports'), 'value': current.transports.filter(function(t) { return t.protocol === 'tcp'; }).map(function(t) { return t.ports.join(' '); }).join(' ') });
 var udp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('UDP ports'), 'value': current.transports.filter(function(t) { return t.protocol === 'udp'; }).map(function(t) { return t.ports.join(' '); }).join(' ') });
 var form = E('div', {}, [
  common.toggleRow(published, _('Available to remote clients'), _('Disabling removes this service from all device assignments.')),
  E('div', { 'class': 'ikev2-form-grid' }, [
   E('div', {}, [ common.fieldLabel(_('TCP ports')), tcp ]),
   E('div', {}, [ common.fieldLabel(_('UDP ports')), udp ])
  ])
 ]);
 editDialog(record.label, form, function() {
  var transports = [], tcpPorts = ports(tcp.value), udpPorts = ports(udp.value);
  if (tcpPorts.length) transports.push({ protocol: 'tcp', ports: tcpPorts });
  if (udpPorts.length) transports.push({ protocol: 'udp', ports: udpPorts });
  if (!transports.length) throw new Error(_('Specify at least one TCP or UDP port.'));
  return { version: 1, expected_generation: generation, operation: 'configure-service',
   payload: { id: record.id, client_access: published.checked, transports: transports } };
 }, reload, pageResult, unsaved);
}

// "5 min", "3 h", "2 d": how long ago, or for how long.
function span(seconds) {
 if (seconds < 90) return _('%d s').format(seconds);
 if (seconds < 5400) return _('%d min').format(Math.round(seconds / 60));
 if (seconds < 86400) return _('%d h').format(Math.round(seconds / 3600));
 return _('%d d').format(Math.round(seconds / 86400));
}

function describeText(value, limit, label) {
 value = String(value || '').trim();
 if (value.length > limit || /[<>\u0000-\u001f\u007f]/.test(value))
  throw new Error(_('%s: up to %d characters, without < and >.').format(label, limit));
 return value;
}

// One device of a person: what it is, how it is doing, what to do with it.
function deviceRow(device, onRemove) {
 var state, detail = '';
 if (device.waiting)
  return E('div', { 'class': 'ikev2-session' }, [ E('div', { 'class': 'ikev2-session-main' }, [
   E('span', { 'class': 'ikev2-session-address' }, [ device.id ]),
   E('div', { 'class': 'ikev2-session-meta' }, [ common.pill(_('Waiting for registration'), 'info'),
    E('span', {}, [ _('link valid for %s more').format(span(device.expires_seconds)) ]) ]) ]) ]);
 if (!device.enabled) state = common.pill(_('Access off'), 'warn');
 else if (!device.selected_services.length) state = common.pill(_('No services'), 'warn');
 else if (device.online) {
  state = common.pill(Number.isInteger(device.connected_seconds) ? _('Online for %s').format(span(device.connected_seconds)) : _('Online'), 'good');
  detail = _('from %s, tunnel address %s').format(device.remote_address || '-', device.tunnel_address || '-');
 } else if (Number.isInteger(device.seen_seconds)) {
  state = common.pill(_('Offline'), 'neutral');
  detail = _('last seen %s ago from %s').format(span(device.seen_seconds), device.seen_from || '-');
 } else state = common.pill(_('Not connected yet'), 'info');
 var computer = [ device.system, device.client ? _('client %s').format(device.client) : '' ].filter(Boolean).join(' \u00b7 ');
 return E('div', { 'class': 'ikev2-session' }, [
  E('div', { 'class': 'ikev2-session-main' }, [
   E('span', { 'class': 'ikev2-session-address' }, [ device.host || device.id ]),
   E('div', { 'class': 'ikev2-session-meta' }, [ state ].concat([ device.host ? device.id : '', computer, detail ].filter(Boolean).map(function(text) { return E('span', {}, [ text ]); })))
  ]),
  E('button', { 'class': 'cbi-button', 'type': 'button', 'click': onRemove }, [ _('Remove') ])
 ]);
}

// A person and their devices. Devices without a named owner stand alone.
function personCard(person, labels, actions) {
 var first = person.devices[0], services = first.selected_services;
 return E('div', { 'class': 'ikev2-user-card' }, [
  E('div', { 'class': 'ikev2-user-identity' }, [
   E('span', { 'class': 'ikev2-user-avatar' }, [ person.name.slice(0, 1) ]),
   E('div', { 'style': 'min-width:0' }, [
    E('strong', { 'class': 'ikev2-user-name' }, [ person.name ]),
    E('div', { 'class': 'ikev2-session-meta' }, (first.note ? [ E('span', {}, [ first.note ]) ] : []).concat(
     services.length ? services.map(function(id) { return common.pill(labels[id] || id, 'neutral'); }) : [ common.pill(_('No services'), 'warn') ]))
   ])
  ]),
  E('div', { 'class': 'ikev2-session-list' }, person.devices.map(function(device) { return deviceRow(device, function() { actions.remove(device); }); })),
  E('div', { 'class': 'ikev2-user-actions' }, [
   person.devices.some(function(device) { return !device.waiting; }) ?
    E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { actions.edit(person); } }, [ _('Edit') ]) : '',
   person.devices.some(function(device) { return device.waiting; }) ?
    E('button', { 'class': 'cbi-button', 'type': 'button', 'title': _('The link is shown once. A new one replaces it.'), 'click': function() { actions.relink(person); } }, [ _('New link') ]) : '',
   E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() { actions.add(person); } }, [ _('Add device') ])
  ])
 ]);
}

function people(devices, waiting) {
 var list = [], byName = {};
 devices.concat((waiting || []).map(function(item) {
  return { id: item.id, owner: item.owner, note: item.note, selected_services: item.selected_services, expires_seconds: item.expires_seconds, enabled: true, waiting: true };
 })).sort(function(a, b) { return a.id.localeCompare(b.id, undefined, { numeric: true }); }).forEach(function(device) {
  var person = device.owner ? byName[device.owner] : null;
  if (!person) { person = { name: device.owner || device.id, owner: device.owner || '', devices: [] }; list.push(person); if (device.owner) byName[device.owner] = person; }
  person.devices.push(device);
 });
 return list.sort(function(a, b) { return a.name.localeCompare(b.name); });
}

// A Latin identifier from a person's name, for the field's first value.
function suggestId(name) {
 var map = { '\u0430':'a','\u0431':'b','\u0432':'v','\u0433':'g','\u0434':'d','\u0435':'e','\u0451':'e','\u0436':'zh','\u0437':'z','\u0438':'i','\u0439':'y','\u043a':'k','\u043b':'l','\u043c':'m','\u043d':'n','\u043e':'o','\u043f':'p','\u0440':'r','\u0441':'s','\u0442':'t','\u0443':'u','\u0444':'f','\u0445':'h','\u0446':'ts','\u0447':'ch','\u0448':'sh','\u0449':'sch','\u044a':'','\u044b':'y','\u044c':'','\u044d':'e','\u044e':'yu','\u044f':'ya' };
 return String(name || '').toLowerCase().split('').map(function(c) { return map[c] != null ? map[c] : c; }).join('')
  .replace(/[^a-z0-9]+/g, '-').replace(/^[^a-z]+|-+$/g, '').slice(0, 40);
}

function removeDialog(device, state, reload, pageResult) {
 var result = common.inlineResult(), remove;
 ui.showModal(_('Remove device %s').format(device.id), [ E('div', { 'class': 'ikev2-page' }, [ common.styles(),
  E('p', {}, [ _('The device loses access and its connection ends. Its identifier cannot be used again.') ]),
  E('div', { 'class': 'ikev2-actions end' }, [ result.node,
   E('button', { 'class': 'cbi-button', 'type': 'button', 'click': ui.hideModal }, [ _('Cancel') ]),
   (remove = E('button', { 'class': 'cbi-button cbi-button-negative', 'type': 'button', 'click': function() {
    return saveRequest(remove, result, { version: 1, expected_generation: state.generation, operation: 'remove-device', payload: { id: device.id } }, function() {
     return reload().then(function() { ui.hideModal(); pageResult.ok(_('Device removed.')); });
    });
   } }, [ _('Remove') ])) ]) ]) ]);
}

function personDialog(person, state, labels, reload, pageResult) {
 var device = person.devices.filter(function(item) { return !item.waiting; })[0];
 var owner = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Who uses it'), 'value': device.owner || '' });
 var note = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Note'), 'value': device.note || '' });
 var enabled = E('input', { 'type': 'checkbox', 'checked': device.enabled ? '' : null, 'aria-label': _('Access enabled') });
 var choices = state.services.filter(function(service) { return service.client_access; }).map(function(service) {
  return { id: service.id, input: E('input', { 'type': 'checkbox', 'checked': device.selected_services.indexOf(service.id) >= 0 ? '' : null, 'aria-label': labels[service.id] || service.id }) };
 });
 var form = E('div', {}, [
  E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
   common.fieldLabel(_('Who uses it')), owner,
   common.fieldLabel(_('Note')), note
  ]),
  E('div', { 'style': 'margin-top:1rem' }, [ common.toggleRow(enabled, _('Access enabled'),
   person.devices.length > 1 ? _('Applies to all %d devices.').format(person.devices.length) : null) ]),
  E('div', { 'style': 'margin-top:1rem' }, [ common.fieldLabel(_('Services')) ].concat(choices.map(function(choice) { return common.toggleRow(choice.input, labels[choice.id] || choice.id); })))
 ]);
 editDialog(person.name, form, function() {
  return { version: 1, expected_generation: state.generation, operation: 'assign-devices',
   payload: { ids: person.devices.filter(function(item) { return !item.waiting; }).map(function(item) { return item.id; }), enabled: enabled.checked,
    selected_services: choices.filter(function(c) { return c.input.checked; }).map(function(c) { return c.id; }),
    owner: describeText(owner.value, 80, _('Who uses it')), note: describeText(note.value, 160, _('Note')) } };
 }, reload, pageResult);
}

function invitationDialog(state, labels, reload, person, replace) {
 var result = common.inlineResult(), create, tracker;
 var generation = state.enrollment_generation;
 var taken = {};
 state.devices.concat(state.waiting || []).forEach(function(device) { taken[device.id] = true; });
 // The next free identifier for one more device of a known person.
 function free(base) {
  if (!base) return '';
  for (var n = 1; n < 100; n++) { var candidate = n === 1 && !taken[base] ? base : base + '-' + (n + 1); if (!taken[candidate] && !taken[candidate + '-1']) return candidate; }
  return base;
 }
 var known = person && person.devices[0];
 replace = replace || [];
 var id = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Device identifier'),
  value: known ? free(suggestId(person.owner) || known.id.replace(/-[0-9]+$/, '')) : '' });
 var endpoint = state.api_endpoint || 'https://' + state.server.address + ':8443/client/v1/enroll';
 var choices = state.services.filter(function(service) { return service.client_access; }).map(function(service) {
  return { id: service.id, input: E('input', { type: 'checkbox', 'aria-label': labels[service.id] || service.id,
   checked: known && known.selected_services.indexOf(service.id) >= 0 ? '' : null }) };
 });
 if (!known && choices.length === 1) choices[0].input.checked = true;
 var owner = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Who uses it'), value: known ? known.owner || '' : '' });
 var note = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Note'), value: known ? known.note || '' : '' });
 var count = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Devices') }, [ 1, 2, 3, 4, 5 ].map(function(n) {
  return E('option', { value: String(n), selected: n === replace.length ? '' : null }, [ String(n) ]);
 }));
 var lifetime = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Link is valid for') }, [ [ 3600, _('1 hour') ], [ 86400, _('1 day') ], [ 604800, _('7 days') ] ].map(function(item) {
  return E('option', { value: String(item[0]), selected: item[0] === 86400 ? '' : null }, [ item[1] ]);
 }));
 // The identifier follows the name until the administrator types their own.
 var typed = !!known;
 id.addEventListener('input', function() { typed = true; });
 owner.addEventListener('input', function() { if (!typed) id.value = free(suggestId(owner.value)); });
 var form = E('div', {}, [
  E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
   common.fieldLabel(_('Who uses it')), owner,
   common.fieldLabel(_('Note')), note,
   common.fieldLabel(_('Devices'), _('One link registers this many devices of the person.')), count,
   common.fieldLabel(_('Device identifier'), _('Latin letters, digits and hyphens. Cannot be changed or used again.')), id,
   common.fieldLabel(_('Link is valid for')), lifetime
  ]),
  replace.length ? E('p', { 'class': 'ikev2-note' }, [ _('The previous link stops working.') ]) : '',
  E('div', { 'style': 'margin:1rem 0' }, [ common.fieldLabel(_('Services')) ].concat(choices.map(function(choice) { return common.toggleRow(choice.input, labels[choice.id] || choice.id); })))
 ]);
 function showLink(link) {
  var field = E('textarea', { readonly: '', 'aria-label': _('Invitation link') });
  field.value = link;
  var output = common.inlineResult(), copy;
  ui.showModal(_('Invitation link'), [ E('div', { 'class': 'ikev2-page' }, [
   common.styles(), E('p', {}, [ _('Shown only once. Send it privately: the owner installs Waypoint on each device and pastes the link there.') ]), field,
   E('div', { 'class': 'ikev2-actions end' }, [ output.node,
    E('button', { type: 'button', 'class': 'cbi-button', click: function() { field.value = ''; ui.hideModal(); } }, [ _('Close') ]),
    (copy = E('button', { type: 'button', 'class': 'cbi-button cbi-button-action', click: function() {
     return common.runAction({ button: copy, result: output, busy: _('Copying...'), success: _('Copied'), failure: _('Could not copy invitation link.'), run: function() { return common.copyText(field.value); } });
    } }, [ _('Copy') ]))
   ])
  ]) ]);
 }
 create = E('button', { type: 'button', 'class': 'cbi-button cbi-button-positive', click: function() {
  var selected = choices.filter(function(choice) { return choice.input.checked; }).map(function(choice) { return choice.id; });
  if (!/^[a-z][a-z0-9-]{0,45}$/.test(id.value) || !selected.length) {
   result.err(_('Enter a device identifier and select at least one service.')); return;
  }
  var token = common.inputToken(), request;
  try {
   request = { version: 1, expected_generation: generation,
    endpoint: endpoint, id: id.value, selected_services: selected, lifetime_seconds: Number(lifetime.value) || 86400,
    owner: describeText(owner.value, 80, _('Who uses it')), note: describeText(note.value, 160, _('Note')) };
   if (Number(count.value) > 1) request.count = Number(count.value);
   if (replace.length) request.cancel = replace.map(function(item) { return item.id; });
  } catch (error) { result.err(error.message); return; }
  return fs.write('/var/run/ikev2-client-admin-' + token + '.in', JSON.stringify(request), 384).then(function() {
   return common.runJob({ button: create, result: result, busy: _('Creating invitation...'), success: _('Invitation created.'), failure: _('Could not create invitation.'),
    startPath: helper, startArgs: [ 'client-admin-invite', token ], statusPath: helper, statusArgs: [ 'client-admin-status' ], timeout: 330000,
    onSuccess: function(status) {
     return fs.exec(helper, [ 'client-admin-take-invitation', status.action_id ]).then(function(response) {
      if (response.code !== 0) throw new Error(_('Invitation is unavailable. Create a new invitation with a new device identifier.'));
      var delivered = JSON.parse(response.stdout);
      if (delivered.version !== 1 || delivered.id !== request.id || typeof delivered.invitation !== 'string' ||
       delivered.invitation.indexOf(request.endpoint + '#') !== 0 || !/#[a-f0-9]{64}$/.test(delivered.invitation))
       throw new Error(_('Invalid invitation response.'));
      tracker.reset(); showLink(delivered.invitation); return reload();
     });
    }
   });
  }, function() { result.err(_('Could not stage invitation.')); });
 } }, [ _('Create invitation') ]);
 tracker = common.trackChanges(create, [ form ]);
 ui.showModal(replace.length ? _('New link for %s').format(person.name) : person ? _('Add device for %s').format(person.name) : _('Add person'), [ E('div', { 'class': 'ikev2-page' }, [ common.styles(), form,
  E('div', { 'class': 'ikev2-actions end' }, [ result.node,
   E('button', { type: 'button', 'class': 'cbi-button', click: ui.hideModal }, [ _('Cancel') ]), create ]) ]) ]);
}

return view.extend({
 load: readState,
 render: function(data) {
  var state, records = [], labels = {}, services = E('div', {}), devices = E('div', {});
  var result = common.inlineResult(), availability = E('div', {}), setup = E('div', {}), fresh = E('div', {}), managed = E('div', {}), refresh, invite;
  function reload() { return readState().then(setData); }
  function setData(next) {
   state = null;
   var settings = null;
   try {
    settings = JSON.parse(next[2].stdout);
    if (next[2].code !== 0 || settings.version !== 1 || !Array.isArray(settings.tunnels)) settings = null;
   } catch (error) { settings = null; }
   var section = settings ? setupSection(settings, reload) : E('div', {});
   fresh.replaceChildren(); setup.replaceChildren();
   (settings && !settings.initialized ? fresh : setup).replaceChildren(section);
   managed.style.display = settings && !settings.initialized ? 'none' : '';
   if (settings && !settings.initialized) { availability.replaceChildren(); return; }
   try {
    if (next[0].code !== 0) throw new Error('unavailable');
    var parsed = JSON.parse(next[0].stdout);
    if (parsed.version !== 1 || !Array.isArray(parsed.services) || !Array.isArray(parsed.devices)) throw new Error('invalid');
    state = parsed;
   } catch (error) {
    availability.replaceChildren(E('div', { 'class': 'ikev2-note warn' }, [ _('Client configuration is unavailable.') ]));
    services.replaceChildren(); devices.replaceChildren();
    if (refresh) refresh.disabled = true;
    if (invite) invite.disabled = true;
    return;
   }
   availability.replaceChildren();
   if (refresh) refresh.disabled = false;
   if (invite) invite.disabled = !Number.isInteger(state.enrollment_generation) || !state.services.some(function(service) { return service.client_access; });
   records = catalogRecords(next[1].stdout); labels = {};
   records.forEach(function(record) { labels[record.id] = record.label; });
   state.services.forEach(function(service) {
    if (!labels[service.id]) { labels[service.id] = service.id; records.push({ id: service.id, label: service.id }); }
   });
   function portsText(service) {
    return service.transports.map(function(t) { return t.protocol.toUpperCase() + ' ' + t.ports.join(', '); }).join(' \u00b7 ');
   }
   function current(record) { return state.services.filter(function(service) { return service.id === record.id; })[0]; }
   // Published services first: they are what the page is about.
   records.sort(function(a, b) {
    var pa = current(a) && current(a).client_access ? 0 : 1, pb = current(b) && current(b).client_access ? 0 : 1;
    return pa - pb || a.label.localeCompare(b.label);
   });
   // The catalog is long; the table holds what is published, and a picker
   // below it publishes one more.
   var shown = records.filter(function(record) { return current(record) && current(record).client_access; });
   var serviceRows = shown.map(function(record) {
    var service = current(record);
    return E('tr', { 'class': 'tr' }, [
     E('td', { 'class': 'td' }, [ E('strong', {}, [ record.label ]) ]),
     E('td', { 'class': 'td' }, [ portsText(service) ]),
     E('td', { 'class': 'td' }, [ String(service.domain_count) ]),
     E('td', { 'class': 'td', 'style': 'text-align:right' }, [ E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { serviceDialog(record, service, state.generation, reload, result); } }, [ _('Edit') ]) ])
    ]);
   });
   var others = records.filter(function(record) { return shown.indexOf(record) < 0; });
   var pick = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Service to publish') }, others.map(function(record) {
    return E('option', { 'value': record.id }, [ record.label ]);
   }));
   var publish = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() {
    var record = others.filter(function(item) { return item.id === pick.value; })[0] || others[0];
    if (record) serviceDialog(record, Object.assign({ transports: [ { protocol: 'tcp', ports: [ 443 ] } ] }, current(record) || {}, { client_access: true }), state.generation, reload, result, true);
   } }, [ _('Publish...') ]);
   services.replaceChildren(
    shown.length ? E('table', { 'class': 'table cbi-section-table' }, [
     E('tr', { 'class': 'tr' }, [ _('Service'), _('Ports'), _('Domains'), '' ].map(function(text) { return E('th', { 'class': 'th' }, [ text ]); }))
    ].concat(serviceRows)) : E('div', { 'class': 'ikev2-empty' }, [ _('No service is published yet.') ]),
    others.length ? E('div', { 'class': 'ikev2-actions', 'style': 'margin-top:.9rem' }, [ pick, publish ]) : '');
   var actions = {
    edit: function(person) { personDialog(person, state, labels, reload, result); },
    add: function(person) { invitationDialog(state, labels, reload, person); },
    relink: function(person) { invitationDialog(state, labels, reload, person, person.devices.filter(function(device) { return device.waiting; })); },
    remove: function(device) { removeDialog(device, state, reload, result); }
   };
   devices.replaceChildren(state.devices.length || (state.waiting || []).length ? E('div', { 'class': 'ikev2-user-list' }, people(state.devices, state.waiting).map(function(person) {
    return personCard(person, labels, actions);
   })) : E('div', { 'class': 'ikev2-empty' }, [ invite && invite.disabled ? _('Publish a service below, then add the first device.') : _('No devices yet. Add one to get its invitation link.') ]));
  }
  refresh = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() {
   return common.runJob({ button: refresh, result: result,
    busy: _('Updating service lists...'), success: _('Service lists updated.'), failure: _('Could not update service lists.'),
    startPath: helper, startArgs: [ 'client-admin-refresh' ], statusPath: helper, statusArgs: [ 'client-admin-status' ],
    timeout: 330000, onSuccess: reload });
  } }, [ _('Update service lists') ]);
  invite = E('button', { type: 'button', 'class': 'cbi-button cbi-button-action', click: function() { invitationDialog(state, labels, reload); } }, [ _('Add person') ]);
  setData(data);
  return E([ common.styles(), E('div', { 'class': 'ikev2-page' }, [
   common.header(_('Remote clients'), _('Selected services for Windows and macOS devices running Waypoint.')),
   availability, fresh,
   (managed.replaceChildren(
    common.section(_('People and devices'), null, E('div', {}, [ devices, E('div', { 'class': 'ikev2-actions end' }, [ result.node ]) ]), invite),
    common.section(_('Services'), _('Lists are shared with Policy Routing.'), services, refresh),
    setup
   ), managed)
  ]) ]);
 },
 handleSaveApply: null, handleSave: null, handleReset: null
});
