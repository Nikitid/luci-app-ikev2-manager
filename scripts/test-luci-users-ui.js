'use strict';

const fsNode = require('fs');
const assert = require('assert');

if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%[sd]/g, () => String(args[i++]));
	};
}

class Node {
	constructor(tag, attrs, children) {
		this.tag = tag;
		this.attrs = attrs || {};
		this.children = [];
		this.style = {};
		this.dataset = {};
		this.disabled = false;
		this.value = this.attrs.value || '';
		this.checked = this.attrs.checked != null;
		this.className = this.attrs.class || '';
		this._text = '';
		this.classList = {
			toggle: (name, enabled) => {
				const names = this.className.split(/\s+/).filter(Boolean);
				const found = names.indexOf(name);
				if (enabled && found < 0) names.push(name);
				if (!enabled && found >= 0) names.splice(found, 1);
				this.className = names.join(' ');
			}
		};
		this.replaceChildren.apply(this, children || []);
	}

	appendChild(child) {
		if (child == null || child === '') return;
		this.children.push(child instanceof Node ? child : String(child));
	}

	replaceChildren() {
		this.children = [];
		Array.prototype.slice.call(arguments).flat().forEach(child => this.appendChild(child));
	}

	addEventListener(type, handler) { this.attrs[type] = handler; }
	setAttribute(name, value) { this.attrs[name] = value; }
	removeAttribute(name) { delete this.attrs[name]; }
	focus() {}

	get textContent() {
		return this._text + this.children.map(child =>
			child instanceof Node ? child.textContent : child).join('');
	}

	set textContent(value) {
		this._text = value == null ? '' : String(value);
		this.children = [];
	}

	get innerHTML() { return this.textContent; }
	set innerHTML(value) { this.textContent = value; }
}

function E(tag, attrs, children) {
	if (Array.isArray(tag)) return new Node('fragment', {}, tag);
	if (typeof tag === 'string' && tag.charAt(0) === '<') return new Node('svg', {}, []);
	return new Node(tag, attrs, children);
}

function walk(node, fn) {
	if (!(node instanceof Node)) return;
	fn(node);
	node.children.forEach(child => walk(child, fn));
}

function find(root, tag, text) {
	let found;
	walk(root, node => {
		if (!found && node.tag === tag && (!text || node.textContent.trim() === text))
			found = node;
	});
	return found;
}

function findByTitle(root, title) {
	let found;
	walk(root, node => {
		if (!found && node.attrs && node.attrs.title === title)
			found = node;
	});
	return found;
}

function inlineResult() {
	const node = E('span', { class: 'ikev2-result' }, []);
	function set(kind, message) {
		node.className = 'ikev2-result ' + kind;
		node.style.display = '';
		node.textContent = message;
	}
	return {
		node,
		busy: message => set('busy', message),
		ok: message => set('ok', message),
		warn: message => set('warn', message),
		err: message => set('err', message),
		clear: () => { node.style.display = 'none'; }
	};
}

function setBusy(button, busy) {
	if (busy) {
		button.dataset.idleDisabled = button.disabled ? '1' : '0';
		button.dataset.busy = '1';
		button.disabled = true;
	}
	else {
		delete button.dataset.busy;
		button.disabled = button.dataset.idleDisabled === '1';
		delete button.dataset.idleDisabled;
	}
}

let users = [];
const linkRequests = [];
const qrPayloads = [];
const uqr = { renderSVG: text => { qrPayloads.push(text); return '<svg width="10" height="10"></svg>'; } };
let userInput = '';
let modal = null;
const fileApi = {
	stat: () => Promise.resolve({}),
	write: (path, payload) => { userInput = payload; return Promise.resolve(); },
	exec: (path, args) => {
		if (path === '/usr/sbin/swanmon') return Promise.resolve({ stdout: '[]' });
		if (args[0] === 'users-show') return Promise.resolve({
			stdout: users.map(user => [
				user.name, user.routerAccess, user.internetAccess,
				user.lanAccess, user.pbrMode, user.lanTargets, user.publicPorts
			].join('\t')).join('\n') + (users.length ? '\n' : '')
		});
		if (args[0] === 'server-access-get') return Promise.resolve({
			stdout: 'allow_router=0\nallow_internet=1\nallow_lan=1\n'
		});
		if (args[0] === 'server-get') return Promise.resolve({ stdout: 'custom_config=0\n' });
		if (args[0] === 'profile-link') {
			linkRequests.push(args.slice(1).join(' '));
			return Promise.resolve({ stdout: 'token=0123456789abcdef0123456789abcdef\nexpires=1790000600\n' });
		}
		if (args[0] === 'user-secret-set') {
			const fields = userInput.split('\n');
			if (fields[0] === 'add') users.push({
				name: fields[1],
				routerAccess: fields[3] || 'inherit',
				internetAccess: fields[4] || 'inherit',
				lanAccess: fields[5] || 'inherit',
				pbrMode: fields[6] || 'inherit',
				lanTargets: fields[7] || '',
				publicPorts: fields[8] || ''
			});
			if (fields[0] === 'policy') {
				const user = users.find(item => item.name === fields[1]);
				user.routerAccess = fields[3];
				user.internetAccess = fields[4];
				user.lanAccess = fields[5];
				user.pbrMode = fields[6];
				user.lanTargets = fields[7];
				user.publicPorts = fields[8];
			}
			return Promise.resolve({ stdout: '' });
		}
		if (args[0] === 'user-delete') {
			users = users.filter(user => user.name !== args[1]);
			return Promise.resolve({ stdout: '' });
		}
		return Promise.resolve({ stdout: '' });
	}
};

const common = {
	trackChanges: () => ({ update() {}, reset() {}, dirty: () => true }),
	parseSwanmon: response => JSON.parse(response.stdout || '[]'),
	parseKeyValues: text => String(text || '').split('\n').reduce((result, line) => {
		const pos = line.indexOf('=');
		if (pos >= 0) result[line.slice(0, pos)] = line.slice(pos + 1);
		return result;
	}, {}),
	formatDuration: value => String(value || 0),
	formatBytes: value => String(value || 0),
	styles: () => E('style', {}, []),
	icon: () => E('svg', {}, []),
	fieldLabel: title => E('label', {}, [ title ]),
	inlineResult,
	inputToken: () => 'test-token',
	pill: (text, tone) => E('span', { class: 'ikev2-pill ' + tone }, [ text ]),
	setPill: (node, text, tone) => { node.className = 'ikev2-pill ' + tone; node.textContent = text; },
	header: (title, subtitle) => E('header', {}, [ title, subtitle ]),
	section: (title, description, content, actions) => E('section', {}, [ title, description, content, actions ]),
	gate: () => E('div', {}, []),
	execChecked: (path, args) => fileApi.exec(path, args).then(response => {
		if (response.code) throw new Error(response.stderr || response.stdout || 'failed');
		return response;
	}),
	runAction: options => {
		setBusy(options.button, true);
		if (options.result) options.result.busy(options.busy);
		return Promise.resolve().then(options.run).then(value => {
			if (options.success && options.result) options.result.ok(options.success);
			return options.onSuccess ? Promise.resolve(options.onSuccess(value)).then(() => value) : value;
		}).catch(error => {
			if (options.result) options.result.err(error.message);
			return null;
		}).finally(() => setBusy(options.button, false));
	}
};

const ui = {
	showModal: (title, nodes) => { modal = E('div', {}, nodes); },
	hideModal: () => { modal = null; }
};
const poll = { add: () => {} };
const L = { resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback) };
const windowMock = { confirm: () => true, setTimeout, Event: function() {},
	location: { origin: 'http://192.168.1.1' } };
const documentMock = {};
const view = { extend: object => object };
const translate = value => value;

const source = fsNode.readFileSync('luci-ikev2-manager/users.js', 'utf8');
// The exact suffix is pinned by check-luci-ui-contract.sh, which also makes
// every page agree on one build; here it only has to be a versioned name.
assert(/'require ikev2-manager\.shared-v\d+ as common';/.test(source),
	'VPN Users uses a cache-versioned shared style and translation module');
const factory = new Function('view', 'fs', 'ui', 'poll', 'common', 'L', 'E', '_', 'window', 'document', 'uqr', source);
const page = factory(view, fileApi, ui, poll, common, L, E, translate, windowMock, documentMock, uqr);

(async () => {
	const data = await page.load();
	const root = page.render(data);
	assert(root.textContent.includes('No VPN users configured.'));
	assert(root.textContent.includes('VPN setup for Windows'),
		'page exposes one reusable Windows installer');
	assert(root.textContent.includes('Download application'),
		'Windows installer has a standalone download action');

	await find(root, 'button', 'Add user').attrs.click({ currentTarget: find(root, 'button', 'Add user') });
	const inputs = [];
	walk(modal, node => { if (node.tag === 'input') inputs.push(node); });
	inputs[0].value = 'test-user';
	inputs[1].value = 'secret';
	const save = find(modal, 'button', 'Save');
	await save.attrs.click({ currentTarget: save });

	assert.strictEqual(modal, null, 'successful add closes the modal');
	assert(root.textContent.includes('test-user'), 'new user appears without a page reload');
	assert(root.textContent.includes('1 users'), 'user count updates without a page reload');
	assert(root.textContent.includes('VPN user added.'), 'success is shown in the local action bar');

	assert(findByTitle(root, 'Download iOS profile'),
		'user card has a direct iOS profile action');
	assert(findByTitle(root, 'Download Windows profile'),
		'user card has a direct Windows XML action');
	assert(findByTitle(root, 'Download Android profile'),
		'user card has a direct Android profile action');
	assert(!root.textContent.includes('Client profiles'),
		'user card does not require a profile download dialog');

	// The QR asks the router for a one-time link to the chosen phone's
	// profile and encodes that link, on the address the page was opened on.
	await findByTitle(root, 'QR code for a phone').attrs.click();
	const android = find(modal, 'button', 'Android, strongSwan app');
	await android.attrs.click();
	assert.deepStrictEqual(linkRequests, [ 'android test-user' ], 'the QR asks for a link to the Android profile');
	assert.deepStrictEqual(qrPayloads,
		[ 'http://192.168.1.1/cgi-bin/ikev2-profile?t=0123456789abcdef0123456789abcdef' ],
		'the QR encodes the one-time link on the page origin');
	assert(modal.textContent.includes('The link opens once'), 'the dialog says the link opens once');
	ui.hideModal();

	await findByTitle(root, 'Access policy').attrs.click({
		currentTarget: findByTitle(root, 'Access policy')
	});
	const selects = [];
	let targets;
	let publicPorts;
	walk(modal, node => {
		if (node.tag === 'select') selects.push(node);
		if (node.tag === 'textarea') targets = node;
		if (node.tag === 'input' && node.attrs.placeholder === '1443 8443-8445')
			publicPorts = node;
	});
	selects[0].value = 'deny';
	selects[0].attrs.change();
	selects[1].value = 'deny';
	selects[2].value = 'limited';
	selects[2].attrs.change();
	selects[3].value = 'exclude';
	targets.value = '192.168.1.20 192.168.10.0/24';
	publicPorts.value = '1443,8443-8445';
	const policySave = find(modal, 'button', 'Save');
	await policySave.attrs.click({ currentTarget: policySave });
	assert(!root.textContent.includes('Router: Denied'),
		'access details stay behind the settings action');
	assert(!root.textContent.includes('Public ports: 1443 8443-8445'),
		'advanced access details do not clutter the card');
	assert(root.textContent.includes('Access policy saved.'), 'policy save uses local inline feedback');

	const remove = findByTitle(root, 'Delete');
	await remove.attrs.click({ currentTarget: remove });
	assert(root.textContent.includes('No VPN users configured.'), 'deleted user disappears without a page reload');
	assert(root.textContent.includes('0 users'), 'user count updates after deletion');
	assert.strictEqual(find(root, 'button', 'Disconnect all').disabled, true,
		'disconnect-all stays disabled when refreshed state has no sessions');

	console.log('luci users UI state refresh tests OK');
})().catch(error => {
	console.error(error);
	process.exit(1);
});
