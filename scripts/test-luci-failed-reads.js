'use strict';

// Renders the pages against a stubbed LuCI with failing reads. A read that failed
// is not an empty setting: the page says what it could not read, offers no save
// over it, and shows no state it does not know.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');

String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%[sd]/g, () => String(args[i++]));
};

class Node {
	constructor(tag) {
		this.tagName = String(tag).toUpperCase();
		this.childNodes = [];
		this.attributes = {};
		this.dataset = {};
		this.style = {};
		this.listeners = {};
		this.disabled = false;
		this.checked = false;
		this.value = '';
		this.className = '';
		this.id = '';
		this.offsetWidth = 0;
		this.parentNode = null;
		this.nodeType = 1;
		this.classList = {
			add: (...names) => { names.forEach(n => this.classList.set.add(n)); },
			remove: (...names) => { names.forEach(n => this.classList.set.delete(n)); },
			toggle: (name, on) => {
				if (on === undefined ? !this.classList.set.has(name) : on) this.classList.set.add(name);
				else this.classList.set.delete(name);
			},
			contains: name => this.classList.set.has(name),
			set: new Set()
		};
	}
	get children() { return this.childNodes.filter(n => n instanceof Node); }
	get firstChild() { return this.childNodes[0] || null; }
	get options() { return this.children.filter(n => n.tagName === 'OPTION'); }
	appendChild(child) {
		if (child instanceof Node && child.tagName === '#FRAGMENT') {
			child.childNodes.forEach(c => this.appendChild(c));
			child.childNodes = [];
			return child;
		}
		if (child instanceof Node) child.parentNode = this;
		this.childNodes.push(child);
		return child;
	}
	append(...nodes) { nodes.forEach(n => this.appendChild(n)); }
	insertBefore(child, ref) {
		const at = this.childNodes.indexOf(ref);
		if (child instanceof Node) child.parentNode = this;
		if (at < 0) this.childNodes.push(child); else this.childNodes.splice(at, 0, child);
		return child;
	}
	removeChild(child) {
		this.childNodes.splice(this.childNodes.indexOf(child), 1);
		return child;
	}
	remove() { if (this.parentNode) this.parentNode.removeChild(this); }
	replaceChildren(...nodes) {
		this.childNodes = [];
		nodes.forEach(n => { if (n != null) this.appendChild(typeof n === 'object' ? n : String(n)); });
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
		if (name === 'id') this.id = String(value);
		if (name === 'class') this.className = String(value);
	}
	getAttribute(name) { return name in this.attributes ? this.attributes[name] : null; }
	hasAttribute(name) { return name in this.attributes; }
	removeAttribute(name) { delete this.attributes[name]; }
	addEventListener(name, handler) { (this.listeners[name] = this.listeners[name] || []).push(handler); }
	removeEventListener() {}
	dispatch(name) {
		let result;
		for (let node = this; node; node = node.parentNode)
			(node.listeners[name] || []).forEach(h => { const r = h.call(node, { type: name, target: this, preventDefault() {}, stopPropagation() {} }); if (node === this) result = r; });
		return result;
	}
	click() { return this.dispatch('click'); }
	focus() {}
	blur() {}
	closest() { return null; }
	contains(node) { for (; node; node = node.parentNode) if (node === this) return true; return false; }
	getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; }
	get textContent() {
		return this.childNodes.map(n => typeof n === 'string' ? n : n.textContent).join('');
	}
	set textContent(value) { this.childNodes = [ String(value) ]; }
	get innerHTML() { return this.textContent; }
	set innerHTML(value) { this.childNodes = value ? [ String(value) ] : []; }
	all() { return [ this ].concat(...this.children.map(c => c.all())); }
	querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
	querySelectorAll(selector) {
		const matches = selector.split(/\s*,\s*/).map(one => {
			const id = /^#([\w-]+)$/.exec(one);
			const cls = /^\.([\w-]+)$/.exec(one);
			return n => id ? n.id === id[1] : cls ? n.className.split(/\s+/).includes(cls[1]) : n.tagName === one.toUpperCase();
		});
		return this.all().slice(1).filter(n => matches.some(match => match(n)));
	}
}

let page = null;
const document = {
	head: new Node('head'),
	documentElement: new Node('html'),
	createElement: tag => new Node(tag),
	createDocumentFragment: () => new Node('#fragment'),
	createTextNode: text => String(text),
	createElementNS: (ns, tag) => new Node(tag),
	getElementById: id => page ? page.querySelector('#' + id) : null,
	querySelector: selector => page ? page.querySelector(selector) : null,
	querySelectorAll: selector => page ? page.querySelectorAll(selector) : []
};

// LuCI's E(): an array is a fragment, attributes that are functions are
// listeners, everything else is set as an attribute.
function E(tag, attrs, children) {
	if (Array.isArray(tag)) {
		const fragment = new Node('#fragment');
		tag.forEach(c => { if (c != null) fragment.appendChild(c); });
		return fragment;
	}
	if (tag instanceof Node) return tag;
	if (typeof tag === 'string' && tag.charAt(0) === '<')
		return new Node('svg');
	if (Array.isArray(attrs) || typeof attrs !== 'object' || attrs === null) {
		children = attrs;
		attrs = {};
	}
	const node = new Node(tag);
	Object.keys(attrs).forEach(name => {
		const value = attrs[name];
		if (value == null) return;
		if (typeof value === 'function') node.addEventListener(name, value);
		else if (name === 'value') node.value = String(value);
		else if (name === 'type') { node.type = String(value); node.setAttribute(name, value); }
		else if (name === 'checked') { node.checked = true; node.setAttribute(name, value); }
		else if (name === 'disabled') { node.disabled = true; node.setAttribute(name, value); }
		else node.setAttribute(name, value);
	});
	[].concat(children == null ? [] : children).forEach(c => {
		if (c == null) return;
		node.appendChild(typeof c === 'object' ? c : String(c));
	});
	return node;
}

const timers = [];
const window = {
	setTimeout(fn, delay) { timers.push(fn); return timers.length; },
	clearTimeout() {},
	requestAnimationFrame(fn) { fn(); },
	confirm: () => true,
	getComputedStyle: () => ({ backgroundColor: '' }),
	matchMedia: () => ({ matches: false, addEventListener() {} }),
	localStorage: null,
	location: { reload() {} }
};
function flushTimers() {
	while (timers.length) timers.shift()();
}

globalThis._ = s => s;

// Router state the page reads, and everything it writes.
let written = [];
const files = {};
const helpers = {};
const fsStub = {
	read(file) {
		return file in files ? Promise.resolve(files[file]) :
			Promise.reject(Object.assign(new Error('Resource not found'), { name: 'NotFoundError' }));
	},
	exec(command, args) {
		const key = path.basename(command) + ' ' + args.join(' ');
		const answer = helpers[key] || helpers[path.basename(command) + ' ' + args[0]];
		return Promise.resolve(answer || { code: 0, stdout: '' });
	},
	write(file, data) {
		written.push({ file, data });
		return Promise.resolve();
	},
	stat: () => Promise.resolve({})
};
const L = {
	resolveDefault(promise, fallback) { return promise.catch(() => fallback); },
	url: (...parts) => '/cgi-bin/luci/' + parts.join('/'),
	Poll: { add() {}, remove() {} }
};

function load(dir, file, common) {
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'view', 'poll', 'common', 'navigator' ];
	const values = [ window, document, L, { extend: o => o }, E, fsStub,
		{ showModal() {}, hideModal() {}, addNotification() {} }, { extend: o => o },
		{ add() {}, remove() {} }, common, {} ];
	return new Function(names.join(','), fs.readFileSync(path.join(root, dir, file), 'utf8')).apply(null, values);
}

const common = load('luci-ikev2-manager', 'shared.js');
const view = load('luci-ikev2-domains', 'editor.js', common);
// The inbound server and the outbound tunnels are panels the Tunnels and DNS
// pages are built from: what a page shows of them is their parts.
const serverPage = panel => ({ loadData: () => panel.load(), renderData: data => E('div', {}, panel.parts(data).server) });
const clientPage = panel => ({ loadData: () => panel.load(), renderData: data => {
	const parts = panel.parts(data);
	const tree = E('div', {}, [ parts.pill ].concat(parts.tunnel, [ parts.dnsNote ], parts.dns));
	tree.parts = parts;
	return tree;
} });
const server = serverPage(load('luci-ikev2-manager', 'settings.js', common));
const setup = load('luci-ikev2-manager', 'setup.js', common);
const client = clientPage(load('luci-ikev2-manager', 'client.js', common));

// Two tunnels; one service sent through the second, one kept on it alone.
function healthyRouter() {
	Object.keys(files).forEach(k => delete files[k]);
	Object.keys(helpers).forEach(k => delete helpers[k]);
	files['/etc/pbr-ikev2-domains.manual.txt'] = 'chat.example.test\n';
	files['/etc/pbr-ikev2-community-selected.txt'] = 'example_ai\nexample_chat\n';
	files['/etc/pbr-ikev2-exits.txt'] = 'example_ai 2s\nexample_chat 2\n';
	helpers['ikev2-domains-community services'] = { code: 0, stdout:
		'example_ai|Example AI|builtin|0|0|tunnel\nexample_chat|Example chat|builtin|0|0|tunnel\n' };
	helpers['ikev2-manager tunnels-get'] = { code: 0, stdout: 'tunnel=2\nname=Second exit\nenabled=1\n' };
	helpers['ikev2-manager tunnels-status'] = { code: 0, stdout: 'tunnel=1 up=1\ntunnel=2 up=1\n' };
	helpers['ikev2-domains-community schedule'] = { code: 0, stdout: 'action_id=1-1\n' };
}

async function open() {
	written = [];
	const data = await view.loadData();
	page = view.renderData(data);
	flushTimers();
	return page;
}

function saveButton(tree) {
	const button = tree.querySelectorAll('button').find(b => b.textContent.trim() === 'Save');
	assert(button, 'the page has a Save button');
	return button;
}

// The user adds a domain and presses Save.
async function editAndSave(tree) {
	const list = tree.querySelector('#ikev2-domain-list');
	list.value += 'more.example.test\n';
	list.dispatch('input');
	flushTimers();
	const save = saveButton(tree);
	if (!save.disabled) {
		save.click();
		for (let i = 0; i < 20; i++) { await Promise.resolve(); flushTimers(); }
	}
	return save;
}

const button = (tree, label) => tree.querySelectorAll('button').find(b => b.textContent.trim() === label);
const pills = tree => tree.querySelectorAll('.ikev2-pill').map(p => p.textContent.trim());
const change = (tree, node) => { node.checked = !node.checked; node.dispatch('change'); flushTimers(); };

// A page opens before its data: the shell has the title and a placeholder at
// once, whatever the helpers take.
async function shellOpensAtOnce() {
	let release;
	const slow = common.shell('Slow page', 'About it', {
		loadData: () => new Promise(resolve => { release = resolve; }),
		renderData: data => E('div', { 'class': 'arrived' }, [ data ])
	});
	await slow.load();
	const root = slow.render();
	await Promise.resolve();
	assert(root.textContent.includes('Slow page'), 'the title waits for the data');
	assert(root.querySelector('.ikev2-skeleton'), 'there is no placeholder for the data');
	release('the data');
	for (let i = 0; i < 5; i++) await Promise.resolve();
	assert(root.querySelector('.arrived'), 'the data did not replace the placeholder');
	assert(!root.querySelector('.ikev2-skeleton'), 'the placeholder stayed');
	const broken = common.shell('Broken', '', { loadData: () => Promise.reject(new Error('no route')), renderData: () => null });
	const failed = broken.render();
	for (let i = 0; i < 5; i++) await Promise.resolve();
	assert(/could not be loaded: no route/.test(failed.textContent), 'a failed load says so');
}

async function pages() {
	// A helper's refusal reads in the page's language and without the tool's noise.
	const catalog = { 'Invalid IPv4 pool': 'Неверный пул IPv4', "WAN network '%s' does not exist": 'Сети WAN «%s» нет',
		'Server certificate not found: %s': 'Сертификат не найден: %s', 'Unable to save ACME settings': 'Не сохранить ACME',
		'previous configuration restored': 'прежняя восстановлена' };
	const plain = globalThis._;
	globalThis._ = text => catalog[text] || text;
	assert.strictEqual(common.helperText('Invalid IPv4 pool'), 'Неверный пул IPv4');
	assert.strictEqual(common.helperText("WAN network 'wan2' does not exist"), 'Сети WAN «wan2» нет');
	assert.strictEqual(common.helperText('Server certificate not found: /etc/a.crt'), 'Сертификат не найден: /etc/a.crt');
	assert.strictEqual(common.helperText('Unable to save ACME settings; previous configuration restored'), 'Не сохранить ACME; прежняя восстановлена');
	assert.strictEqual(common.helperText('Something new'), 'Something new');
	helpers['ikev2-manager noisy'] = { code: 1, stdout: '', stderr: '/sbin/uci: Entry not found\nInvalid IPv4 pool\n' };
	const reason = await common.execChecked('/usr/libexec/ikev2-manager', [ 'noisy' ]).then(() => null, error => error.message);
	assert.strictEqual(reason, 'Неверный пул IPv4', 'the tool line is dropped, the message translated');
	globalThis._ = plain;
	delete helpers['ikev2-manager noisy'];
	assert.strictEqual(common.serviceLabel('anthropic_ai'), 'Anthropic');
	assert.strictEqual(common.serviceLabel('huggingface'), 'Hugging Face');

	const failed = { code: 1, stdout: '' };
	// Inbound server: nothing about it could be read.
	const swanmon = name => name === '/usr/sbin/swanmon';
	fsStub.stat = () => Promise.resolve({});
	for (const key of Object.keys(helpers)) delete helpers[key];
	[ 'server-get', 'server-access-get', 'advanced-mode', 'advanced-read', 'acme-get' ].forEach(k => { helpers['ikev2-manager ' + k] = failed; });
	let tree = page = server.renderData(await server.loadData());
	flushTimers();
	assert(/Could not be read: server settings, certificate settings/.test(tree.textContent), 'server: says what could not be read');
	assert(pills(tree).includes('Unavailable'), 'server: no Disabled or No certificate for what is unknown');
	assert(!pills(tree).includes('Disabled'), 'server: not called disabled');
	change(tree, tree.querySelector('input'));
	assert(button(tree, 'Save server').disabled, 'server: Save stays off');
	assert(button(tree, 'Save ACME settings').disabled, 'server: Save ACME stays off');
	assert(button(tree, 'Request certificate').disabled, 'server: Request certificate stays off');

	// A refused Save keeps what was typed.
	helpers['ikev2-manager server-get'] = { code: 0, stdout: 'enabled=1\nidentity=vpn.example.test\npool4=10.20.30.10-10.20.30.100\ngateway4=10.20.30.1/24\ndns4=10.20.30.1\ndpd=30\nike_rekey=14400\nchild_rekey=3600\nmtu=1400\nmobike=1\nfragmentation=1\n' };
	helpers['ikev2-manager server-access-get'] = { code: 0, stdout: 'local_ts=0.0.0.0/0\nallow_internet=1\nallow_lan=1\nallow_router=0\nlan_zones=lan\nfirewall_zone=ikev2in\noutbound_zone=ikev2out\n' };
	helpers['ikev2-manager acme-get'] = { code: 0, stdout: 'cert_present=0\n' };
	helpers['ikev2-manager advanced-mode'] = { code: 0, stdout: '0\n' };
	helpers['ikev2-manager advanced-read'] = { code: 0, stdout: '' };
	helpers['ikev2-manager server-input'] = { code: 1, stdout: '', stderr: 'Invalid IPv4 pool' };
	tree = page = server.renderData(await server.loadData());
	flushTimers();
	assert(!/Could not be read/.test(tree.textContent), 'server: a healthy page has no note');
	const toggle = tree.querySelector('input');
	change(tree, toggle);
	const save = button(tree, 'Save server');
	assert(!save.disabled, 'server: a change can be saved');
	const typed = toggle.checked;
	save.click();
	for (let i = 0; i < 30; i++) { await Promise.resolve(); flushTimers(); }
	assert.strictEqual(toggle.checked, typed, 'server: a refusal keeps what was typed');
	assert(!save.disabled, 'server: the refused change can be corrected and saved again');

	// Overview: an unreadable router is not an unconfigured one.
	for (const key of Object.keys(helpers)) delete helpers[key];
	helpers['ikev2-manager-system get'] = failed;
	helpers['ikev2-devices dump'] = failed;
	tree = page = setup.renderData(await setup.loadData());
	flushTimers();
	assert(/Could not be read: router settings, device rules/.test(tree.textContent), 'setup: says what could not be read');
	assert(!pills(tree).includes('Not configured'), 'setup: not called unconfigured');
	assert(!pills(tree).includes('Routing active') && !pills(tree).includes('Not paused'), 'setup: no routing state it does not know');
	assert(!/No device rules/.test(tree.textContent), 'setup: an unread list is not an empty one');
	assert(button(tree, 'Apply router settings').disabled, 'setup: Apply stays off');
	// A readable router says only whether routing is paused.
	helpers['ikev2-manager-system get'] = { code: 0, stdout: 'configured=1\nrouting_paused=0\nwan_interface=wan\n' };
	helpers['ikev2-devices dump'] = { code: 0, stdout: '' };
	tree = page = setup.renderData(await setup.loadData());
	flushTimers();
	assert(pills(tree).includes('Not paused') && !pills(tree).includes('Routing active'), 'setup: the pause state is not called routing');

	// Outbound tunnel.
	for (const key of Object.keys(helpers)) delete helpers[key];
	[ 'ikev2-manager client-get', 'ikev2-manager tunnels-get', 'ikev2-manager-system dns-get', 'ikev2-manager-system dns-segments-get', 'swanmon list-sas' ]
		.forEach(k => { helpers[k] = failed; });
	assert(swanmon('/usr/sbin/swanmon'));
	tree = page = client.renderData(await client.loadData());
	flushTimers();
	assert(/Could not be read: tunnel settings, more tunnels\./.test(tree.textContent), 'client: the tunnels say what could not be read');
	assert(/Could not be read: DNS settings, DNS segments\./.test(tree.textContent), 'client: the DNS says what could not be read');
	assert(!pills(tree).includes('Disconnected'), 'client: not called disconnected');
	assert(!/Only the main tunnel is configured|No DNS segments configured/.test(tree.textContent), 'client: unread lists are not empty ones');
	const tabsBefore = tree.parts.tunnels.panels().length + tree.parts.segments.panels().length;
	tree.parts.tunnels.add(); tree.parts.segments.add();
	assert.strictEqual(tree.parts.tunnels.panels().length + tree.parts.segments.panels().length, tabsBefore,
		'client: nothing is added to what is unknown');

	// Saving one tunnel keeps what is being written in another.
	for (const key of Object.keys(helpers)) delete helpers[key];
	helpers['ikev2-manager client-get'] = { code: 0, stdout: 'enabled=1\ndpd=30\nmtu=1400\n' };
	helpers['ikev2-manager tunnels-get'] = { code: 0, stdout: 'tunnel=2\nname=Second\nenabled=1\nremote_address=a.example.test\nremote_id=a.example.test\nusername=u\ndpd=30\nmtu=1400\nbackup=1\npassword_set=1\ntunnel=3\nname=Third\nenabled=1\nremote_address=b.example.test\nremote_id=b.example.test\nusername=u\ndpd=30\nmtu=1400\nbackup=1\npassword_set=1\n' };
	helpers['ikev2-manager tunnel-input'] = { code: 0, stdout: '' };
	tree = page = client.renderData(await client.loadData());
	flushTimers();
	const blocks = tree.parts.tunnels.panels().map(panel => panel.block);
	assert.strictEqual(blocks.length, 2, 'client: both tunnels have a tab');
	const names = blocks.map(b => b.querySelectorAll('input').find(i => i.value === 'Second' || i.value === 'Third'));
	names[0].value = 'Second edited'; names[0].dispatch('input');
	names[1].value = 'Third edited'; names[1].dispatch('input');
	flushTimers();
	blocks[0].querySelectorAll('button').find(b => b.textContent.trim() === 'Save tunnel').click();
	for (let i = 0; i < 40; i++) { await Promise.resolve(); flushTimers(); }
	const after = tree.parts.tunnels.panels().map(panel => panel.block);
	assert.strictEqual(after.length, 2, 'client: the tabs are drawn again');
	assert.notStrictEqual(after[0], blocks[0], 'client: the saved tunnel is drawn from the router');
	assert.strictEqual(after[1], blocks[1], 'client: the block being edited is kept');
	assert.strictEqual(names[1].value, 'Third edited', 'client: unsaved edits of another tunnel survive');
}

async function main() {
	// A router read in full: Save sends the services where they were.
	healthyRouter();
	let tree = await open();
	let save = await editAndSave(tree);
	const exits = written.find(w => w.file.endsWith('.exits'));
	assert(exits, 'a healthy page saves the exits');
	assert.strictEqual(exits.data, 'example_ai 2s\nexample_chat 2\n', 'Save keeps where each service goes');

	// The tunnel list could not be read. The page cannot tell the second tunnel
	// exists, so it must not save, and it must say why.
	healthyRouter();
	helpers['ikev2-manager tunnels-get'] = { code: 1, stdout: '' };
	tree = await open();
	save = await editAndSave(tree);
	assert.deepStrictEqual(written.map(w => w.file), [], 'nothing is written after a failed read');
	assert(save.disabled, 'Save stays off after a failed read');
	assert(/could not be read/i.test(tree.textContent), 'the page says what could not be read');
	assert(/Save is off: part of the policy could not be read/.test(saveButton(tree).parentNode.textContent),
		'the reason is next to the grey Save too');

	// The same for the service catalogue: without it a service's old mark is lost.
	healthyRouter();
	helpers['ikev2-domains-community services'] = { code: 1, stdout: '' };
	tree = await open();
	await editAndSave(tree);
	assert.deepStrictEqual(written.map(w => w.file), [], 'nothing is written without the catalogue');

	// A list that does not exist yet is an empty list, not a failed read.
	healthyRouter();
	delete files['/etc/pbr-ikev2-exits.txt'];
	delete files['/etc/pbr-ikev2-domains.manual.txt'];
	tree = await open();
	await editAndSave(tree);
	assert(written.find(w => w.file.endsWith('.exits')), 'a missing file does not block Save');

	// A file that exists but could not be read blocks Save like a helper does.
	healthyRouter();
	fsStub.read = (orig => file => file === '/etc/pbr-ikev2-exits.txt' ?
		Promise.reject(Object.assign(new Error('Permission denied'), { name: 'PermissionError' })) : orig(file))(fsStub.read);
	tree = await open();
	await editAndSave(tree);
	assert.deepStrictEqual(written.map(w => w.file), [], 'nothing is written when a list could not be read');

	await shellOpensAtOnce();
	await pages();
	console.log('failed reads OK');
}

main().catch(error => {
	console.error('failed reads: ' + (error && error.stack || error));
	process.exit(1);
});
