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
 var exit = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Exit for remote clients') }, exits.map(function(item) {
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
 return common.section(_('Access for remote clients'),
  _('Devices register over HTTPS on this port and reach their services through the inbound server. The port is opened on WAN while this is on.'),
  E('div', {}, notes.concat([
   common.toggleRow(enabled, _('Accept remote clients'), settings.server_identity ?
    _('Registration address: %s').format('https://' + settings.server_identity + ':' + settings.port) : null),
   E('div', { 'class': 'ikev2-grid' }, [
    E('div', {}, [ common.fieldLabel(_('Registration port')), port ]),
    E('div', {}, [ common.fieldLabel(_('Exit for remote clients')), exit ]),
    E('div', {}, [ common.fieldLabel(_('Virtual subnet'), settings.initialized ?
     _('Enrolled devices keep this subnet; it cannot change.') : _('Addresses that stand for the selected services. It must not be used anywhere in your networks.')), subnet ])
   ]),
   E('div', { 'class': 'ikev2-actions end' }, [ result.node, save ])
  ])));
}

function editDialog(title, form, buildRequest, reload, pageResult) {
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
 ui.showModal(title, [ body ]);
}

function serviceDialog(record, current, generation, reload, pageResult) {
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
 }, reload, pageResult);
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

// What the administrator needs to tell one device from another.
function deviceWho(device) {
 return E('div', {}, [ E('strong', {}, [ device.id ]) ].concat(
  device.owner ? [ E('div', {}, [ device.owner ]) ] : [],
  device.note ? [ E('div', { 'style': 'color:var(--ikev2-muted)' }, [ device.note ]) ] : []));
}

function deviceComputer(device) {
 if (!device.host && !device.system) return E('span', { 'style': 'color:var(--ikev2-muted)' }, [ _('Not reported yet') ]);
 return E('div', {}, [ E('div', {}, [ device.host || '-' ]) ].concat(
  device.system ? [ E('div', { 'style': 'color:var(--ikev2-muted)' }, [ device.client ? _('%s, client %s').format(device.system, device.client) : device.system ]) ] : []));
}

function deviceState(device) {
 if (!device.enabled || !device.selected_services.length) return E('span', {}, [ _('Access closed') ]);
 if (device.online)
  return E('div', {}, [ E('div', {}, [ Number.isInteger(device.connected_seconds) ? _('Online for %s').format(span(device.connected_seconds)) : _('Online') ]),
   E('div', { 'style': 'color:var(--ikev2-muted)' }, [ _('from %s, tunnel address %s').format(device.remote_address || '-', device.tunnel_address || '-') ]) ]);
 if (Number.isInteger(device.seen_seconds))
  return E('div', {}, [ E('div', {}, [ _('Offline') ]),
   E('div', { 'style': 'color:var(--ikev2-muted)' }, [ _('last seen %s ago from %s').format(span(device.seen_seconds), device.seen_from || '-') ]) ]);
 return E('span', {}, [ _('Has not connected yet') ]);
}

function removeDialog(device, state, reload, pageResult) {
 var result = common.inlineResult(), remove;
 ui.showModal(_('Remove device %s').format(device.id), [ E('div', { 'class': 'ikev2-page' }, [ common.styles(),
  E('p', {}, [ _('The device loses its access and its account on this router, and its connection ends. Its identifier cannot be used again: a returning device needs a new invitation under another identifier.') ]),
  E('div', { 'class': 'ikev2-actions end' }, [ result.node,
   E('button', { 'class': 'cbi-button', 'type': 'button', 'click': ui.hideModal }, [ _('Cancel') ]),
   (remove = E('button', { 'class': 'cbi-button cbi-button-negative', 'type': 'button', 'click': function() {
    return saveRequest(remove, result, { version: 1, expected_generation: state.generation, operation: 'remove-device', payload: { id: device.id } }, function() {
     return reload().then(function() { ui.hideModal(); pageResult.ok(_('Device removed.')); });
    });
   } }, [ _('Remove') ])) ]) ]) ]);
}

function deviceDialog(device, state, labels, reload, pageResult) {
 var owner = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Who uses it'), 'value': device.owner || '' });
 var note = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'aria-label': _('Note'), 'value': device.note || '' });
 var enabled = E('input', { 'type': 'checkbox', 'checked': device.enabled ? '' : null, 'aria-label': _('Device access enabled') });
 var choices = state.services.filter(function(service) { return service.client_access; }).map(function(service) {
  return { id: service.id, input: E('input', { 'type': 'checkbox', 'checked': device.selected_services.indexOf(service.id) >= 0 ? '' : null, 'aria-label': labels[service.id] || service.id }) };
 });
 var form = E('div', {}, [
  E('div', { 'class': 'ikev2-form-grid' }, [
   E('div', {}, [ common.fieldLabel(_('Who uses it'), _('A name you will recognise: the employee, the role.')), owner ]),
   E('div', {}, [ common.fieldLabel(_('Note')), note ])
  ]),
  common.toggleRow(enabled, _('Device access enabled')),
  E('div', {}, choices.map(function(choice) { return common.toggleRow(choice.input, labels[choice.id] || choice.id); }))
 ]);
 editDialog(device.id, form, function() {
  return { version: 1, expected_generation: state.generation, operation: 'assign-device',
   payload: { id: device.id, enabled: enabled.checked, selected_services: choices.filter(function(c) { return c.input.checked; }).map(function(c) { return c.id; }),
    owner: describeText(owner.value, 80, _('Who uses it')), note: describeText(note.value, 160, _('Note')) } };
 }, reload, pageResult);
}

function invitationDialog(state, labels, reload) {
 var result = common.inlineResult(), create, tracker;
 var generation = state.enrollment_generation;
 var id = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Device identifier') });
 var endpoint = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Registration HTTPS address'), value: state.api_endpoint || 'https://' + state.server.address + ':8443/client/v1/enroll' });
 var choices = state.services.filter(function(service) { return service.client_access; }).map(function(service) {
  return { id: service.id, input: E('input', { type: 'checkbox', 'aria-label': labels[service.id] || service.id }) };
 });
 var owner = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Who uses it') });
 var note = E('input', { type: 'text', 'class': 'cbi-input-text', 'aria-label': _('Note') });
 var form = E('div', {}, [
  common.fieldLabel(_('Device identifier'), _('Latin letters, digits and hyphens, for example ivanov-laptop. It cannot be changed or used again.')), id,
  E('div', { 'class': 'ikev2-form-grid' }, [
   E('div', {}, [ common.fieldLabel(_('Who uses it'), _('A name you will recognise: the employee, the role.')), owner ]),
   E('div', {}, [ common.fieldLabel(_('Note')), note ])
  ]),
  common.fieldLabel(_('Registration HTTPS address')), endpoint,
  E('p', { 'class': 'ikev2-note' }, [ _('Use the configured registration listener address. Creating an invitation does not verify its availability.') ]),
  E('div', {}, choices.map(function(choice) { return common.toggleRow(choice.input, labels[choice.id] || choice.id); }))
 ]);
 function showLink(link) {
  var field = E('textarea', { readonly: '', 'aria-label': _('Invitation link') });
  field.value = link;
  var output = common.inlineResult(), copy;
  ui.showModal(_('Invitation link'), [ E('div', { 'class': 'ikev2-page' }, [
   common.styles(), E('p', {}, [ _('This link expires in 10 minutes and is shown only once. Send it privately to the device owner.') ]), field,
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
  if (!/^[a-z][a-z0-9-]{0,47}$/.test(id.value) || !selected.length) {
   result.err(_('Enter a device identifier and select at least one service.')); return;
  }
  var token = common.inputToken(), request;
  try {
   request = { version: 1, expected_generation: generation,
    endpoint: endpoint.value, id: id.value, selected_services: selected, lifetime_seconds: 600,
    owner: describeText(owner.value, 80, _('Who uses it')), note: describeText(note.value, 160, _('Note')) };
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
 ui.showModal(_('Create invitation'), [ E('div', { 'class': 'ikev2-page' }, [ common.styles(), form,
  E('div', { 'class': 'ikev2-actions end' }, [ result.node,
   E('button', { type: 'button', 'class': 'cbi-button', click: ui.hideModal }, [ _('Cancel') ]), create ]) ]) ]);
}

return view.extend({
 load: readState,
 render: function(data) {
  var state, records = [], labels = {}, services = E('div', {}), devices = E('div', {});
  var result = common.inlineResult(), availability = E('div', {}), setup = E('div', {}), managed = E('div', {}), refresh, invite;
  function reload() { return readState().then(setData); }
  function setData(next) {
   state = null;
   var settings = null;
   try {
    settings = JSON.parse(next[2].stdout);
    if (next[2].code !== 0 || settings.version !== 1 || !Array.isArray(settings.tunnels)) settings = null;
   } catch (error) { settings = null; }
   setup.replaceChildren(settings ? setupSection(settings, reload) : E('div', {}));
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
   var serviceRows = records.map(function(record) {
    var current = state.services.filter(function(service) { return service.id === record.id; })[0];
    return E('tr', { 'class': 'tr' }, [
     E('td', { 'class': 'td' }, [ record.label ]),
     E('td', { 'class': 'td' }, [ current && current.client_access ? _('Published') : _('Not published') ]),
     E('td', { 'class': 'td' }, [ current ? String(current.domain_count) : '-' ]),
     E('td', { 'class': 'td' }, [ E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { serviceDialog(record, current, state.generation, reload, result); } }, [ _('Edit') ]) ])
    ]);
   });
   services.replaceChildren(E('table', { 'class': 'table cbi-section-table' }, [
    E('tr', { 'class': 'tr' }, [ _('Service'), _('Client availability'), _('Domains'), _('Actions') ].map(function(text) { return E('th', { 'class': 'th' }, [ text ]); }))
   ].concat(serviceRows)));
   var deviceRows = state.devices.map(function(device) {
    return E('tr', { 'class': 'tr' }, [
     E('td', { 'class': 'td' }, [ deviceWho(device) ]),
     E('td', { 'class': 'td' }, [ deviceComputer(device) ]),
     E('td', { 'class': 'td' }, [ deviceState(device) ]),
     E('td', { 'class': 'td' }, [ device.selected_services.map(function(id) { return labels[id] || id; }).join(', ') || '-' ]),
     E('td', { 'class': 'td' }, [
      E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { deviceDialog(device, state, labels, reload, result); } }, [ _('Edit') ]), ' ',
      E('button', { 'class': 'cbi-button cbi-button-negative', 'type': 'button', 'click': function() { removeDialog(device, state, reload, result); } }, [ _('Remove') ]) ])
    ]);
   });
   devices.replaceChildren(state.devices.length ? E('table', { 'class': 'table cbi-section-table' }, [
    E('tr', { 'class': 'tr' }, [ _('Device'), _('Computer'), _('State'), _('Selected services'), _('Actions') ].map(function(text) { return E('th', { 'class': 'th' }, [ text ]); }))
   ].concat(deviceRows)) : E('p', {}, [ _('No devices enrolled.') ]));
  }
  refresh = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() {
   return common.runJob({ button: refresh, result: result,
    busy: _('Updating service lists...'), success: _('Service lists updated.'), failure: _('Could not update service lists.'),
    startPath: helper, startArgs: [ 'client-admin-refresh' ], statusPath: helper, statusArgs: [ 'client-admin-status' ],
    timeout: 330000, onSuccess: reload });
  } }, [ _('Update service lists') ]);
  invite = E('button', { type: 'button', 'class': 'cbi-button cbi-button-action', click: function() { invitationDialog(state, labels, reload); } }, [ _('Create invitation') ]);
  setData(data);
  return E([ common.styles(), E('div', { 'class': 'ikev2-page' }, [
   common.header(_('Remote clients'), _('Publish selected services and assign them to enrolled Windows and macOS devices.')),
   availability, setup,
   (managed.replaceChildren(
    common.section(_('Services for remote clients'), _('Domain lists are shared with Policy Routing and update automatically.'), E('div', {}, [
     services, E('div', { 'class': 'ikev2-actions end' }, [ result.node, refresh ])
    ])),
    common.section(_('Device assignments'), _('Assign published services to each enrolled device.'), E('div', {}, [ devices, E('div', { 'class': 'ikev2-actions end' }, [ invite ]) ]))
   ), managed)
  ]) ]);
 },
 handleSaveApply: null, handleSave: null, handleReset: null
});
