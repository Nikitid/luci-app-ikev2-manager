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
  disabled: false, textContent: '', className: attrs.class || '', listeners: {},
  classList: { add() {}, remove() {}, toggle() {} },
  addEventListener(name, fn) { this.listeners[name] = fn; },
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
const ui = { showModal(title, body) { modal = E('div', {}, body); }, hideModal() { hidden++; } };
const snapshot = { version: 1, generation: 17, enrollment_generation: 0, api_endpoint: 'https://vpn.example.com:9443/client/v1/enroll', server: {address:"vpn.example.com"},
 services: [{ id: 'example_service', client_access: true, domain_count: 1, transports: [{ protocol: 'tcp', ports: [443] }] }],
 devices: [{ id: 'alice', enabled: true, selected_services: ['example_service'], revision: 3 }] };
const data = () => [{ code: 0, stdout: JSON.stringify(snapshot) }, { code: 0, stdout: 'example_service|Example service|builtin|0|0|tunnel\nnew_service|New service|builtin|0|0|tunnel\n' }];
const backend = {
 exec(file, args) { if(args[0] === 'client-admin-take-invitation') return Promise.resolve({code:0,stdout:JSON.stringify({version:1,id:'new-laptop',invitation:'https://vpn.example.com:9443/client/v1/enroll#'+'c'.repeat(64)})}); return Promise.resolve(args[0] === 'services' ? data()[1] : data()[0]); },
 write(file, body, mode) { if (failWrite) return Promise.reject(new Error('write rejected')); written.push({ file, body: JSON.parse(body), mode }); return Promise.resolve(); }
};
const extend = { extend(value) { return value; } };
function load(file, common) {
 return new Function('view','baseclass','E','document','window','L','fs','ui','common','_', fs.readFileSync(file === 'remote-clients.js' && process.env.REMOTE_CLIENTS_VIEW ? process.env.REMOTE_CLIENTS_VIEW : path.join(root,'luci-ikev2-manager',file),'utf8'))(extend,extend,E,document,window,L,backend,ui,common,s=>s);
}
const common = load('shared.js');
common.runJob = options => { jobs.push(options); return Promise.resolve({state:'ok'}); };
const page = load('remote-clients.js', common);
function button(tree, label) { const result = nodes(tree).find(n => n.tagName === 'BUTTON' && text(n).trim() === label); assert(result, label); return result; }
function click(node) { return node.attrs.click(); }
async function main() {
 const tree = page.render(await page.load());
 assert(text(tree).includes('Example service')); assert(text(tree).includes('alice'));
 assert(!text(tree).includes('token_sha256'));
 const edits = nodes(tree).filter(n => n.tagName === 'BUTTON' && text(n).trim() === 'Edit');
 click(edits[0]);
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
 click(edits[1]);
 const serviceSave = button(modal,'Save');
 nodes(modal).filter(n=>n.tagName==='INPUT' && n.type==='text')[0].value = '70000';
 await click(serviceSave);
 assert.strictEqual(written.length,1, 'invalid ports cannot stage a request');
 assert(text(modal).includes('1 to 65535'));
 click(edits[2]);
 const deviceInputs = nodes(modal).filter(n=>n.tagName==='INPUT');
 deviceInputs[0].checked=false;
 // Keep the generation captured when the dialog opened, even if a refresh
 // changes the page's state while the administrator is editing it.
 snapshot.generation = 18;
 await click(button(tree,'Update service lists'));
 await jobs[1].onSuccess();
 await click(button(modal,'Save'));
 assert.strictEqual(written[1].body.expected_generation,17);
 assert.strictEqual(written[1].body.operation,'assign-device'); assert.strictEqual(written[1].body.payload.enabled,false);
 failWrite = true; await click(button(modal,'Save'));
 assert(text(modal).includes('write rejected')); assert.strictEqual(jobs.length,3);
 failWrite = false;
 await click(button(tree,'Update service lists'));
 assert.deepStrictEqual(jobs[3].startArgs,['client-admin-refresh']);
 click(button(tree,'Create invitation'));
 const invitationCreate = button(modal,'Create invitation');
 await click(invitationCreate);
 assert(text(modal).includes('select at least one service'));
 const invitationInputs = nodes(modal).filter(n=>n.tagName==='INPUT');
 invitationInputs.find(n=>n.attrs['aria-label']==='Device identifier').value='new-laptop';
 invitationInputs.find(n=>n.type==='checkbox').checked=true;
 await click(invitationCreate);
 const invitationJob = jobs[jobs.length-1];
 assert.strictEqual(invitationJob.startArgs[0],'client-admin-invite');
 assert.strictEqual(written[written.length-1].body.expected_generation,0);
 assert.strictEqual(written[written.length-1].body.endpoint,snapshot.api_endpoint);
 assert.deepStrictEqual(written[written.length-1].body.selected_services,['example_service']);
 assert(!JSON.stringify(written).includes('cccccccc'), 'no invitation secret in request inbox');
 await invitationJob.onSuccess({action_id:'123-456'});
 const linkField=nodes(modal).find(n=>n.tagName==='TEXTAREA');
 assert(linkField && linkField.value.endsWith('#'+'c'.repeat(64)));
 assert(!JSON.stringify(jobs.map(j=>j.success)).includes('cccccccc'), 'no invitation secret in job status');
 click(button(modal,'Close')); assert.strictEqual(linkField.value,'');
 const unavailable = page.render([{code:1,stdout:''},data()[1]]);
 assert(button(unavailable,'Update service lists').disabled); assert(!nodes(unavailable).some(n=>n.tagName==='INPUT'));
 console.log('remote clients UI: render, forms, validation, queued requests, generations and unavailable state OK');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
