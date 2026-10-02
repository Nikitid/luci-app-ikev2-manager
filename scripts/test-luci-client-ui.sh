#!/bin/sh

# A parse check proves only that the file is syntactically valid. A LuCI page
# dies at render time instead - a control referenced before it is declared, a
# helper that is not exported, a section built from a variable that was never
# assigned - and every command-line check still passes while the page shows
# nothing. This harness stubs the LuCI environment and actually renders the
# outbound tunnel view, which owns the DNS controls.

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

node - "$root" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

// LuCI installs a printf-style String.prototype.format; the modules rely on it.
if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function() {
			const args = Array.prototype.slice.call(arguments);
			let index = 0;
			return String(this).replace(/%[sdif]|%\.\d+f/g, function() {
				const value = args[index++];
				return value === undefined ? '' : String(value);
			});
		}
	});
}

function fail(message) {
	process.stderr.write('client UI contract failed: ' + message + '\n');
	process.exit(1);
}

function makeNode(tag, attrs) {
	return {
		tagName: String(tag || 'div').toUpperCase(),
		attrs: attrs || {},
		children: [],
		style: {},
		dataset: {},
		listeners: {},
		// A real <select> reports the selected option's value when none was set
		// explicitly. Without this the modules see an empty protocol and build
		// empty option lists, which is a stub artefact rather than a page defect.
		_value: (attrs && attrs.value != null) ? String(attrs.value) : '',
		get value() {
			if (this._value) return this._value;
			if (this.tagName !== 'SELECT') return '';
			const chosen = this.children.find(function(child) {
				return child.attrs && child.attrs.selected != null;
			}) || this.children[0];
			return chosen && chosen.attrs ? String(chosen.attrs.value || '') : '';
		},
		set value(next) { this._value = next == null ? '' : String(next); },
		checked: !!(attrs && attrs.checked !== undefined && attrs.checked !== null),
		disabled: !!(attrs && attrs.disabled),
		textContent: '',
		title: '',
		className: (attrs && attrs['class']) || '',
		// A <select> exposes its <option> children as .options; the modules read it.
		get options() { return this.children; },
		get firstChild() { return this.children[0] || null; },
		classList: { add() {}, remove() {}, contains() { return false; }, toggle() {} },
		// Every listener runs, as in the DOM: a change tracker added after the
		// page's own handler must not replace it.
		addEventListener(name, handler) {
			const previous = this.listeners[name];
			this.listeners[name] = previous ? function(event) {
				previous.call(this, event);
				return handler.call(this, event);
			} : handler;
		},
		removeAttribute() {}, setAttribute() {}, focus() {}, remove() {}, click() {},
		// The overview shows an issue twice, in the summary and the details.
		cloneNode(deep) {
			const copy = Object.assign(makeNode(this.tagName, this.attrs), { textContent: this.textContent });
			if (deep)
				copy.children = this.children.map(function(child) {
					return child && typeof child.cloneNode === 'function' ? child.cloneNode(true) : child;
				});
			return copy;
		},
		appendChild(child) { this.children.push(child); return child; },
		removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; },
		insertBefore(child) { this.children.unshift(child); return child; },
		replaceChildren() { this.children = Array.prototype.slice.call(arguments); },
		appendChildren() {},
		querySelector() { return null; },
		querySelectorAll() { return []; }
	};
}

function E(tag, attrs, children) {
	// E([a, b]) builds a fragment from the array; keep the children or the page
	// looks empty to the harness even though it rendered.
	if (Array.isArray(tag)) {
		const fragment = makeNode('div', {});
		tag.forEach(function(child) { if (child) fragment.children.push(child); });
		return fragment;
	}
	if (typeof tag === 'string' && tag.charAt(0) === '<')
		return makeNode('svg', {});
	if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
	const node = makeNode(tag, attrs);
	(children || []).forEach(function(child) { if (child) node.children.push(child); });
	return node;
}

const documentStub = {
	createTextNode(text) { const n = makeNode('#text', {}); n.textContent = String(text); return n; },
	getElementById() { return null; },
	head: { appendChild() {} },
	createDocumentFragment() { return makeNode('fragment', {}); },
	// SVG is built attribute by attribute; keep them so the chart can be read.
	createElementNS(ns, tag) {
		const node = makeNode(tag, {});
		node.setAttribute = function(name, value) { this.attrs[name] = String(value); };
		node.getBoundingClientRect = function() { return { left: 0, top: 0, width: 280, height: 224 }; };
		return node;
	},
	documentElement: { lang: 'en' },
	querySelector() { return null; },
	querySelectorAll() { return []; }
};
const windowStub = {
	localStorage: null, setTimeout() {}, clearTimeout() {},
	location: { reload() {} }, _: null,
	requestAnimationFrame(fn) { fn(); }
};

// LuCI's cbi.js declares _() globally; the pages call it directly.
globalThis._ = function(s) { return s; };

const L = {
	resolveDefault: function(p, d) { return Promise.resolve(d); },
	url: function() { return '/cgi-bin/luci/' + Array.prototype.join.call(arguments, '/'); },
	Poll: { add() {}, remove() {} }
};
const baseclass = { extend: function(o) { return o; } };
const fsStub = {
	exec: function() { return Promise.resolve({ code: 0, stdout: '' }); },
	stat: function() { return Promise.resolve({}); },
	write: function() { return Promise.resolve(); }
};
const uiStub = {
	createHandlerFn: function(self, fn) { return fn; },
	showModal() {}, hideModal() {}, addNotification() {}
};
const pollStub = { add() {}, remove() {} };

function loadModule(file, extra) {
	const src = fs.readFileSync(path.join(root, 'luci-ikev2-manager', file), 'utf8');
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'uci',
		'view', 'poll', 'common' ];
	const values = [ windowStub, documentStub, L, baseclass, E, fsStub, uiStub, {},
		{ extend: function(o) { return o; } }, pollStub, extra ];
	return new Function(names.join(','), src).apply(null, values);
}

const common = loadModule('shared.js', null);
[ 'styles', 'card', 'pill', 'setPill', 'header', 'section', 'fieldLabel',
	'inlineResult', 'runAction', 'execChecked', 'inputToken', 'toggleRow',
	'switchLabel', 'gate', 'parseKeyValues', 'parseSwanmon' ].forEach(function(name) {
	if (typeof common[name] !== 'function')
		fail('shared.js does not export ' + name + ', which client.js uses');
});

const view = loadModule('client.js', common);
if (typeof view.render !== 'function')
	fail('client.js does not return a view with render()');

// Reliable mode, managed DNS, tunnel resolution on, one destination segment.
const clientGet = [
	'enabled=1', 'remote_address=vpn.example.net', 'remote_id=vpn.example.net',
	'username=proxy', 'dpd=30', 'mtu=1400', 'custom_config=0',
	'reconnect_cooldown=15', 'tunnel_dns_provider=custom',
	'tunnel_dns_upstream=https://dns.cloudflare.com/dns-query https://dns.google/dns-query',
	'tunnel_dns_bootstrap=8.8.8.8:53 1.1.1.1:53',
	'tunnel_dns_active=https://dns.cloudflare.com/dns-query',
	'tunnel_dns_failures=0', 'interface_present=1',
	'interface_bytes_in=1', 'interface_bytes_out=1'
].join('\n');
const dnsGet = [
	'managed=1', 'protocol=doh', 'provider=custom', 'upstream_mode=fastest_addr',
	'upstream=https://freedns.controld.com/p0', 'bootstrap=9.9.9.10:53',
	'fallback=https://dns.google/dns-query', 'wan_fallback=1',
	'timeout=2s', 'timeout_effective=2s', 'fallback_verified=1788000000',
	'tunnel_resolve=1', 'segment_health=up', 'running=1',
	'via_singbox=0', 'https_compat=0', 'engine=fakeip'
].join('\n');
const segments = [
	'id=ru\tname=RU\tenabled=1\tdomains=ru su\tprotocol=doh\tmode=load_balance',
	'upstream=https://common.dot.dns.yandex.net/dns-query\tbootstrap=77.88.8.8:53',
	'fallback=\tfallback_effective=https://dns.google/dns-query\tinherits_fallback=1',
	'https_compat=1\tport=5550'
].join('\t');

const data = [
	{ code: 0, stdout: clientGet }, { stdout: '' }, { code: 0, stdout: '0' },
	{ code: 0, stdout: '' }, { stdout: dnsGet }, { stdout: segments },
	{ stdout: [
		'window=3600', 'generated=1790000000', 'samples=3', 'measured=3',
		'availability=100.0', 'loss=0.0', 'wan_loss=0.0', 'jitter=2.0',
		'rtt_p50=50.0', 'rtt_p95=60.0', 'wan_rtt_p50=2.0', 'overhead_ms=48.0',
		'state=up', 'stable_since=1789999000', 'outages=0', 'reconnects=1',
		'resolver_restarts=0', 'quality=good', 'quality_cause=',
		'points=1789996400,-,-,-,-,-,none,-,-;1789999820,48.0,55.0,0.0,2.0,0.0,up,1000,100;' +
			'1789999880,52.0,60.0,20.0,2.0,0.0,up,1000,100,-;1789999910,-,-,-,2.0,0.0,maint,0,0,pbr-restart;' +
			'1789999940,50.0,51.0,0.0,2.0,0.0,up,1000,100,-',
		'events=1789999930,pbr-restart,manual,25;1789999900,reconnect,auto,1',
		'speed_setting_tunnel_service=ovh', 'speed_setting_wan_service=selectel',
		'speed_setting_direction=down', 'speed_setting_streams=4',
		'speed_checked=1789999000', 'speed_tunnel_service=ovh', 'speed_wan_service=cloudflare',
		'speed_streams=1', 'speed_tunnel_down_bps=100000000', 'speed_loaded_rtt=58.0',
		'speed_wan_down_bps=16000', 'speed_wan_down_stalled=1',
		'speed_tunnel_up_bps=unavailable', 'speed_wan_up_bps=50000000'
	].join('\n') }
];
data.ready = true;

let page;
try {
	page = view.render(data);
} catch (error) {
	fail('render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!page || !page.children || !page.children.length)
	fail('render() produced an empty page');

const source = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'client.js'), 'utf8');

// Connection quality: the verdict, four tiles, and a curve rather than bars.
function collect(node, test, out) {
	if (!node || typeof node !== 'object') return out;
	if (test(node)) out.push(node);
	(node.children || []).forEach(function(child) { collect(child, test, out); });
	return out;
}
function hasClass(node, name) {
	const value = (node.attrs && node.attrs['class']) || node.className || '';
	return String(value).split(/\s+/).indexOf(name) >= 0;
}
const verdictNodes = collect(page, function(node) { return hasClass(node, 'ikev2-quality-verdict'); }, []);
if (verdictNodes.length !== 1)
	fail('the connection quality section is missing');
if (verdictNodes[0].children[0].textContent !== 'Good')
	fail('the quality verdict does not show the summary verdict');
const qualityGrid = collect(page, function(node) { return hasClass(node, 'ikev2-quality-grid'); }, [])[0];
if (!qualityGrid || qualityGrid.children.length !== 4)
	fail('the quality section does not show four tiles');
const tunnelCurves = collect(page, function(node) {
	return node.tagName === 'PATH' && node.attrs['class'] === 'tunnel';
}, []);
// The maintenance bucket in the fixture breaks the line in two.
if (tunnelCurves.length !== 2 || !tunnelCurves.some(function(node) { return /C/.test(node.attrs.d); }) ||
	tunnelCurves.some(function(node) { return /L/.test(node.attrs.d); }))
	fail('tunnel latency is not drawn as a smooth curve broken at maintenance');
if (!collect(page, function(node) { return node.tagName === 'RECT' && node.attrs['class'] === 'loss'; }, []).length)
	fail('packet loss is not marked on the chart');
if (!collect(page, function(node) { return node.tagName === 'CIRCLE' && /event/.test(node.attrs['class'] || ''); }, []).length)
	fail('events are not marked on the chart');
if (!collect(page, function(node) { return node.tagName === 'RECT' && node.attrs['class'] === 'maint'; }, []).length)
	fail('an operator action is not shown as maintenance on the chart');
const speedOptions = collect(page, function(node) { return hasClass(node, 'ikev2-speed-options'); }, [])[0];
if (!speedOptions || collect(speedOptions, function(node) { return node.tagName === 'SELECT'; }, []).length !== 4)
	fail('the speed test does not offer a service per path, direction and streams');
// Download and upload are columns of their own, each comparing the two paths.
const speedColumns = collect(page, function(node) { return hasClass(node, 'ikev2-speed-column'); }, []);
if (speedColumns.length !== 2)
	fail('download and upload are not shown as two columns');
speedColumns.forEach(function(column) {
	if (collect(column, function(node) { return hasClass(node, 'ikev2-speed-row'); }, []).length !== 2)
		fail('a speed column does not compare the tunnel with the direct path');
});
if (!collect(page, function(node) { return node.tagName === 'B' && hasClass(node, 'muted'); }, []).length)
	fail('an upload the service cannot take is not reported as unavailable');
const livePanel = collect(page, function(node) { return hasClass(node, 'ikev2-speed-live'); }, [])[0];
if (!livePanel || livePanel.attrs.style !== 'display:none')
	fail('the live CPU panel is missing or shown outside a test');
if (!/progress: false/.test(source))
	fail('the speed test repeats its steps beside the button as well as in the live panel');
const cutOff = collect(page, function(node) { return node.tagName === 'B' && hasClass(node, 'warn'); }, []);
if (!cutOff.length)
	fail('a transfer the path cut off is not reported as cut');

// The tunnel DNS block applies on its own, and destination segments are their
// own section rather than a disclosure inside the router resolver.
if (source.indexOf("common.section(_('Destination DNS segments')") < 0)
	fail('destination segments are not their own section');
if (/E\('details'[^\n]*\n\s*E\('summary', \{\}, \[ _\('Destination DNS segments'\)/.test(source))
	fail('destination segments are still hidden behind a disclosure');
if (source.indexOf('tunnelDnsApply.addEventListener') < 0)
	fail('tunnel DNS has no apply of its own');
if (source.indexOf('routerDnsBypassNote') < 0)
	fail('router DNS section does not report being bypassed');

// Every literal bootstrap preset must satisfy the rule the runtime enforces:
// a bare IPv4 authority, or an encrypted endpoint whose host is one. A preset
// that fails it would be offered by the page and refused on save.
const providerStart = source.indexOf('var dnsProviders = [');
const providerBlock = source.slice(providerStart,
	source.indexOf('\n];', providerStart));
const literalPresets = (providerBlock.match(/bootstrap_(?:doh|dot): '([^']*)'/g) || [])
	.map(function(line) { return line.replace(/^[^']*'|'$/g, ''); })
	.join(' ').split(/\s+/).filter(Boolean);
if (literalPresets.length < 8)
	fail('the bootstrap group offers almost no literal-address presets');
literalPresets.forEach(function(endpoint) {
	const authority = endpoint.slice(endpoint.indexOf('://') + 3).split('/')[0];
	const host = authority.split(':')[0];
	if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(host))
		fail('bootstrap preset ' + endpoint + ' does not use a literal IPv4 host');
	if (!/^(https|tls|quic):\/\//.test(endpoint))
		fail('bootstrap preset ' + endpoint + ' uses a scheme the runtime refuses');
});

// Protocol labels reach _() through a variable, so the translation coverage
// check cannot see them. Every offered label must still be in the catalog.
const catalog = fs.readFileSync(path.join(root, 'po', 'ru', 'ikev2-manager.po'), 'utf8');
const protocolBlockStart = source.indexOf('var dnsProtocols = [');
const protocolLabels = source.slice(protocolBlockStart,
	source.indexOf('\n];', protocolBlockStart))
	.match(/label: '([^']*)'/g).map(function(line) {
		return line.replace(/^label: '|'$/g, '');
	}).concat([ 'Plain DNS (IPv4:port)' ]);
protocolLabels.forEach(function(label) {
	if (catalog.indexOf('\nmsgid ' + JSON.stringify(label) + '\n') < 0)
		fail('protocol label "' + label + '" has no translation');
});

// The protocol is chosen per endpoint, not once for a whole group. A group
// select would contradict the row selects the moment the two disagreed, and
// dnsproxy parses each upstream by its own scheme anyway.
if (/\bdnsProtocol\b/.test(source))
	fail('the router resolver still picks one protocol for the whole group');
if (/common\.fieldLabel\(_\('Protocol'\)\)/.test(source))
	fail('a segment still picks one protocol for its whole group');
if ((source.match(/\{ choosable: true \}/g) || []).length < 4)
	fail('not every editable group offers a per-row protocol select');
if (source.indexOf('function segmentProtocol()') < 0)
	fail('the stored segment protocol is no longer derived from its endpoints');
// doh3 renders the same https:// string as doh, so a per-row picker offering
// both cannot round-trip through the stored endpoint.
if (/id: 'doh3'/.test(source))
	fail('the protocol list still offers a choice it cannot store');

// Every endpoint row must carry its own provider select, and picking a
// provider must fill the editable field rather than replace it.
function firstWithClass(node, name, out) {
	if (!node || typeof node !== 'object') return out;
	if (node.attrs && typeof node.attrs['class'] === 'string' &&
		node.attrs['class'].split(/\s+/).indexOf(name) >= 0) out.push(node);
	(node.children || []).forEach(function(child) { firstWithClass(child, name, out); });
	return out;
}
// The controls are direct children of the row: a wrapper around the selects
// sized every row by its own longest option label, so columns stopped lining
// up between rows of one list.
const endpointRows = firstWithClass(page, 'ikev2-dns-endpoint', []);
if (!endpointRows.length)
	fail('no endpoint row offers a protocol/provider picker');
const rowShapes = {};
endpointRows.forEach(function(row) {
	const selects = row.children.filter(function(child) {
		return child && child.tagName === 'SELECT';
	});
	if (!selects.length)
		fail('an endpoint row rendered without a select');
	if (!selects[selects.length - 1].children.length)
		fail('the provider select rendered with no options');
	if (!row.children.some(function(child) {
		return child && child.tagName === 'INPUT';
	}))
		fail('an endpoint row rendered without its editable field');
	rowShapes[String(selects.length)] = true;
});
// Both shapes must exist: a group that fixes its protocol and one that lets
// every row choose. A single shape means one of them stopped rendering.
if (!rowShapes['1'] || !rowShapes['2'])
	fail('endpoint rows all render the same shape');
// The fallback line under a segment must not repeat a list the fields above it
// already show; it exists to spell out what an empty field inherits, and the
// provider's servers the router adds after a list of the segment's own.
function renderSegment(fields) {
	const copy = data.slice();
	copy.ready = true;
	copy[5] = { stdout: [
		'id=ru\tname=RU\tenabled=1\tdomains=ru su\tprotocol=doh\tmode=load_balance',
		'upstream=https://common.dot.dns.yandex.net/dns-query\tbootstrap=77.88.8.8:53',
		fields, 'https_compat=1\tport=5550'
	].join('\t') };
	return textOf(view.render(copy));
}
const ownList = renderSegment('fallback=https://dns.google/dns-query\t' +
	'fallback_effective=https://dns.google/dns-query\tinherits_fallback=0\twan_fallback=0');
if (ownList.indexOf('Inherited from the global groups') >= 0)
	fail('the segment fallback restates an explicitly configured list');
const withProvider = renderSegment('fallback=https://dns.google/dns-query\t' +
	'fallback_effective=https://dns.google/dns-query udp://10.0.0.1:53\tinherits_fallback=0\twan_fallback=1');
if (withProvider.indexOf('Then the provider DNS servers: udp://10.0.0.1:53') < 0)
	fail('the provider servers added after the segment list are not named');

// Segments are edited as one block per segment, not through a picker that
// opens on an empty creation form. A configured segment must be on screen
// without a click, and the add button must append another block.
function walk(node, out) {
	if (!node || typeof node !== 'object') return out;
	if (node.attrs && typeof node.attrs['class'] === 'string') out.push(node);
	(node.children || []).forEach(function(child) { walk(child, out); });
	return out;
}
function countClass(name) {
	return walk(page, []).filter(function(node) {
		return node.attrs['class'].split(/\s+/).indexOf(name) >= 0;
	}).length;
}
if (source.indexOf('segmentSelect') >= 0)
	fail('DNS segments are still edited through a segment picker');

// The resolution path: one switch for the ordinary names and one per segment,
// each with the compatibility switch under it, grey while its path does not
// pass through sing-box. Resolving every name through the tunnel takes that
// path already, so the main switch is fixed while that is on.
function switchesAfter(scope, label) {
	const found = [];
	walk(scope, []).forEach(function(node) {
		(node.children || []).forEach(function(child, index) {
			if (child && hasClass(child, 'ikev2-field-label') && child.children[0] === label) {
				const control = node.children[index + 1];
				found.push(control.children[0]);
			}
		});
	});
	return found;
}
const segmentBlock = walk(page, []).find(function(node) { return hasClass(node, 'ikev2-segment-block'); });
const viaSwitches = switchesAfter(page, 'Resolve through sing-box');
const compatSwitches = switchesAfter(page, 'Browser compatibility');
if (viaSwitches.length !== 2 || compatSwitches.length !== 2)
	fail('the router resolver and the segment do not each have a path and a compatibility switch');
const segmentVia = switchesAfter(segmentBlock, 'Resolve through sing-box')[0];
const segmentCompat = switchesAfter(segmentBlock, 'Browser compatibility')[0];
const mainVia = viaSwitches.find(function(node) { return node !== segmentVia; });
const mainCompat = compatSwitches.find(function(node) { return node !== segmentCompat; });
if (!mainVia.disabled || mainCompat.disabled)
	fail('with every name resolved through the tunnel the path is not fixed and compatibility not offered');
if (segmentVia.checked || segmentVia.disabled || !segmentCompat.disabled)
	fail('a direct segment does not offer its path, or offers compatibility it cannot apply');
segmentVia.checked = true;
segmentVia.listeners.change();
if (segmentCompat.disabled)
	fail('sending a segment through sing-box did not offer compatibility');
const written = [];
fsStub.write = function(file, content) { written.push(content); return Promise.resolve(); };
const segmentSave = walk(segmentBlock, []).find(function(node) {
	return node.tagName === 'BUTTON' && textOf(node).trim() === 'Save segment';
});
segmentSave.listeners.click();
if (!written.length || written[0].split('\n')[12] !== '1' || written[0].split('\n').length !== 14)
	fail('the segment path is not the thirteenth line of what the page sends: ' + JSON.stringify(written[0]));
// The router resolver sends its path and compatibility as lines nine and ten.
const dnsWritten = [];
const dnsApply = walk(page, []).find(function(node) {
	return node.tagName === 'BUTTON' && textOf(node).trim() === 'Apply DNS';
});
fsStub.write = function(file, content) { dnsWritten.push(content); return Promise.resolve(); };
mainVia.disabled = false;
mainVia.checked = true;
const dnsSent = Promise.resolve(dnsApply.listeners.click()).then(function() {
	const lines = (dnsWritten[0] || '').split('\n');
	if (lines.length !== 11 || lines[8] !== '1' || lines[9] !== '0')
		fail('the router resolver path is not what the page sends: ' + JSON.stringify(dnsWritten[0]));
	fsStub.write = function() { return Promise.resolve(); };
});

// Matching by address has no sing-box: every path switch is grey.
const standardData = data.slice();
standardData[4] = { stdout: dnsGet.replace('engine=fakeip', 'engine=nftset')
	.replace('tunnel_resolve=1', 'tunnel_resolve=0') };
standardData.ready = true;
const standardPage = view.render(standardData);
const standardSwitches = switchesAfter(standardPage, 'Resolve through sing-box')
	.concat(switchesAfter(standardPage, 'Browser compatibility'));
if (standardSwitches.length !== 4 || standardSwitches.some(function(node) { return !node.disabled; }))
	fail('matching by address offers a resolution path through sing-box');
if (countClass('ikev2-segment-block') !== 1)
	fail('expected one rendered block for the one configured segment, got ' +
		countClass('ikev2-segment-block'));
const addButton = walk(page, []).find(function(node) {
	return node.attrs['class'].indexOf('ikev2-wide-button') >= 0;
});
if (!addButton) fail('there is no full-width button to add a DNS segment');
addButton.listeners.click();
if (countClass('ikev2-segment-block') !== 2)
	fail('the add button did not append another segment block');

// The router takes at most four tunnel DoH servers; a fifth row only led to
// a refusal on save. Two are configured, so two more fill the list.
const addDoh = walk(page, []).find(function(node) {
	return node.tagName === 'BUTTON' && textOf(node).trim() === 'Add DoH server';
});
if (!addDoh) fail('the tunnel DNS editor has no add button');
function fillNewDoh(value) {
	const field = walk(page, []).find(function(node) {
		return node.tagName === 'INPUT' && node.attrs.placeholder === 'https://dns.example/dns-query' &&
			!node.value;
	});
	if (!field) fail('the added tunnel DoH row has no empty field');
	field.value = value;
}
addDoh.listeners.click();
fillNewDoh('https://dns.quad9.net/dns-query');
if (addDoh.disabled) fail('adding a third tunnel DoH server was refused');
addDoh.listeners.click();
fillNewDoh('https://dns.adguard-dns.com/dns-query');
if (!addDoh.disabled) fail('a fifth tunnel DoH server can still be added');

// A busy button must show that the action was accepted, not just go grey.
const probe = makeNode('button', {});
probe.textContent = 'Apply';
common.setBusy(probe, true, 'Applying...');
if (!probe.disabled)
	fail('setBusy did not disable the button');
if (!probe.children.some(function(child) {
	return child.attrs && child.attrs['class'] === 'ikev2-spin';
}))
	fail('setBusy did not render a spinner');
common.setBusy(probe, false);
if (probe.disabled)
	fail('setBusy did not restore the button');

// The overview page owns the pause control, so it is rendered here too: a
// control referenced before its declaration parses cleanly and only fails in
// the browser.
const setupValue = [
	'configured=1', 'routing_paused=1', 'wan_interface=wan', 'wan_zone=wan',
	'source_interfaces=lan', 'source_zones=lan', 'dns_enforce=1', 'block_dot=1',
	'source_include_vpn=1', 'engine=fakeip', 'service=running', 'healthy=yes',
	'state=active'
].join('\n');
const doctorOut = [ 'diagnostic_status=ok', 'dependencies_ok=yes', 'readiness=ok' ].join('\n');
const setupView = loadModule('setup.js', common);
if (typeof setupView.render !== 'function')
	fail('setup.js does not return a view with render()');
let setupPage;
try {
	setupPage = setupView.render([
		{ stdout: setupValue }, { stdout: doctorOut }, { stdout: '' },
		{ stdout: '' }, { stdout: '' }, { stdout: '' }
	]);
} catch (error) {
	fail('setup.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!setupPage || !setupPage.children || !setupPage.children.length)
	fail('setup.js render() produced an empty page');

// What the rendered overview shows, not what its source says.
function nodesOf(node, out) {
	out = out || [];
	if (!node || typeof node !== 'object') return out;
	out.push(node);
	(node.children || []).forEach(function(child) { nodesOf(child, out); });
	return out;
}
function textOf(node) {
	if (node == null) return '';
	if (typeof node !== 'object') return String(node);
	// Like the DOM: textContent, once set, is the node's whole text.
	if (node.textContent) return node.textContent;
	return (node.children || []).map(textOf).join(' ');
}
function dnsSentReady() { return Promise.all([ dnsSent, reportSaved, policySaved ]); }

// A strongSwan upgraded on disk but not restarted is explained, not shown as
// a code.
const pendingPage = setupView.render([
	{ stdout: setupValue },
	{ stdout: doctorOut + '\nstrongswan_running=warn:6.0.3-restart-pending-6.0.7' +
		'\nstrongswan_eap_server_security=warn:6.0.3-r2-cve-2026-47895-awaiting-feed' },
	{ stdout: '' }, { stdout: '' }, { stdout: '' }, { stdout: '' }
]);
const pendingText = textOf(pendingPage);
if (!/6\.0\.3 runs; the installed 6\.0\.7 takes effect when charon restarts/.test(pendingText))
	fail('a strongSwan waiting for a restart is not explained on the overview');
if (!/vulnerable \(CVE-2026-47895\); waiting for a fixed package in the feed/.test(pendingText))
	fail('the overview does not explain the vulnerability warning');
if (/restart-pending/.test(pendingText))
	fail('the overview shows the raw restart code');

// A full-route device row offers to send what is never to go through the
// tunnel to WAN; the box says what is stored and sends the device's address.
const respectCalls = [];
const fullRoutePage = setupView.render([
	{ stdout: setupValue }, { stdout: doctorOut }, { stdout: '' },
	{ stdout: 'addr=192.168.1.40 mode=fullroute respect=1\n' }, { stdout: '' }, { stdout: '' }
]);
const respectBox = nodesOf(fullRoutePage).find(function(node) {
	return node.tagName === 'INPUT' && /never go through the tunnel/.test(node.attrs['aria-label'] || '');
});
if (!respectBox || !respectBox.checked)
	fail('a full-route device row does not show that it respects the exclusions');
// After the other checks that stub exec, and once the job has started.
const respectStored = Promise.resolve().then(dnsSentReady).then(function() {
	const execBefore = fsStub.exec;
	fsStub.exec = function(file, args) { respectCalls.push((args || []).join(' ')); return Promise.resolve({ code: 0, stdout: '' }); };
	respectBox.checked = false;
	respectBox.listeners.change();
	return new Promise(function(resolve) { setImmediate(resolve); }).then(function() {
		fsStub.exec = execBefore;
		if (respectCalls[0] !== 'device-async set-included 192.168.1.40 0')
			fail('unticking the box does not store it for the device: ' + JSON.stringify(respectCalls));
	});
});

// A dnsmasq that does not resolve as Reliable mode set it up is named as the
// reason the mode is degraded.
const degradedPage = setupView.render([
	{ stdout: [ 'configured=1', 'routing_paused=0', 'domain_engine=fakeip',
		'domain_service=running', 'domain_healthy=no', 'domain_state=error',
		'domain_dnsmasq_resolver=mismatch', 'domain_nft=active', 'domain_rule=active' ].join('\n') },
	{ stdout: doctorOut }, { stdout: '' }, { stdout: '' }, { stdout: '' }, { stdout: '' }
]);
if (textOf(degradedPage).indexOf('dnsmasq does not resolve the way reliable mode set it up.') < 0)
	fail('the overview does not name dnsmasq as the reason Reliable mode is degraded');
const setupNodes = nodesOf(setupPage);
const setupText = textOf(setupPage);
function button(label) {
	return setupNodes.find(function(node) {
		return node.tagName === 'BUTTON' && textOf(node).trim() === label;
	});
}
// Dependencies show only what needs attention; the rest sits behind a toggle.
if (setupText.indexOf('Technical details') < 0)
	fail('the dependency details are not behind their toggle');
// Pause and the restarts are one block of rows, each with its button.
if (setupText.indexOf('Routing control') < 0 || setupText.indexOf('Tunnel routing') < 0)
	fail('the overview has no routing control block with the pause row');
if (setupText.indexOf('Manual recovery') >= 0)
	fail('the recovery actions are still a separate block');
if (!button('Resume tunnel routing'))
	fail('a paused router offers no resume button');
// A pause leaves routing in place and only refuses what reaches the tunnel,
// so a rebuild stays available, and the page says what the pause does.
const rebuild = button('Restart policy routing');
if (!rebuild || rebuild.disabled)
	fail('the policy routing rebuild is withheld while routing is paused');
if (setupText.indexOf('none of them goes through WAN') < 0)
	fail('the paused overview does not say that nothing leaks to WAN');

// The policy editor lives in its own application and had no render coverage at
// all, which is where the raw status dump survived unnoticed.
function loadEditor() {
	const src = fs.readFileSync(path.join(root, 'luci-ikev2-domains', 'editor.js'), 'utf8');
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'uci',
		'view', 'poll', 'common' ];
	const values = [ windowStub, documentStub, L, baseclass, E, fsStub, uiStub, {},
		{ extend: function(o) { return o; } }, pollStub, common ];
	return new Function(names.join(','), src).apply(null, values);
}
const editor = loadEditor();
if (typeof editor.render !== 'function')
	fail('editor.js does not return a view with render()');
const policyStatus = [
	'state=ok', 'updated=2026-08-30 11:58:52 +0300', 'services=16',
	'domains=121', 'cidrs=14', 'custom_cidrs=0', 'selected=openai,telegram'
].join('\n');
const editorSources = [
	'now=1789300000', 'stale_after=604800', 'refresh_interval=86400',
	'refresh_last_attempt=1789290000', 'refresh_last_success=1789280000',
	'refresh_last_error=1789290000', 'refresh_due=0',
	'---service---', 'service=zoom', 'label=zoom',
	'domains_origin=bundled', 'domains_bundled=5',
	'networks_origin=vendor', 'networks_url=https://assets.zoom.us/docs/ipranges/ZoomMeetings.txt',
	'networks_bundled=49', 'networks_entries=49', 'networks_fetched=1788000000',
	'networks_changed=1787000000', 'networks_added=2', 'networks_removed=1',
	'networks_sha256=' + '0123456789abcdef'.repeat(4), 'networks_stale=1',
	'networks_failed=1789290000', 'networks_error=download failed',
	'---service---', 'service=telegram', 'label=telegram',
	'domains_origin=community', 'domains_url=https://lists.invalid/telegram.lst',
	'domains_entries=20', 'domains_fetched=1789280000'
].join('\n');
let editorPage;
try {
	editorPage = editor.render([
		'example.com\n', 'openai telegram', policyStatus,
		{ code: 0, stdout: '' }, 'example.com\n',
		{ code: 0, stdout: 'engine=fakeip\nservice=running\nnft=active\nrule=active' },
		'203.0.113.10\n',
		{ code: 0, stdout: editorSources }
	]);
} catch (error) {
	fail('editor.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!editorPage || !editorPage.children || !editorPage.children.length)
	fail('editor.js render() produced an empty page');

const editorSource = fs.readFileSync(path.join(root, 'luci-ikev2-domains', 'editor.js'), 'utf8');
// The policy state is reported by the header pill and the save result. The page
// must not grow a status readout of its own again: the last one was a raw
// key=value dump that duplicated the chips beside it.
if (editorSource.indexOf('ikev2-status-line') >= 0)
	fail('the policy page has a status readout again');
if (/lines\.push\('selected=' \+ st\.selected\)/.test(editorSource))
	fail('the policy page still dumps raw status keys');
if (editorSource.indexOf("common.setPill(policyPill") < 0)
	fail('the policy page no longer reports its state at all');
// The list sources section reads the helper's ledger and starts a detached
// forced refresh; an empty selection must render too.
if (editorSource.indexOf("fs.exec(communityHelper, [ 'sources' ])") < 0)
	fail('the policy page does not read list sources');
if (editorSource.indexOf("startArgs: [ 'refresh-schedule', 'force' ]") < 0)
	fail('the policy page cannot start a list update');
// Never through the tunnel: two lists beside the two routed ones, saved with
// them, and services of one's own that exclude are marked in the catalogue.
const excludePage = editor.render([
	'example.com\n', 'banks openai', policyStatus,
	{ code: 0, stdout: 'banks|Banks|custom|1|1|exclude\nopenai|openai|builtin|0|0|route\n' },
	'example.com\n', { code: 0, stdout: 'engine=fakeip' }, '203.0.113.10\n',
	{ code: 0, stdout: 'now=1789300000' }, 'bank.example\n', '192.0.2.7\n'
]);
const byId = {};
collect(excludePage, function(node) { return node.attrs && node.attrs.id; }, []).forEach(function(node) {
	byId[node.attrs.id] = node;
});
[ 'ikev2-domain-list', 'ikev2-address-list', 'ikev2-exclude-domain-list', 'ikev2-exclude-address-list' ]
	.forEach(function(id) { if (!byId[id]) fail('the policy page has no ' + id + ' editor'); });
if (textOf(byId['ikev2-exclude-domain-list']).trim() !== 'bank.example' ||
	textOf(byId['ikev2-exclude-address-list']).trim() !== '192.0.2.7')
	fail('the exclusion editors do not show the stored lists');
if (!collect(excludePage, function(node) { return node.tagName === 'SPAN' && textOf(node) === '⊘'; }, []).length)
	fail('an exclusion service is not marked in the catalogue');
Object.keys(byId).forEach(function(id) { byId[id].value = textOf(byId[id]); });
byId['ikev2-exclude-domain-list'].value = 'Bank.Example\n\nother.example';
const policyWrites = {};
const saveStub = { ok() {}, err() {}, warn() {}, busy() {}, clear() {} };
// After the DNS form, which shares the write stub and saves asynchronously.
const policySaved = dnsSent.then(function() {
	fsStub.write = function(file, content) { policyWrites[file.replace(/^.*\./, '')] = content; return Promise.resolve(); };
	const previousQuery = documentStub.querySelector;
	documentStub.querySelector = function(selector) { return byId[selector.replace(/^#/, '')] || null; };
	return Promise.resolve(editor.doSave(saveStub)).then(function() {
		documentStub.querySelector = previousQuery;
		fsStub.write = function() { return Promise.resolve(); };
		if (policyWrites.xdomains !== 'bank.example\nother.example\n' || policyWrites.xcidrs !== '192.0.2.7/32\n')
			fail('the exclusion lists are not saved normalised beside the others: ' + JSON.stringify(policyWrites));
	});
});

try {
	editor.render([ '', '', '', { code: 0, stdout: '' }, '', { code: 0, stdout: '' }, '',
		{ code: 0, stdout: 'now=1789300000\nrefresh_due=1' } ]);
} catch (error) {
	fail('editor.js render() threw with no selected services: ' + (error && error.stack ? error.stack : error));
}

// The inbound server page carries the most controls of any view, so its render
// is exercised too - a restructured section there fails the same silent way.
const settingsView = loadModule('settings.js', common);
if (typeof settingsView.render !== 'function')
	fail('settings.js does not return a view with render()');
const serverGet = [
	'enabled=1', 'identity=vpn.example.com', 'pool4=10.253.10.0/24',
	'gateway4=10.253.10.1', 'dns4=10.253.10.1', 'mtu=1400', 'mobike=1',
	'fragmentation=1', 'dpd=30', 'ike_rekey=4h', 'child_rekey=1h'
].join('\n');
const serverAccess = [
	'local_ts=0.0.0.0/0', 'allow_internet=1', 'allow_lan=1', 'allow_router=1',
	'router_ports=', 'lan_zones=lan', 'firewall_zone=ikev2', 'outbound_zone=wan'
].join('\n');
const settingsData = [
	{ stdout: serverGet }, { stdout: serverAccess }, { stdout: '0' },
	{ stdout: '' }, { stdout: 'identities=vpn.example.com' },
	{ stdout: 'lan=LAN\nwan=WAN' }, { stdout: 'lan=LAN\nwan=WAN' },
	{ stdout: 'wan_interface=wan' }
];
settingsData.ready = true;
let settingsPage;
try {
	settingsPage = settingsView.render(settingsData);
} catch (error) {
	fail('settings.js render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!settingsPage || !settingsPage.children || !settingsPage.children.length)
	fail('settings.js render() produced an empty page');

// Advanced options are reached from a control in the header of the section
// they qualify, not from a disclosure block appended under its controls.
const settingsSource = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'settings.js'), 'utf8');
[ [ 'client.js', source ], [ 'settings.js', settingsSource ] ].forEach(function(entry) {
	if (entry[1].indexOf("'class': 'ikev2-advanced' }") >= 0)
		fail(entry[0] + ' still appends an advanced disclosure block');
	if (entry[1].indexOf('common.advancedPanel(') < 0)
		fail(entry[0] + ' has no advanced panel opened from a section header');
});
// Staging issues certificates clients reject, so it is an advanced option and
// is rendered with the same toggle row as every other switch on the page - not
// as a lone two-column grid whose switch drifted out of alignment.
if (/common\.fieldLabel\(_\('Staging'\)/.test(settingsSource))
	fail('the ACME staging switch is back in a grid row of its own');
if (settingsSource.indexOf("common.toggleRow(acmeStaging") < 0)
	fail('the ACME staging switch is not a toggle row');
if (settingsSource.indexOf('acmeAdvanced.toggle') < 0)
	fail('the ACME panel has no advanced toggle');
// The inbound page opened on three collapsed panels with nothing but the
// server identity visible. Its sections are now flat, each with its own
// advanced toggle for the parts that stay hidden.
if (settingsSource.indexOf("E('details', { 'class': 'ikev2-disclosure' }") >= 0)
	fail('the inbound page still nests its settings in disclosures');
if (settingsSource.indexOf('ikev2-disclosure-stack') >= 0)
	fail('the inbound page still stacks disclosures');
[ 'accessPanel', 'acmePanel', 'behaviorPanel' ].forEach(function(name) {
	if (!new RegExp('var ' + name + ' = common\\.section\\(').test(settingsSource))
		fail(name + ' is not a flat section');
});

// The custom destination editors are sized by a class that has to outrank the
// page-wide textarea floor, or they silently stay at that floor.
const sharedSource = fs.readFileSync(path.join(root, 'luci-ikev2-manager', 'shared.js'), 'utf8');
if (sharedSource.indexOf('.ikev2-page .ikev2-domain-editor {') < 0)
	fail('the domain editor height is set by a selector the textarea floor outranks');
if (sharedSource.indexOf('.ikev2-page .ikev2-domain-editor {') >
	sharedSource.indexOf('.ikev2-page .ikev2-domain-editor-small {'))
	fail('the small editor override is declared before the rule it narrows');

if (typeof common.advancedPanel !== 'function')
	fail('shared.js does not export advancedPanel');
const advanced = common.advancedPanel(makeNode('div', {}), 'Advanced');
if (advanced.panel.style.display !== 'none')
	fail('the advanced panel starts open');
advanced.toggle.listeners.click({});
if (advanced.panel.style.display === 'none')
	fail('the advanced toggle did not open the panel');
advanced.toggle.listeners.click({});
if (advanced.panel.style.display !== 'none')
	fail('the advanced toggle did not close the panel again');

// The overview collects the diagnostics report on the router and has the
// browser save it as a text file.
const reportButton = nodesOf(setupPage).find(function(node) {
	return node.tagName === 'BUTTON' && textOf(node).trim() === 'Download report';
});
if (!reportButton) fail('the overview has no button for the diagnostics report');
const saved = [];
const execCalls = [];
documentStub.body = { appendChild(node) { saved.push(node); return node; } };
fsStub.exec = function(file, args) {
	execCalls.push([ file ].concat(args || []).join(' '));
	return Promise.resolve({ code: 0, stdout: '# IKEv2 manager diagnostics\n' });
};
const reportSaved = Promise.resolve(reportButton.listeners.click()).then(function() {
	if (execCalls.indexOf('/usr/libexec/ikev2-manager-system diagnostics') < 0)
		fail('the report button does not ask the router for the report: ' + JSON.stringify(execCalls));
	if (!saved.some(function(node) { return /^ikev2-diagnostics-[0-9-]+\.txt$/.test(node.attrs.download || ''); }))
		fail('the report is not saved as a dated text file');
});

// The settings backup is made on the router under the passphrase given, and
// a short one is refused before anything is sent.
const backupSaved = respectStored.then(function() {
	const exportButton = nodesOf(setupPage).find(function(node) {
		return node.tagName === 'BUTTON' && textOf(node).trim() === 'Download backup';
	});
	if (!exportButton) fail('the overview has no settings backup');
	const passField = nodesOf(setupPage).find(function(node) {
		return node.tagName === 'INPUT' && node.attrs.placeholder === 'At least eight characters';
	});
	const writes = {};
	const calls = [];
	const files = [];
	fsStub.write = function(file, content) { writes[file.replace(/^.*\./, '')] = content; return Promise.resolve(); };
	fsStub.exec = function(file, args) { calls.push((args || []).join(' ')); return Promise.resolve({ code: 0, stdout: 'SUJFVjI=\n' }); };
	documentStub.body = { appendChild(node) { files.push(node); return node; } };
	// A refused click leaves a listener that restores the button, and the
	// stub returns the last listener's result: wait for the work itself.
	const settle = function() { return new Promise(function(resolve) { setTimeout(resolve, 5); }); };
	passField.value = 'short';
	exportButton.listeners.click();
	return settle().then(function() {
		if (calls.length) fail('a short passphrase reached the router');
		passField.value = 'correct horse battery';
		exportButton.listeners.click();
		return settle();
	}).then(function() {
		if (writes.pass !== 'correct horse battery' || !/^backup-export [A-Za-z0-9-]+$/.test(calls[0] || ''))
			fail('the backup is not made under the given passphrase: ' + JSON.stringify([ writes, calls ]));
		if (!files.some(function(node) { return /\.ikev2backup$/.test(node.attrs.download || ''); }))
			fail('the backup is not saved as a file');
		if (passField.value !== '') fail('the passphrase stays in the form after the download');
		fsStub.write = function() { return Promise.resolve(); };
	});
});

Promise.all([ dnsSent, reportSaved, policySaved, respectStored, backupSaved ]).then(function() {
	process.stdout.write('client UI render tests OK\n');
});
JS
