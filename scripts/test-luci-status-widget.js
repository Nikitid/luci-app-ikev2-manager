'use strict';

const fsNode = require('fs');
const assert = require('assert');

if (!String.prototype.format) {
	String.prototype.format = function() {
		let index = 0;
		const args = arguments;
		return this.replace(/%[sd]/g, () => String(args[index++]));
	};
}

class Node {
	constructor(tag, attrs, children) {
		this.tag = tag;
		this.attrs = attrs || {};
		this.children = [];
		(children || []).flat().forEach(child => this.appendChild(child));
	}

	appendChild(child) {
		if (child == null || child === '')
			return;
		this.children.push(child instanceof Node ? child : String(child));
	}

	get textContent() {
		return this.children.map(child =>
			child instanceof Node ? child.textContent : child).join('');
	}
}

function E(tag, attrs, children) {
	if (typeof tag === 'string' && tag.charAt(0) === '<')
		return new Node('svg', {}, []);
	return new Node(tag, attrs, children);
}

function walk(node, callback) {
	if (!(node instanceof Node))
		return;
	callback(node);
	node.children.forEach(child => walk(child, callback));
}

function find(root, tag, className) {
	let result;
	walk(root, node => {
		if (result || node.tag !== tag)
			return;
		const classes = String(node.attrs.class || '').split(/\s+/);
		if (!className || classes.includes(className))
			result = node;
	});
	return result;
}

let statusResponse = {
	stdout: [
		'health=up',
		'configured=1',
		'pbr=running',
		'client_enabled=1',
		'server_enabled=1',
		'interface_present=1',
		'interface_bytes_in=123456',
		'interface_bytes_out=654321',
		'inbound_conn_loaded=1',
		'inbound_pool_loaded=1',
		'pbr_domains=79',
		'manual_addresses=2',
		'community_services=11',
		'killswitch=active',
		'domain_engine=fakeip',
		'domain_service=running',
		'domain_healthy=yes',
		'domain_state=active'
	].join('\n') + '\n'
};
let saResponse = {
	stdout: JSON.stringify({
		errors: [],
		data: [
			{
				'proxy-out': {
					state: 'ESTABLISHED',
					established: '600',
					'child-sas': {
						'proxy4-1': {
							name: 'proxy4',
							state: 'INSTALLED',
							'bytes-in': '8192',
							'bytes-out': '1024'
						}
					}
				}
			},
			{
				'ikev2-in': {
					state: 'ESTABLISHED',
					'remote-eap-id': 'alice',
					'remote-vips': [ '10.90.0.10' ],
					established: '125',
					'child-sas': {
						'alice-1': {
							state: 'INSTALLED',
							'bytes-in': '2048',
							'bytes-out': '4096'
						}
					}
				}
			},
			{
				'ikev2-in': {
					state: 'CONNECTING',
					'remote-eap-id': 'offline-user',
					'remote-vips': [ '10.90.0.11' ],
					'child-sas': {}
				}
			},
			{
				'ikev2-in': {
					state: 'ESTABLISHED',
					'remote-eap-id': 'no-data-plane',
					'remote-vips': [ '10.90.0.12' ],
					'child-sas': {
						'pending': { state: 'REKEYING' }
					}
				}
			}
		]
	})
};

const fileApi = {
	exec: (path, args) => {
		if (path === '/usr/libexec/ikev2-manager') {
			assert.deepStrictEqual(args, [ 'widget-status' ]);
			return Promise.resolve(statusResponse);
		}
		assert.strictEqual(path, '/usr/sbin/swanmon');
		assert.deepStrictEqual(args, [ 'list-sas' ]);
		return Promise.resolve(saResponse);
	}
};
const common = {
	// shared.js shadows the global _() with this translator instead of
	// assigning window._, so every consumer must receive it.
	t: text => text,
	parseKeyValues: text => String(text || '').split('\n').reduce((result, line) => {
		const separator = line.indexOf('=');
		if (separator > 0)
			result[line.slice(0, separator)] = line.slice(separator + 1);
		return result;
	}, {}),
	parseSwanmon: result => {
		try {
			return JSON.parse(result.stdout || '{}').data || [];
		}
		catch (error) {
			return [];
		}
	},
	formatBytes: value => value + ' B',
	formatDuration: value => value + ' s',
	styles: () => E('style', {}, []),
	icon: () => E('svg', {}, []),
	pill: (text, tone) => E('span', { class: 'ikev2-pill ' + tone }, [ text ])
};
const L = {
	resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback),
	url: function() {
		return '/' + Array.prototype.slice.call(arguments).join('/');
	}
};
const baseclass = { extend: object => object };
const translate = value => value;

const source = fsNode.readFileSync('luci-ikev2-manager/status-widget.js', 'utf8');
const factory = new Function('baseclass', 'fs', 'common', 'L', 'E', '_', source);
const widget = factory(baseclass, fileApi, common, L, E, translate);

(async () => {
	assert.strictEqual(widget.title, 'IKEv2 Manager');
	const root = widget.render(await widget.load());
	const text = root.textContent;

	assert(text.includes('Operational'));
	assert(text.includes('Outbound tunnel'));
	assert(text.includes('Connected'));
	assert(text.includes('Online for 600 s'));
	assert(text.includes('123456 B'));
	assert(text.includes('654321 B'));
	assert(!text.includes('8192 B'));
	assert(!text.includes('1024 B'));
	assert(text.includes('Policy routing'));
	assert(text.includes('Reliable mode active'));
	assert(text.includes('79 domains'));
	assert(text.includes('Service groups: 11'));
	assert(text.includes('Address rules: 2'));
	assert(text.includes('Routing running'));
	assert(text.includes('Fail-closed active'));
	assert(text.includes('Inbound server'));
	assert(text.includes('Server ready'));
	assert(text.includes('Active sessions: 1'));
	assert(text.includes('alice'));
	assert(text.includes('10.90.0.10'));
	assert(text.includes('4096 B'));
	assert(text.includes('2048 B'));
	assert(!text.includes('offline-user'));
	assert(!text.includes('no-data-plane'));

	const link = find(root, 'a', 'ikev2-quick-link');
	assert(link);
	assert.strictEqual(link.attrs.href, '/admin/services/ikev2-manager/setup');

	saResponse = { stdout: JSON.stringify({ errors: [], data: [] }) };
	const disconnected = widget.render(await widget.load());
	assert(disconnected.textContent.includes('Action required'));
	assert(disconnected.textContent.includes('Disconnected'));
	assert(disconnected.textContent.includes('Active sessions: 0'));
	assert(!disconnected.textContent.includes('Active inbound clients'));

	statusResponse = {
		stdout: [
			'health=down',
			'configured=1',
			'pbr=stopped',
			'client_enabled=1',
			'server_enabled=1',
			'interface_present=0',
			'interface_bytes_in=0',
			'interface_bytes_out=0',
			'inbound_conn_loaded=0',
			'inbound_pool_loaded=0',
			'pbr_domains=79',
			'manual_addresses=0',
			'community_services=11',
			'killswitch=missing',
			'domain_engine=fakeip',
			'domain_service=stopped',
			'domain_healthy=no'
		].join('\n') + '\n'
	};
	const degraded = widget.render(await widget.load());
	assert(degraded.textContent.includes('Routing stopped'));
	assert(degraded.textContent.includes('Fail-closed missing'));
	assert(degraded.textContent.includes('Server degraded'));

	// The application's own routing runs without PBR: a stopped or removed
	// PBR is not a stopped policy routing.
	statusResponse = {
		stdout: statusResponse.stdout
			.replace('pbr=stopped', 'pbr=stopped\nrouting_backend=native\nrouting=running')
	};
	const native = widget.render(await widget.load());
	assert(native.textContent.includes('Routing running'));
	assert(!native.textContent.includes('Routing stopped'));

	const unavailable = widget.render([
		{ code: 1, stdout: '' },
		{ code: 1, stdout: '' }
	]);
	assert(unavailable.textContent.includes('Project status is unavailable.'));
	assert(unavailable.textContent.includes('Connection state is unavailable.'));

	console.log('LuCI status widget tests OK');
})().catch(error => {
	console.error(error);
	process.exit(1);
});
