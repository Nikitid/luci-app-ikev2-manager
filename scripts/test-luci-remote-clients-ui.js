'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); };
function nodes(node) { return node && typeof node === 'object' ? [node].concat(...node.children.map(nodes)) : []; }
function text(node) { return typeof node === 'string' ? node : node ? (node.textContent || '') + node.children.map(text).join(' ') : ''; }
function E(tag, attrs, children) {
 if (Array.isArray(tag)) { children = tag; tag = 'div'; attrs = {}; }
 if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
 attrs = attrs || {};
 const node = { tagName: String(tag).toUpperCase(), attrs, children: (children || []).filter(Boolean),
  style: {}, dataset: {}, type: attrs.type || '', value: attrs.value || '', checked: attrs.checked != null,
  disabled: attrs.disabled != null, textContent: '', className: attrs.class || '', listeners: {},
  classList: { add() {}, remove() {}, toggle() {} },
  addEventListener(name, fn) { this.listeners[name] = fn; },
  setAttribute(name, value) { this.attrs[name] = value; }, getAttribute(name) { return this.attrs[name] ?? null; }, removeAttribute(name) { delete this.attrs[name]; },
  replaceChildren(...next) { this.children = next; },
  appendChild(child) { this.children.push(child); },
  querySelectorAll(selector) { return nodes(this).slice(1).filter(n => selector.toUpperCase().split(/,\s*/).includes(n.tagName)); }
 };
 return node;
}
const document = { getElementById() { return true; }, createDocumentFragment() { return E('div'); } };
const window = { setTimeout(fn, delay) { if (!delay) fn(); }, clearTimeout() {} };
const L = { resolveDefault(promise, fallback) { return promise.catch(() => fallback); } };
let modal, hidden = 0, written = [], jobs = [], failWrite = false;
let linkAsked = [], linkKept = true;
const reportAsked = [];
const ui = { showModal(title, body) { modal = E('div', {}, body); }, hideModal() { hidden++; } };
const snapshot = { version: 1, generation: 17, enrollment_generation: 0, api_endpoint: 'https://vpn.example.com:9443/client/v1/enroll', server: {address:"vpn.example.com"},
 services: [{ id: 'example_service', client_access: true, domain_count: 1, transports: [{ protocol: 'tcp', ports: [443] }] }],
 devices: [{ id: 'alice', enabled: true, selected_services: ['example_service'], revision: 3, owner: 'Alice Example', note: 'accounting',
  host: 'ALICE-PC', system: 'Windows 10.0.26100', client: '2.3.0', online: true, tunnel_address: '10.20.0.7', remote_address: '203.0.113.9', connected_seconds: 7300, seen_seconds: 4, seen_from: '203.0.113.9' },
  { id: 'bob-laptop', enabled: true, selected_services: ['example_service'], revision: 1, owner: '', note: '', online: false, seen_seconds: 90000, seen_from: '198.51.100.4' },
  { id: 'spare', enabled: false, selected_services: [], revision: 1, owner: '', note: '', online: false, seen_seconds: null }],
 waiting: [{ id: 'alice-2', owner: 'Alice Example', note: 'accounting', selected_services: ['example_service'], expires_seconds: 7200 }] };
const data = () => [{ code: 0, stdout: JSON.stringify(snapshot) }, { code: 0, stdout: 'example_service|Example service|builtin|0|0|tunnel\nnew_service|New service|builtin|0|0|tunnel\n' }];
const backend = {
 exec(file, args) { if(args[0] === 'client-admin-report-request') { reportAsked.push(args[1]); return Promise.resolve({code:0,stdout:'requested=1\n'}); }
  if(args[0] === 'client-admin-report') return Promise.resolve({code:0,stdout: reportAsked.length ? JSON.stringify({version:1,id:args[1],received_at:1700000000+reportAsked.length,report:{state:'access_closed',faults:['2026-01-01T00:00:00Z policy device_no_services']}}) : '{}\n'});
  if(args[0] === 'client-admin-link') { linkAsked.push(args[1]); return Promise.resolve(linkKept ? {code:0,stdout:JSON.stringify({version:1,invitation:'https://vpn.example.com:9443/client/v1/enroll#'+'d'.repeat(64),expires_seconds:7000,places:1})} : {code:1,stdout:''}); }
  if(args[0] === 'client-admin-take-invitation') return Promise.resolve({code:0,stdout:JSON.stringify({version:1,id:'carol-example',invitation:'https://vpn.example.com:9443/client/v1/enroll#'+'c'.repeat(64)})}); return Promise.resolve(args[0] === 'services' ? data()[1] : data()[0]); },
 write(file, body, mode) { if (failWrite) return Promise.reject(new Error('write rejected')); written.push({ file, body: JSON.parse(body), mode }); return Promise.resolve(); }
};
const extend = { extend(value) { return value; } };
function load(file, common) {
 return new Function('view','baseclass','E','document','window','L','fs','ui','common','_','vpnUsers', fs.readFileSync(file === 'remote-clients.js' && process.env.REMOTE_CLIENTS_VIEW ? process.env.REMOTE_CLIENTS_VIEW : path.join(root,'luci-ikev2-manager',file),'utf8'))(extend,extend,E,document,window,L,backend,ui,common,s=>s,{ load: () => Promise.resolve({ panel: true }), render: () => E('div', {}, [ 'VPN profiles panel' ]) });
}
const common = load('shared.js');
// A person's device limit is stored before their link is made; that job is let through.
common.runJob = options => { jobs.push(options); const last = written[written.length-1];
 if (options.startArgs[0] === 'client-admin-update' && last && last.body.operation === 'set-person-limit') return Promise.resolve(options.onSuccess({state:'ok'})).then(() => ({state:'ok'}));
 return Promise.resolve({state:'ok'}); };
const page = load('remote-clients.js', common);
function button(tree, label) { const result = nodes(tree).find(n => n.tagName === 'BUTTON' && text(n).trim() === label); assert(result, label); return result; }
function click(node) { return node.attrs.click(); }
async function main() {
 const tree = page.render(await page.load());
 assert(text(tree).includes('VPN profiles panel'), 'ordinary VPN profiles are managed on the same page');
 assert(text(tree).includes('Example service')); assert(text(tree).includes('ALICE-PC'), 'a device is shown under the name of its computer');
 // Who is behind each device, what it runs and where it is now.
 for (const shown of ['Alice Example', 'accounting', 'ALICE-PC', 'Windows 10.0.26100 \u00b7 client 2.3.0', 'Online for 2 h, from 203.0.113.9, tunnel address 10.20.0.7',
  'last seen 1 d ago from 198.51.100.4', 'Access off', 'Waiting for registration', 'link valid for 2 h more'])
  assert(text(tree).includes(shown), shown);
 assert(!text(tree).includes('token_sha256'));
 const edits = nodes(tree).filter(n => n.tagName === 'BUTTON' && (text(n).trim() === 'Edit' || n.attrs['aria-label'] === 'Edit'));
 // People come first on the page, then the services.
 click(nodes(tree).find(n => n.tagName === 'BUTTON' && n.attrs['aria-label'] === 'Ports: rarely needed'));
 const save = button(modal,'Save'); assert(save.disabled, 'unchanged service cannot save');
 const inputs = nodes(modal).filter(n => n.tagName === 'INPUT');
 inputs.find(n=>n.type==='checkbox').checked = false;
 const form = nodes(modal).find(n=>n.listeners.change); form.listeners.change();
 assert(!save.disabled, 'changed service must save');
 await click(save);
 assert.deepStrictEqual(written[0].body, {version:1,expected_generation:17,operation:'configure-service',payload:{id:'example_service',client_access:false,transports:[{protocol:'tcp',ports:[443]}]}});
 assert(written[0].file.startsWith('/var/run/ikev2-client-admin-')); assert.strictEqual(written[0].mode,384);
 assert.strictEqual(jobs[0].startArgs[0],'client-admin-update'); assert.deepStrictEqual(jobs[0].statusArgs,['client-admin-status']);
 await jobs[0].onSuccess(); assert.strictEqual(hidden,1);
 // Ports are a rare case behind the gear; a wrong one cannot be staged.
 click(nodes(tree).find(n => n.tagName === 'BUTTON' && n.attrs['aria-label'] === 'Ports: rarely needed'));
 const serviceSave = button(modal,'Save');
 nodes(modal).filter(n=>n.tagName==='INPUT' && n.type==='text')[0].value = '70000';
 nodes(modal).find(n=>n.listeners.change).listeners.change();
 await click(serviceSave);
 assert.strictEqual(written.length,1, 'invalid ports cannot stage a request');
 assert(text(modal).includes('1 to 65535'));
 click(edits[0]);
 const deviceInputs = nodes(modal).filter(n=>n.tagName==='INPUT');
 deviceInputs.find(n=>n.type==='checkbox').checked=false;
 deviceInputs.find(n=>n.attrs['aria-label']==='Who uses it').value='Alice <Example>';
 await click(button(modal,'Save'));
 assert(text(modal).includes('without < and >'), 'markup characters are refused in a description');
 deviceInputs.find(n=>n.attrs['aria-label']==='Who uses it').value='Alice Example';
 // Keep the generation captured when the dialog opened, even if a refresh
 // changes the page's state while the administrator is editing it.
 snapshot.generation = 18;
 await click(button(tree,'Update service lists'));
 await jobs[1].onSuccess();
 await click(button(modal,'Save'));
 assert.strictEqual(written[1].body.expected_generation,17);
 assert.strictEqual(written[1].body.operation,'assign-devices'); assert.deepStrictEqual(written[1].body.payload.ids,['alice']); assert.strictEqual(written[1].body.payload.enabled,false);
 assert.strictEqual(written[1].body.payload.owner,'Alice Example'); assert.strictEqual(written[1].body.payload.note,'accounting');
 assert(!('mode' in written[1].body.payload), 'what goes into the tunnel is decided per device, not here');
 failWrite = true; await click(button(modal,'Save'));
 assert(text(modal).includes('write rejected')); assert.strictEqual(jobs.length,3);
 failWrite = false;
 await click(button(tree,'Update service lists'));
 assert.deepStrictEqual(jobs[3].startArgs,['client-admin-refresh']);
 // Another service is published from the picker with nothing asked: the web's ports.
 await click(button(tree,'Publish'));
 assert.deepStrictEqual(written[written.length-1].body.payload, {id:'new_service',client_access:true,transports:[{protocol:'tcp',ports:[80,443]},{protocol:'udp',ports:[443]}]});
 click(button(tree,'Add person'));
 const invitationCreate = button(modal,'Create invitation');
 await click(invitationCreate);
 assert(text(modal).includes('Enter the name of the person.'), 'a link is for a person');
 const invitationInputs = nodes(modal).filter(n=>n.tagName==='INPUT');
 assert(!invitationInputs.some(n=>n.attrs['aria-label']==='Device identifier'), 'the identifier is never asked for');
 invitationInputs.find(n=>n.type==='checkbox').checked=true;
 invitationInputs.find(n=>n.attrs['aria-label']==='Who uses it').value='Carol Example';
 await click(invitationCreate);
 // How many devices she may have is her own setting, stored first; the link is for the free places.
 assert.deepStrictEqual(written[written.length-2].body.operation === 'set-person-limit' && written[written.length-2].body.payload, {owner:'Carol Example',limit:2});
 assert.strictEqual(written[written.length-1].body.id,'carol-example', 'the identifier is made from the name');
 assert.strictEqual(written[written.length-1].body.count,2);
 const invitationJob = jobs[jobs.length-1];
 assert.strictEqual(invitationJob.startArgs[0],'client-admin-invite');
 assert.strictEqual(written[written.length-1].body.expected_generation,0);
 assert.strictEqual(written[written.length-1].body.endpoint,snapshot.api_endpoint);
 assert.deepStrictEqual(written[written.length-1].body.selected_services,['example_service']);
 assert.strictEqual(written[written.length-1].body.owner,'Carol Example'); assert.strictEqual(written[written.length-1].body.note,'');
 assert.strictEqual(written[written.length-1].body.mode,'services', 'a new device starts with its services alone unless said otherwise');
 assert.strictEqual(written[written.length-1].body.lifetime_seconds,86400);
 assert(!JSON.stringify(written).includes('cccccccc'), 'no invitation secret in request inbox');
 await invitationJob.onSuccess({action_id:'123-456'});
 const linkField=nodes(modal).find(n=>n.tagName==='TEXTAREA');
 assert(linkField && linkField.value.endsWith('#'+'c'.repeat(64)));
 assert(!JSON.stringify(jobs.map(j=>j.success)).includes('cccccccc'), 'no invitation secret in job status');
 click(button(modal,'Close')); assert.strictEqual(linkField.value,'');
 // Links that still wait are listed with their person, places and time, and one is withdrawn whole.
 assert(text(tree).includes('Active links: 1') && text(tree).includes('Places left'), 'links out are accounted for');
 // A waiting link is shown again on request, for the place it holds open; one
 // the router no longer keeps is said to be gone, and nothing is shown.
 modal = null;
 await click(button(tree,'Show')); await Promise.resolve(); await Promise.resolve();
 assert.deepStrictEqual(linkAsked, ['alice-2']);
 assert(modal && nodes(modal).find(n => n.tagName === 'TEXTAREA').value.endsWith('#'+'d'.repeat(64)), 'the kept link is shown again');
 modal = null; linkKept = false;
 await click(button(tree,'Show')); await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
 assert(modal === null && text(tree).includes('no longer keeps this link'), 'a link that is not kept is not shown, and the row says why');
 await click(button(tree,'Revoke'));
 assert.deepStrictEqual({operation: written[written.length-1].body.operation, payload: written[written.length-1].body.payload}, {operation:'close-places', payload:{ids:['alice-2']}});
 // A person who still has a link out: the new link replaces it, covers the
 // places left under her own limit, and takes an identifier nothing used.
 snapshot.person_limits = { 'Alice Example': 3 };
 const again = page.render(await page.load());
 click(nodes(again).find(n => n.tagName === 'BUTTON' && n.attrs['aria-label'] === 'New Waypoint link in place of the one given'));
 assert(text(modal).includes('Registered: 1.') && text(modal).includes('The link will register 2 more.') && text(modal).includes('stops working'), 'the dialog says what the link covers and what happens to the old one');
 const before2 = written.length;
 await click(button(modal,'Create invitation'));
 assert.strictEqual(written.length, before2 + 1, 'an unchanged limit is not stored again');
 const relink = written[written.length-1].body;
 assert.deepStrictEqual([relink.cancel, relink.count, relink.owner], [['alice-2'], 2, 'Alice Example']);
 assert(!['alice','alice-1','alice-2'].includes(relink.id) && /^[a-z][a-z0-9-]*$/.test(relink.id), 'a used identifier is never offered: ' + relink.id);
 delete snapshot.person_limits;
 const removes = nodes(tree).filter(n => n.tagName === 'BUTTON' && n.attrs['aria-label'] === 'Remove');
 assert.strictEqual(removes.length, 5, 'four devices and places, and the published service');
 // A free place is closed, not removed as a device.
 click(removes[1]);
 await click(button(modal,'Remove'));
 assert.deepStrictEqual({operation: written[written.length-1].body.operation, payload: written[written.length-1].body.payload}, {operation:'close-place', payload:{id:'alice-2'}});
 click(removes[2]);
 assert(text(modal).includes('cannot be used again'));
 await click(button(modal,'Remove'));
 assert.deepStrictEqual({operation: written[written.length-1].body.operation, payload: written[written.length-1].body.payload}, {operation:'remove-device', payload:{id:'bob-laptop'}});
 // Everything into the tunnel is not offered until a lost tunnel can hold such a device back.
 assert(!text(tree).includes('Everything into the tunnel') && !nodes(tree).some(n => n.attrs && n.attrs['aria-label'] === 'Everything into the tunnel'), 'the full-tunnel mode is not offered');
 snapshot.devices[0].mode = 'full';
 const withFull = page.render(await page.load());
 assert(nodes(withFull).some(n => n.tagName === 'BUTTON' && /Selected services|Everything into the tunnel/.test(n.attrs['aria-label'] || n.attrs.title || '')), 'a device that already sends everything can be brought back');
 delete snapshot.devices[0].mode;
 // Diagnostics: the device is asked by its identifier, and what it sent is shown as it came.
 const gears = nodes(tree).filter(n => n.tagName === 'BUTTON' && n.attrs['aria-label'] === 'Device: name and services');
 assert(gears.length >= 1, 'a device has its own settings');
 click(gears[0]);
 click(button(modal,'Diagnostics...'));
 await new Promise(resolve => setImmediate(resolve));
 const reportField = nodes(modal).find(n => n.tagName === 'TEXTAREA');
 assert.strictEqual(reportField.value || '', '', 'nothing is shown before a report came');
 assert(button(modal,'Copy').disabled && button(modal,'Save to file').disabled && text(modal).includes('No report from this device yet.'));
 const realTimeout = window.setTimeout; window.setTimeout = (run) => { setImmediate(run); return 1; };
 await click(button(modal,'Request report'));
 window.setTimeout = realTimeout;
 assert.deepStrictEqual(reportAsked, ['alice']);
 assert(reportField.value.includes('device_no_services') && reportField.value.includes('access_closed') && !button(modal,'Copy').disabled);
 const unavailable = page.render([[{code:1,stdout:''},data()[1]], null]);
 assert(button(unavailable,'Update service lists').disabled); assert(!nodes(unavailable).some(n=>n.tagName==='INPUT' && n.attrs.type !== 'search'), 'nothing to edit while the state is unavailable');
 // First activation: only the setup section is offered, and it stages one request.
 const fresh = { version: 1, initialized: false, enabled: false, port: 8443, server_enabled: true, server_identity: 'vpn.example.com', tunnels: ['1', '2'] };
 const first = page.render([[{code:1,stdout:''},data()[1],{code:0,stdout:JSON.stringify(fresh)}], null]);
 assert(nodes(first).some(n => n.style.display === 'none' && text(n).includes('Services for Waypoint')), 'management hidden before setup');
 assert(!text(first).includes('Client configuration is unavailable'));
 const setupInputs = nodes(first).filter(n => n.tagName === 'INPUT');
 const portInput = setupInputs.find(n => n.attrs['aria-label'] === 'Registration port');
 assert.strictEqual(nodes(first).find(n => n.tagName === 'SELECT').children.length, 4, 'each tunnel offers a failover and a bound exit');
 portInput.value = '80'; const before = written.length;
 await click(button(first,'Set up remote clients'));
 assert.strictEqual(written.length, before, 'a privileged port cannot be staged'); assert(text(first).includes('1024 to 65535'));
 portInput.value = '9443'; setupInputs.find(n => n.type === 'checkbox').checked = true;
 nodes(first).find(n => n.tagName === 'SELECT').value = '2s';
 await click(button(first,'Set up remote clients'));
 assert.deepStrictEqual(written[written.length-1].body, {version:1,enabled:true,port:9443,virtual_subnet:'172.31.240.0/20',exit:'2s'});
 assert.deepStrictEqual(jobs[jobs.length-1].startArgs.slice(0,1), ['client-admin-setup']);
 const blocked = page.render([[{code:1,stdout:''},data()[1],{code:0,stdout:JSON.stringify(Object.assign({}, fresh, {server_identity:null, tunnels:[]}))}], null]);
 assert(button(blocked,'Set up remote clients').attrs.disabled != null, 'setup needs the inbound server and a tunnel');
 const custom = page.render([[data()[0],data()[1],{code:0,stdout:JSON.stringify(Object.assign({}, fresh, {initialized:true, custom_server:true}))}], null]);
 assert(text(custom).includes('ikev2-in-managed'), 'an administrator with an own server configuration is told what to add');
 const running = page.render([[data()[0],data()[1],{code:0,stdout:JSON.stringify(Object.assign({}, fresh, {initialized:true, enabled:true, virtual_subnet:'10.99.0.0/24', exit:'1'}))}], null]);
 assert(nodes(running).find(n => n.attrs['aria-label'] === 'Virtual subnet').attrs.disabled != null, 'the subnet of enrolled devices is fixed');
 assert(text(running).includes('ALICE-PC') && text(running).includes('https://vpn.example.com:8443'));
 console.log('remote clients UI: render, forms, validation, queued requests, generations, setup and unavailable state OK');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
