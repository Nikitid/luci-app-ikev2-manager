'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared-v14 as common';

var helper = '/usr/libexec/ikev2-client-admin';
var catalogHelper = '/usr/libexec/ikev2-domains-community';

function readState() {
 return Promise.all([
  fs.exec(helper, [ 'client-admin-show' ]),
  L.resolveDefault(fs.exec(catalogHelper, [ 'services' ]), { code: 1, stdout: '' })
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

function deviceDialog(device, state, labels, reload, pageResult) {
 var enabled = E('input', { 'type': 'checkbox', 'checked': device.enabled ? '' : null, 'aria-label': _('Device access enabled') });
 var choices = state.services.filter(function(service) { return service.client_access; }).map(function(service) {
  return { id: service.id, input: E('input', { 'type': 'checkbox', 'checked': device.selected_services.indexOf(service.id) >= 0 ? '' : null, 'aria-label': labels[service.id] || service.id }) };
 });
 var form = E('div', {}, [
  common.toggleRow(enabled, _('Device access enabled')),
  E('div', {}, choices.map(function(choice) { return common.toggleRow(choice.input, labels[choice.id] || choice.id); }))
 ]);
 editDialog(device.id, form, function() {
  return { version: 1, expected_generation: state.generation, operation: 'assign-device',
   payload: { id: device.id, enabled: enabled.checked, selected_services: choices.filter(function(c) { return c.input.checked; }).map(function(c) { return c.id; }) } };
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
 var form = E('div', {}, [
  common.fieldLabel(_('Device identifier')), id,
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
  var token = common.inputToken(), request = { version: 1, expected_generation: generation,
   endpoint: endpoint.value, id: id.value, selected_services: selected, lifetime_seconds: 600 };
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
  var result = common.inlineResult(), availability = E('div', {}), refresh, invite;
  function reload() { return readState().then(setData); }
  function setData(next) {
   state = null;
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
     E('td', { 'class': 'td' }, [ device.id ]),
     E('td', { 'class': 'td' }, [ device.enabled && device.selected_services.length ? _('Enabled') : _('No access') ]),
     E('td', { 'class': 'td' }, [ device.selected_services.map(function(id) { return labels[id] || id; }).join(', ') || '-' ]),
     E('td', { 'class': 'td' }, [ String(device.revision) ]),
     E('td', { 'class': 'td' }, [ E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { deviceDialog(device, state, labels, reload, result); } }, [ _('Edit') ]) ])
    ]);
   });
   devices.replaceChildren(state.devices.length ? E('table', { 'class': 'table cbi-section-table' }, [
    E('tr', { 'class': 'tr' }, [ _('Device'), _('Access'), _('Selected services'), _('Revision'), _('Actions') ].map(function(text) { return E('th', { 'class': 'th' }, [ text ]); }))
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
   availability,
   common.section(_('Services for remote clients'), _('Domain lists are shared with Policy Routing and update automatically.'), E('div', {}, [
    services, E('div', { 'class': 'ikev2-actions end' }, [ result.node, refresh ])
   ])),
   common.section(_('Device assignments'), _('Assign published services to each enrolled device.'), E('div', {}, [ devices, E('div', { 'class': 'ikev2-actions end' }, [ invite ]) ]))
  ]) ]);
 },
 handleSaveApply: null, handleSave: null, handleReset: null
});
