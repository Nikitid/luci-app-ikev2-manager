'use strict';
'require view';
'require fs';
'require poll';
'require ikev2-manager.shared-v13 as common';

var helper = '/usr/libexec/ikev2-manager';
var systemHelper = '/usr/libexec/ikev2-manager-system';

var dnsProtocols = [
	{ id: 'udp', label: 'DNS over UDP' },
	{ id: 'tcp', label: 'DNS over TCP' },
	{ id: 'dot', label: 'DNS over TLS (DoT)' },
	{ id: 'doh', label: 'DNS over HTTPS (DoH)' },
	{ id: 'h3', label: 'DoH over HTTP/3 only' },
	{ id: 'doq', label: 'DNS over QUIC (DoQ)' },
	{ id: 'dnscrypt', label: 'DNSCrypt' }
];

var dnsProviders = [
	{
		id: 'cloudflare', label: 'Cloudflare',
		udp: 'udp://1.1.1.1:53 udp://1.0.0.1:53',
		tcp: 'tcp://1.1.1.1:53 tcp://1.0.0.1:53',
		dot: 'tls://one.one.one.one',
		doh: 'https://dns.cloudflare.com/dns-query',
		doh3: 'https://dns.cloudflare.com/dns-query',
		h3: 'h3://dns.cloudflare.com/dns-query',
		bootstrap_doh: 'https://1.1.1.1/dns-query https://1.0.0.1/dns-query',
		bootstrap_dot: 'tls://1.1.1.1 tls://1.0.0.1',
		bootstrap: '1.1.1.1:53 1.0.0.1:53'
	},
	{
		id: 'google', label: 'Google Public DNS',
		udp: 'udp://8.8.8.8:53 udp://8.8.4.4:53',
		tcp: 'tcp://8.8.8.8:53 tcp://8.8.4.4:53',
		dot: 'tls://dns.google',
		doh: 'https://dns.google/dns-query',
		doh3: 'https://dns.google/dns-query',
		h3: 'h3://dns.google/dns-query',
		bootstrap_doh: 'https://8.8.8.8/dns-query https://8.8.4.4/dns-query',
		bootstrap_dot: 'tls://8.8.8.8 tls://8.8.4.4',
		bootstrap: '8.8.8.8:53 8.8.4.4:53'
	},
	{
		id: 'quad9', label: 'Quad9 Security',
		udp: 'udp://9.9.9.9:53 udp://149.112.112.112:53',
		tcp: 'tcp://9.9.9.9:53 tcp://149.112.112.112:53',
		dot: 'tls://dns.quad9.net',
		doh: 'https://dns.quad9.net/dns-query',
		bootstrap_doh: 'https://9.9.9.9/dns-query https://149.112.112.112/dns-query',
		bootstrap_dot: 'tls://9.9.9.9 tls://149.112.112.112',
		bootstrap: '9.9.9.9:53 149.112.112.112:53'
	},
	{
		id: 'adguard', label: 'AdGuard DNS',
		udp: 'udp://94.140.14.14:53 udp://94.140.15.15:53',
		tcp: 'tcp://94.140.14.14:53 tcp://94.140.15.15:53',
		dot: 'tls://dns.adguard-dns.com',
		doh: 'https://dns.adguard-dns.com/dns-query',
		doh3: 'https://dns.adguard-dns.com/dns-query',
		doq: 'quic://dns.adguard-dns.com',
		dnscrypt: 'sdns://AQMAAAAAAAAAETk0LjE0MC4xNC4xNDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20',
		bootstrap_doh: 'https://94.140.14.14/dns-query https://94.140.15.15/dns-query',
		bootstrap_dot: 'tls://94.140.14.14 tls://94.140.15.15',
		bootstrap: '94.140.14.14:53 94.140.15.15:53'
	},
	{
		id: 'adguard_unfiltered', label: 'AdGuard DNS — unfiltered',
		udp: 'udp://94.140.14.140:53 udp://94.140.14.141:53',
		tcp: 'tcp://94.140.14.140:53 tcp://94.140.14.141:53',
		dot: 'tls://unfiltered.adguard-dns.com',
		doh: 'https://unfiltered.adguard-dns.com/dns-query',
		doh3: 'https://unfiltered.adguard-dns.com/dns-query',
		doq: 'quic://unfiltered.adguard-dns.com',
		dnscrypt: 'sdns://AQMAAAAAAAAAEjk0LjE0MC4xNC4xNDA6NTQ0MyC16ETWuDo-PhJo62gfvqcN48X6aNvWiBQdvy7AZrLa-iUyLmRuc2NyeXB0LnVuZmlsdGVyZWQubnMxLmFkZ3VhcmQuY29t',
		bootstrap: '94.140.14.140:53 94.140.14.141:53'
	},
	{
		id: 'controld', label: 'Control D — unfiltered',
		udp: 'udp://76.76.2.0:53 udp://76.76.10.0:53',
		tcp: 'tcp://76.76.2.0:53 tcp://76.76.10.0:53',
		dot: 'tls://p0.freedns.controld.com',
		doh: 'https://freedns.controld.com/p0',
		doq: 'quic://p0.freedns.controld.com',
		bootstrap: '76.76.2.0:53 76.76.10.0:53'
	},
	{
		id: 'mullvad', label: 'Mullvad DNS',
		dot: 'tls://dns.mullvad.net',
		doh: 'https://dns.mullvad.net/dns-query',
		bootstrap: '194.242.2.2:53'
	},
	{
		id: 'yandex', label: 'Yandex DNS',
		udp: 'udp://77.88.8.8:53 udp://77.88.8.1:53',
		tcp: 'tcp://77.88.8.8:53 tcp://77.88.8.1:53',
		dot: 'tls://common.dot.dns.yandex.net',
		doh: 'https://common.dot.dns.yandex.net/dns-query',
		bootstrap_doh: 'https://77.88.8.8/dns-query https://77.88.8.1/dns-query',
		bootstrap_dot: 'tls://77.88.8.8 tls://77.88.8.1',
		bootstrap: '77.88.8.8:53 77.88.8.1:53'
	}
];

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

function splitDnsList(value) {
	return (value || '').trim().split(/\s+/).filter(Boolean);
}

function configuredDnsValue(values, key, currentKey, defaultValue) {
	if (Object.prototype.hasOwnProperty.call(values, key))
		return values[key] || '';
	if (currentKey && Object.prototype.hasOwnProperty.call(values, currentKey))
		return values[currentKey] || '';
	return defaultValue || '';
}

function parseDnsSegments(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').filter(Boolean).map(function(line) {
		var out = {};
		line.split('\t').forEach(function(field) {
			var eq = field.indexOf('=');
			if (eq > 0) out[field.slice(0, eq)] = field.slice(eq + 1);
		});
		return out.id ? out : null;
	}).filter(Boolean);
}

function dnsEndpointProtocol(value) {
	if (value.indexOf('udp://') === 0) return 'udp';
	if (value.indexOf('tcp://') === 0) return 'tcp';
	if (value.indexOf('tls://') === 0) return 'dot';
	if (value.indexOf('https://') === 0) return 'doh';
	if (value.indexOf('h3://') === 0) return 'h3';
	if (value.indexOf('quic://') === 0) return 'doq';
	if (value.indexOf('sdns://') === 0) return 'dnscrypt';
	return 'unknown';
}

function dnsProtocolById(id) {
	if (id === 'plain')
		return { id: 'plain', label: 'Plain DNS (IPv4:port)' };
	return dnsProtocols.filter(function(entry) { return entry.id === id; })[0] || null;
}

// A bootstrap entry is either a bare IPv4 authority or an encrypted endpoint
// whose host is one, so its scheme is read the same way with plain as a case of
// its own.
function dnsBootstrapProtocol(value) {
	if (/^\d+\.\d+\.\d+\.\d+:\d+$/.test(value))
		return 'plain';
	return dnsEndpointProtocol(value);
}

function validDnsEndpoint(protocol, value) {
	var accepted = {
		udp: 'udp://', tcp: 'tcp://', dot: 'tls://', doh: 'https://',
		doh3: 'https://', h3: 'h3://', doq: 'quic://', dnscrypt: 'sdns://'
	};
	var prefix = accepted[protocol];
	if (!prefix || value.indexOf(prefix) !== 0 || value.length > 2048)
		return false;
	var remainder = value.slice(prefix.length);
	if (protocol === 'dnscrypt')
		return remainder.length >= 8 && /^[A-Za-z0-9_-]+$/.test(remainder);
	var path = '';
	if (protocol === 'doh' || protocol === 'doh3' || protocol === 'h3') {
		var slash = remainder.indexOf('/');
		if (slash <= 0)
			return false;
		path = remainder.slice(slash);
		remainder = remainder.slice(0, slash);
		if (path === '/' || !/^\/[A-Za-z0-9._~:/?%+=,&;@-]+$/.test(path))
			return false;
	}
	if (!remainder || /[\/?#@\[\]]/.test(remainder))
		return false;
	var parts = remainder.split(':');
	if (parts.length > 2)
		return false;
	if (parts.length === 2) {
		if (!/^\d+$/.test(parts[1]))
			return false;
		var port = Number(parts[1]);
		if (port < 1 || port > 65535)
			return false;
	}
	var host = parts[0];
	if (/^\d+(?:\.\d+){3}$/.test(host)) {
		var octets = host.split('.');
		return octets.every(function(octet) { return Number(octet) <= 255; });
	}
	if (/^[0-9.]+$/.test(host) || host.length > 253)
		return false;
	return host.split('.').every(function(label) {
		return label.length >= 1 && label.length <= 63 &&
			/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label);
	});
}

// Mirrors the runtime: the primary group may mix transports, so each endpoint
// is checked against the protocol its own scheme names rather than against one
// protocol chosen for the whole group.
function validDnsEndpointAny(value) {
	var protocol = dnsEndpointProtocol(value);
	return protocol !== 'unknown' && validDnsEndpoint(protocol, value);
}

function validBootstrapEndpoint(value) {
	var match = value.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+):(\d+)$/);
	if (match) {
		for (var i = 1; i <= 4; i++)
			if (Number(match[i]) > 255)
				return false;
		var port = Number(match[5]);
		return port >= 1 && port <= 65535;
	}
	// An encrypted bootstrap entry must not need a resolver of its own, so only
	// a literal IPv4 authority qualifies. This is what keeps the whole ladder
	// off plaintext UDP/53 when that is the thing being dropped.
	var protocol = dnsEndpointProtocol(value);
	if (protocol !== 'doh' && protocol !== 'dot' && protocol !== 'doq')
		return false;
	if (!validDnsEndpoint(protocol, value))
		return false;
	var authority = value.slice(value.indexOf('://') + 3).split('/')[0];
	var host = authority.split(':')[0];
	if (!/^\d+(?:\.\d+){3}$/.test(host))
		return false;
	return host.split('.').every(function(octet) { return Number(octet) <= 255; });
}

// Presets used to live in a separate row with their own picker, then in a flat
// datalist hanging off the field. Neither let you say "give me Quad9 over DoT":
// the picker belonged to a different field, and a datalist cannot be grouped -
// the HTML spec has no optgroup inside one. Each row now names the protocol and
// the provider, and the endpoint they resolve to stays an editable text field,
// so the two selects are a shortcut rather than a gate.
//
// options.protocol   - fixed protocol for the whole editor (no protocol select)
// options.choosable   - one protocol select per row
// options.protocols   - restrict that select to these protocol ids
// options.max         - the most entries the router accepts; Add greys out there
// options.bootstrap   - literal IPv4 authorities, encrypted or plain
function dnsEndpointEditor(value, placeholder, addLabel, emptyLabel, options) {
	options = options || {};
	var groupProtocol = options.protocol || (options.bootstrap ? 'plain' : 'doh');
	var offered = (options.protocols || dnsProtocols.map(function(entry) {
		return entry.id;
	})).map(function(id) {
		return dnsProtocolById(id);
	}).filter(Boolean);
	var list = E('div', { 'class': 'ikev2-dns-endpoints' });
	var add = E('button', {
		'class': 'cbi-button cbi-button-action',
		'type': 'button'
	}, [ addLabel ]);
	var rows = [];

	// The router takes a fixed number of entries for some lists; offering a
	// fifth row only led to a refusal whose wording blamed the addresses.
	function syncAdd() {
		add.disabled = !!options.max && rows.length >= options.max;
		add.title = add.disabled ? _('At most %d entries').format(options.max) : '';
	}

	// A provider entry is a space-separated list; a row holds one endpoint, so
	// offering the whole list would overwrite the row with several addresses.
	function providerEndpoints(provider, protocol) {
		if (!options.bootstrap)
			return splitDnsList(provider[protocol]);
		// A bootstrap authority must be a literal IPv4 address, so it comes from
		// the provider's verified literal endpoints rather than its named ones.
		if (protocol === 'plain')
			return splitDnsList(provider.bootstrap);
		return splitDnsList(provider['bootstrap_' + protocol]);
	}

	function providerFor(endpoint, protocol) {
		for (var i = 0; i < dnsProviders.length; i++)
			if (providerEndpoints(dnsProviders[i], protocol).indexOf(endpoint) >= 0)
				return dnsProviders[i];
		return null;
	}

	function makeRow(item) {
		var row = { protocol: groupProtocol };
		var field = input('text', item, { 'placeholder': placeholder });
		var provider = E('select', { 'class': 'cbi-input-select' });
		var protocol = options.choosable ?
			E('select', { 'class': 'cbi-input-select' },
				offered.map(function(entry) {
					return E('option', { 'value': entry.id }, [ _(entry.label) ]);
				})) : null;

		// The list is rebuilt for the active protocol, so a provider that does
		// not publish it never appears - the grouping the flat list could not do.
		function fillProviders() {
			provider.replaceChildren(E('option', { 'value': '' }, [ _('Custom') ]));
			dnsProviders.forEach(function(entry) {
				if (!providerEndpoints(entry, row.protocol).length)
					return;
				provider.appendChild(E('option', { 'value': entry.id }, [ entry.label ]));
			});
		}

		// Typing is the source of truth: the selects follow the text, and fall
		// back to Custom when it stops matching anything known.
		function syncFromField() {
			var current = field.value.trim();
			if (options.choosable && current) {
				var detected = options.bootstrap ?
					dnsBootstrapProtocol(current) : dnsEndpointProtocol(current);
				if (detected !== 'unknown' && detected !== row.protocol) {
					row.protocol = detected;
					protocol.value = detected;
					fillProviders();
				}
			}
			var match = current ? providerFor(current, row.protocol) : null;
			provider.value = match ? match.id : '';
		}

		// Prefer an address of that provider the editor is not already using, so
		// picking the same provider twice gives the secondary rather than a
		// duplicate of the primary.
		function applyProvider() {
			var entry = dnsProviders.filter(function(candidate) {
				return candidate.id === provider.value;
			})[0];
			if (!entry)
				return;
			var used = values();
			var endpoints = providerEndpoints(entry, row.protocol);
			var free = endpoints.filter(function(endpoint) {
				return used.indexOf(endpoint) < 0;
			});
			field.value = (free.length ? free : endpoints)[0] || '';
		}

		if (protocol) {
			protocol.value = row.protocol;
			protocol.addEventListener('change', function() {
				row.protocol = protocol.value;
				fillProviders();
				applyProvider();
			});
		}
		provider.addEventListener('change', applyProvider);
		field.addEventListener('input', syncFromField);
		field.addEventListener('change', syncFromField);

		var remove = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'type': 'button',
			'title': _('Remove'),
			'aria-label': _('Remove')
		}, [ '×' ]);
		remove.addEventListener('click', function() {
			rows = rows.filter(function(entry) { return entry !== row; });
			row.node.remove();
			if (!rows.length)
				render([]);
			syncAdd();
		});

		fillProviders();
		row.field = field;
		row.protocolSelect = protocol;
		row.providerSelect = provider;
		row.setProtocol = function(next) {
			if (protocol || row.protocol === next)
				return;
			row.protocol = next;
			fillProviders();
			syncFromField();
		};
		// Flat, so the row is one grid: nesting the controls in wrappers sized
		// every row by its own longest option label, and the columns stopped
		// lining up between rows of the same list.
		row.node = E('div', { 'class': 'ikev2-dns-endpoint' },
			(protocol ? [ protocol ] : []).concat([ provider, field, remove ]));
		syncFromField();
		return row;
	}

	function values() {
		return rows.map(function(row) {
			return row.field.value.trim();
		}).filter(Boolean);
	}

	function render(items) {
		rows = [];
		list.replaceChildren();
		if (!items.length) {
			list.appendChild(E('div', { 'class': 'ikev2-dns-empty' }, [ emptyLabel ]));
			syncAdd();
			return;
		}
		items.forEach(function(item) {
			var row = makeRow(item);
			rows.push(row);
			list.appendChild(row.node);
		});
		syncAdd();
	}

	function append(items) {
		var next = values();
		splitDnsList(items).forEach(function(item) {
			if (next.indexOf(item) < 0)
				next.push(item);
		});
		render(next);
	}

	add.addEventListener('click', function() {
		render(values().concat(''));
		if (rows.length)
			rows[rows.length - 1].field.focus();
	});

	render(splitDnsList(value));
	return {
		node: E('div', {
			'class': 'ikev2-dns-editor' +
				(options.choosable ? ' ikev2-dns-editor-choosable' : '')
		}, [
			list,
			E('div', { 'class': 'ikev2-dns-editor-actions' }, [ add ])
		]),
		values: values,
		append: append,
		set: function(items) { render(splitDnsList(items)); },
		setProtocol: function(next) {
			groupProtocol = next;
			rows.forEach(function(row) { row.setProtocol(next); });
		}
	};
}

// "key=value" lines of tunnels-get, one group per "tunnel=N".
function parseTunnels(stdout) {
	var tunnels = [], current = null;
	String(stdout || '').split('\n').forEach(function(line) {
		var at = line.indexOf('=');
		if (at < 1)
			return;
		var key = line.slice(0, at), value = line.slice(at + 1);
		if (key === 'tunnel') {
			current = { index: value };
			tunnels.push(current);
		}
		else if (current)
			current[key] = value;
	});
	return tunnels;
}

// One line a tunnel from tunnels-status: "tunnel=N up=0|1 address=A carries=1,2".
function parseTunnelStatus(stdout) {
	var status = {};
	String(stdout || '').split('\n').forEach(function(line) {
		var item = {};
		line.split(' ').forEach(function(pair) {
			var at = pair.indexOf('=');
			if (at > 0)
				item[pair.slice(0, at)] = pair.slice(at + 1);
		});
		if (item.tunnel)
			status[item.tunnel] = item;
	});
	return status;
}

function findOutbound(sas) {
	for (var i = 0; i < sas.length; i++) {
		if (sas[i]['proxy-out'])
			return sas[i]['proxy-out'];
	}
	return null;
}

function writeProfileInput(value) {
	var token = common.inputToken();
	return fs.write('/var/run/ikev2-manager-profile-' + token + '.in', value, 384)
		.then(function() { return token; });
}

function runManagerJob(button, result, args, busy, success, failure, timeout, onSuccess) {
	return common.runJob({
		button: button,
		result: result,
		busy: busy,
		success: success,
		failure: failure,
		startPath: helper,
		startArgs: args,
		statusPath: helper,
		statusArgs: [ 'action-status' ],
		timeout: timeout || 120000,
		allowImmediate: true,
		timeoutMessage: _('The operation continues in the background. You can use the button again.'),
		onSuccess: onSuccess
	});
}

var qualityHelper = '/usr/libexec/ikev2-tunnel-quality';
var svgNS = 'http://www.w3.org/2000/svg';

// The same service measures both paths, or the comparison means nothing.
var speedServices = [
	{ id: 'cloudflare', label: 'Cloudflare', upload: true },
	{ id: 'hetzner', label: _('Hetzner, Germany') },
	{ id: 'ovh', label: _('OVH, France') },
	{ id: 'selectel', label: _('Selectel, Russia'),
		hint: _('a server in Russia is reached through the VPS and back, so the figure measures that detour.') },
	{ id: 'custom', label: _('Custom file URL') }
];

var qualityWindows = [
	{ id: '1h', label: _('1 h'), tick: 900 },
	{ id: '6h', label: _('6 h'), tick: 3600 },
	{ id: '24h', label: _('24 h'), tick: 21600 }
];

function svgNode(name, attrs, parent) {
	var node = document.createElementNS(svgNS, name);
	Object.keys(attrs || {}).forEach(function(key) { node.setAttribute(key, attrs[key]); });
	if (parent)
		parent.appendChild(node);
	return node;
}

// The helper prints "-" for a value it could not measure.
function qualityNumber(value) {
	var n = parseFloat(value);
	return isFinite(n) ? n : null;
}

function parseQualityPoints(text) {
	return String(text || '').split(';').filter(Boolean).map(function(item) {
		var f = item.split(',');
		return {
			ts: Number(f[0]), rtt: qualityNumber(f[1]), rttMax: qualityNumber(f[2]),
			loss: qualityNumber(f[3]), wan: qualityNumber(f[4]), wanLoss: qualityNumber(f[5]),
			state: f[6] || 'none', rx: qualityNumber(f[7]), tx: qualityNumber(f[8]),
			maint: f[9] && f[9] !== '-' ? f[9] : ''
		};
	});
}

function parseQualityEvents(text) {
	return String(text || '').split(';').filter(Boolean).map(function(item) {
		var f = item.split(',');
		return { ts: Number(f[0]), kind: f[1] || '', source: f[2] || '', detail: f.slice(3).join(',') };
	});
}

function localNumber(value, digits) {
	var lang = ((document.documentElement && document.documentElement.lang) || 'en').replace('_', '-');
	try {
		return Number(value).toLocaleString(lang, { maximumFractionDigits: digits });
	}
	catch (e) {
		return String(Number(value).toFixed(digits));
	}
}

function formatMs(value) {
	if (value == null)
		return '-';
	return _('%s ms').format(localNumber(value, value >= 10 ? 0 : 1));
}

// Availability lives between 99 and 100, where the decimal is the news.
function formatPercent(value, digits) {
	if (value == null)
		return '-';
	if (digits == null)
		digits = value >= 10 || value === 0 ? 0 : 1;
	return _('%s%%').format(localNumber(value, value >= 100 ? 0 : digits));
}

function formatRate(bps) {
	if (bps == null)
		return '-';
	if (bps < 1e6)
		return _('%s kbit/s').format(localNumber(bps / 1e3, 0));
	return _('%s Mbit/s').format(localNumber(bps / 1e6, bps < 1e7 ? 1 : 0));
}

function formatClock(seconds) {
	var lang = ((document.documentElement && document.documentElement.lang) || 'en').replace('_', '-');
	return new Intl.DateTimeFormat(lang, { hour: '2-digit', minute: '2-digit' })
		.format(new Date(seconds * 1000));
}

// The first solid background behind the page. Solid surfaces - the chart
// readout, the pressed segment, the ring around an event marker - have to
// match the theme, and every LuCI theme paints its own.
function pageBackground() {
	var nodes = [ document.body, document.documentElement ];
	for (var i = 0; i < nodes.length; i++) {
		if (!nodes[i] || !window.getComputedStyle)
			continue;
		var color = window.getComputedStyle(nodes[i]).backgroundColor;
		if (color && color !== 'transparent' && !/rgba\([^)]*,\s*0\)$/.test(color))
			return color;
	}
	return '';
}

// A monotone cubic through the points: smooth, and never swinging past a
// sample, so a latency curve does not dip below zero or invent a peak.
function monotonePath(points) {
	var n = points.length;
	if (n === 1)
		return 'M' + (points[0].x - 1.5) + ',' + points[0].y + 'H' + (points[0].x + 1.5);
	var d = [], m = [], i;
	for (i = 0; i < n - 1; i++)
		d.push((points[i + 1].y - points[i].y) / ((points[i + 1].x - points[i].x) || 1));
	m.push(d[0]);
	for (i = 1; i < n - 1; i++)
		m.push(d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2);
	m.push(d[n - 2]);
	for (i = 0; i < n - 1; i++) {
		if (d[i] === 0) {
			m[i] = 0;
			m[i + 1] = 0;
			continue;
		}
		var a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b;
		if (s > 9) {
			var t = 3 / Math.sqrt(s);
			m[i] = t * a * d[i];
			m[i + 1] = t * b * d[i];
		}
	}
	var path = 'M' + points[0].x.toFixed(1) + ',' + points[0].y.toFixed(1);
	for (i = 0; i < n - 1; i++) {
		var dx = (points[i + 1].x - points[i].x) / 3;
		path += 'C' + (points[i].x + dx).toFixed(1) + ',' + (points[i].y + m[i] * dx).toFixed(1) +
			' ' + (points[i + 1].x - dx).toFixed(1) + ',' + (points[i + 1].y - m[i + 1] * dx).toFixed(1) +
			' ' + points[i + 1].x.toFixed(1) + ',' + points[i + 1].y.toFixed(1);
	}
	return path;
}

// Runs of buckets that have a value. The watcher samples every 60-70 seconds,
// so a one-minute bucket is sometimes simply empty: up to two empty buckets
// are bridged. A sample without a value - the tunnel was down - and a longer
// silence both break the line instead of drawing through them.
function valueRuns(items, key) {
	var runs = [], run = [], empty = 0;
	items.forEach(function(item) {
		if (item.state === 'none' && ++empty <= 2)
			return;
		if (item[key] == null) {
			if (run.length)
				runs.push(run);
			run = [];
		}
		else {
			run.push(item);
			empty = 0;
		}
	});
	if (run.length)
		runs.push(run);
	return runs;
}

// The smallest 1, 2, 2.5 or 5 times a power of ten that is at least VALUE.
function niceStep(value) {
	var power = Math.pow(10, Math.floor(Math.log10(Math.max(value, 1e-6))));
	var steps = [ 1, 2, 2.5, 5, 10 ];
	for (var i = 0; i < steps.length; i++)
		if (steps[i] * power >= value)
			return steps[i] * power;
	return 10 * power;
}

// What an operator action is called in the event list and on the chart. The
// kinds are the backends' own action names.
var qualityActions = {
	'set': _('Router settings applied'),
	'coverage-add': _('Network added to policy routing'),
	'coverage-remove': _('Network removed from policy routing'),
	'device': _('Device routing changed'),
	'pbr-restart': _('Policy routing restarted'),
	'apply': _('Firewall, policy routing and strongSwan applied'),
	'connect': _('Tunnel reconnected'),
	'client-connect': _('Tunnel settings saved and reconnected'),
	'advanced-set': _('Custom strongSwan config saved'),
	'advanced-reset': _('strongSwan config reset to generated'),
	'server-apply': _('Inbound server applied'),
	'recover-reliable': _('Reliable mode restarted'),
	'routing-pause': _('Tunnel routing paused'),
	'routing-resume': _('Tunnel routing resumed')
};

function qualityEvent(event) {
	var seconds = Number(event.detail) || 0;
	switch (event.kind) {
	case 'outage':
		return { tone: 'bad', text: event.detail === 'noreply' ?
			_('The tunnel stopped carrying traffic') : _('The tunnel went down') };
	case 'restored':
		return { tone: 'good', text: _('Connection restored after %s').format(common.formatDuration(seconds)) };
	case 'reconnect':
		return { tone: 'warn', text: seconds > 1 ?
			_('The tunnel reconnected by itself %d times').format(seconds) : _('The tunnel reconnected by itself') };
	case 'resolver-restart':
		return { tone: 'warn', text: event.detail === 'failed' ?
			_('Automatic FakeIP resolver restart failed') : _('FakeIP resolver restarted automatically') };
	case 'dns-switch':
		return { tone: 'info', text: _('Tunnel DNS switched to %s').format(event.detail) };
	}
	if (qualityActions[event.kind]) {
		// A window reports how long the action held the tunnel; an event has no
		// length to report.
		return { tone: 'info', text: event.detail && event.detail !== '-' && isFinite(Number(event.detail)) ?
			_('%s by hand, %s').format(qualityActions[event.kind], common.formatDuration(seconds)) :
			_('%s by hand').format(qualityActions[event.kind]) };
	}
	return { tone: '', text: event.kind };
}

var qualityVerdicts = {
	good: { tone: 'good', text: _('Good') },
	fair: { tone: 'warn', text: _('Unstable') },
	poor: { tone: 'bad', text: _('Poor') },
	down: { tone: 'bad', text: _('No connection') },
	off: { tone: '', text: _('Client disabled') },
	unknown: { tone: '', text: _('Collecting data') }
};

// The latency curve. Everything is drawn in CSS pixels of the current width,
// so text and strokes keep their size; a resize redraws.
function qualityChart() {
	var wrap = E('div', { 'class': 'ikev2-quality-chart' });
	var tip = E('div', { 'class': 'ikev2-quality-tip', 'style': 'display:none' });
	var root = svgNode('svg', { 'role': 'img' });
	wrap.appendChild(root);
	wrap.appendChild(tip);
	var state = null;
	var geometry = null;

	function draw() {
		if (!state)
			return;
		while (root.firstChild)
			root.removeChild(root.firstChild);
		var width = Math.max(wrap.clientWidth || 0, 280) || 720;
		var height = root.getBoundingClientRect ? (root.getBoundingClientRect().height || 224) : 224;
		var left = 44, right = 8, top = 18;
		var plotBottom = height - 42, lossTop = height - 36, lossBottom = height - 24;
		var plotWidth = width - left - right;
		var start = state.generated - state.window;
		var step = state.window / Math.max(state.points.length, 1);
		root.setAttribute('viewBox', '0 0 ' + width + ' ' + height);

		var defs = svgNode('defs', {}, root);
		var gradient = svgNode('linearGradient', { 'id': 'ikev2-quality-fill', 'x1': '0', 'y1': '0', 'x2': '0', 'y2': '1' }, defs);
		svgNode('stop', { 'offset': '0', 'style': 'stop-color:var(--ikev2-accent);stop-opacity:.22' }, gradient);
		svgNode('stop', { 'offset': '1', 'style': 'stop-color:var(--ikev2-accent);stop-opacity:0' }, gradient);

		var peak = 0;
		state.points.forEach(function(p) {
			if (p.rtt != null) peak = Math.max(peak, p.rtt);
			if (p.wan != null) peak = Math.max(peak, p.wan);
		});
		var tick = niceStep(Math.max(peak * 1.15, 10) / 2);
		var yMax = tick * 2;
		function x(ts) { return left + (ts - start) / state.window * plotWidth; }
		function y(value) { return plotBottom - Math.min(value, yMax) / yMax * (plotBottom - top); }

		state.points.forEach(function(p) {
			if (p.state === 'down' || p.state === 'noreply' || p.state === 'off' || p.state === 'maint')
				svgNode('rect', {
					'class': p.state === 'off' ? 'off' : p.state === 'maint' ? 'maint' : 'outage',
					'x': x(p.ts).toFixed(1), 'y': top,
					'width': Math.max(plotWidth / state.points.length, 1).toFixed(1),
					'height': plotBottom - top
				}, root);
		});

		// The unit rides on the top label only; the other two stay bare numbers.
		[ 0, tick, yMax ].forEach(function(value) {
			svgNode('line', { 'class': 'grid', 'x1': left, 'x2': width - right, 'y1': y(value), 'y2': y(value) }, root);
			svgNode('text', { 'class': 'axis', 'x': left - 8, 'y': y(value) + 4, 'text-anchor': 'end' }, root)
				.textContent = value === yMax ? formatMs(value) : localNumber(value, 0);
		});

		var offset = -new Date().getTimezoneOffset() * 60;
		var labelStep = state.tick;
		for (var t = Math.ceil((start + offset) / labelStep) * labelStep - offset; t <= state.generated; t += labelStep) {
			var tx = x(t);
			if (tx < left + 16 || tx > width - right - 16)
				continue;
			svgNode('text', { 'class': 'axis', 'x': tx, 'y': height - 6, 'text-anchor': 'middle' }, root)
				.textContent = formatClock(t);
		}

		function coords(run, key) {
			return run.map(function(p) { return { x: x(p.ts + step / 2), y: y(p[key]) }; });
		}
		valueRuns(state.points, 'wan').forEach(function(run) {
			svgNode('path', { 'class': 'direct', 'd': monotonePath(coords(run, 'wan')) }, root);
		});
		valueRuns(state.points, 'rtt').forEach(function(run) {
			var pts = coords(run, 'rtt');
			var line = monotonePath(pts);
			if (pts.length > 1)
				svgNode('path', { 'class': 'area', 'd': line + 'L' + pts[pts.length - 1].x.toFixed(1) + ',' +
					plotBottom + 'L' + pts[0].x.toFixed(1) + ',' + plotBottom + 'Z' }, root);
			svgNode('path', { 'class': 'tunnel', 'd': line }, root);
		});

		var bucketWidth = plotWidth / Math.max(state.points.length, 1);
		state.points.forEach(function(p) {
			if (!p.loss)
				return;
			var h = Math.max(2, Math.min(1, p.loss / 20) * (lossBottom - lossTop));
			var w = Math.max(1.5, bucketWidth * .6);
			svgNode('rect', {
				'class': 'loss', 'rx': 1,
				'x': (x(p.ts + step / 2) - w / 2).toFixed(1), 'y': (lossBottom - h).toFixed(1),
				'width': w.toFixed(1), 'height': h.toFixed(1)
			}, root);
		});

		state.events.forEach(function(event) {
			if (event.ts < start)
				return;
			var view = qualityEvent(event);
			var dot = svgNode('circle', { 'class': 'event ' + view.tone, 'cx': x(event.ts).toFixed(1), 'cy': 8, 'r': 4 }, root);
			svgNode('title', {}, dot).textContent = formatClock(event.ts) + ' — ' + view.text;
		});

		geometry = { x: x, y: y, left: left, right: width - right, top: top, bottom: plotBottom, width: width, step: step, start: start };
		geometry.cursor = svgNode('line', { 'class': 'cursor', 'y1': top, 'y2': plotBottom, 'style': 'display:none' }, root);
		geometry.dot = svgNode('circle', { 'class': 'cursor-dot', 'r': 4, 'style': 'display:none' }, root);
	}

	function hide() {
		tip.style.display = 'none';
		if (geometry) {
			geometry.cursor.style.display = 'none';
			geometry.dot.style.display = 'none';
		}
	}

	// The readout answers the pointer on every move, with no easing, and the
	// nearest bucket is picked from the pointer's x alone, so a hand moving
	// along the curve never has to aim at it.
	function track(event) {
		if (!state || !geometry || !state.points.length)
			return;
		var box = root.getBoundingClientRect();
		var px = event.clientX - box.left;
		if (px < geometry.left || px > geometry.right)
			return hide();
		var index = Math.min(state.points.length - 1,
			Math.max(0, Math.floor((px - geometry.left) / (geometry.right - geometry.left) * state.points.length)));
		var p = state.points[index];
		if (p.state === 'none')
			return hide();
		var cx = geometry.x(p.ts + geometry.step / 2);
		geometry.cursor.setAttribute('x1', cx);
		geometry.cursor.setAttribute('x2', cx);
		geometry.cursor.style.display = '';
		if (p.rtt != null) {
			geometry.dot.setAttribute('cx', cx);
			geometry.dot.setAttribute('cy', geometry.y(p.rtt));
			geometry.dot.style.display = '';
		}
		else
			geometry.dot.style.display = 'none';
		var rows = [
			E('b', {}, [ geometry.step > 90 ?
				'%s – %s'.format(formatClock(p.ts), formatClock(p.ts + geometry.step)) : formatClock(p.ts) ])
		];
		function row(label, value) {
			rows.push(E('div', {}, [ E('span', {}, [ label + ' ' ]), value ]));
		}
		if (p.state === 'maint')
			row(_('Maintenance'), qualityActions[p.maint] || p.maint);
		else if (p.state === 'down')
			row(_('Tunnel'), _('down'));
		else if (p.state === 'noreply')
			row(_('Tunnel'), _('no traffic'));
		else if (p.state === 'off')
			row(_('Tunnel'), _('disabled'));
		else
			row(_('Tunnel'), formatMs(p.rtt) + (p.rttMax != null && p.rttMax > p.rtt ?
				' · ' + _('peak %s').format(formatMs(p.rttMax)) : ''));
		row(_('Direct'), formatMs(p.wan));
		if (p.loss != null)
			row(_('Loss'), formatPercent(p.loss));
		if (p.rx != null)
			row(_('Traffic'), '↓ %s ↑ %s'.format(formatRate(p.rx), formatRate(p.tx)));
		tip.replaceChildren.apply(tip, rows);
		tip.style.display = '';
		var tipWidth = tip.offsetWidth || 160;
		var place = cx + 14;
		if (place + tipWidth > geometry.width)
			place = cx - 14 - tipWidth;
		tip.style.left = Math.max(0, place) + 'px';
		tip.style.top = (geometry.top + 4) + 'px';
	}

	root.addEventListener('pointermove', track);
	root.addEventListener('pointerdown', track);
	root.addEventListener('pointerleave', hide);
	if (window.ResizeObserver) {
		var width = 0;
		new ResizeObserver(function() {
			if (wrap.clientWidth === width)
				return;
			width = wrap.clientWidth;
			hide();
			draw();
		}).observe(wrap);
	}

	return {
		node: wrap,
		update: function(next) {
			state = next;
			hide();
			root.setAttribute('aria-label', next.label || '');
			draw();
		}
	};
}

function qualitySection(initial) {
	var windowId = '1h';
	var summary = initial || {};
	var generation = 0;
	var busy = {};

	var verdictText = E('b', {});
	var verdictCause = E('span', {});
	var verdictStable = E('span', {});
	var verdict = E('div', { 'class': 'ikev2-quality-verdict', 'aria-live': 'polite' },
		[ verdictText, verdictCause, verdictStable ]);

	function tile(label) {
		var value = E('div', { 'class': 'ikev2-card-value' });
		var detail = E('div', { 'class': 'ikev2-card-detail' });
		return {
			node: E('div', { 'class': 'ikev2-card' }, [ E('div', { 'class': 'ikev2-card-label' }, [ label ]), value, detail ]),
			value: value,
			detail: detail
		};
	}
	var latency = tile(_('Latency'));
	var loss = tile(_('Packet loss'));
	var availability = tile(_('Availability'));
	var jitter = tile(_('Jitter'));

	var chart = qualityChart();
	var empty = E('div', { 'class': 'ikev2-quality-empty', 'style': 'display:none' }, [
		_('Collecting data. The first measurement appears within a minute.')
	]);
	var legend = E('div', { 'class': 'ikev2-quality-legend' }, [
		E('span', {}, [ E('i', { 'class': 'tunnel' }), _('Tunnel latency') ]),
		E('span', {}, [ E('i', { 'class': 'direct' }), _('Direct latency') ]),
		E('span', {}, [ E('i', { 'class': 'loss' }), _('Packet loss') ]),
		E('span', {}, [ E('i', { 'class': 'outage' }), _('No connection') ]),
		E('span', {}, [ E('i', { 'class': 'maint' }), _('Maintenance') ])
	]);

	var eventList = E('ul', { 'class': 'ikev2-quality-events' });
	var eventsQuiet = E('p', { 'class': 'ikev2-quality-quiet' }, [ _('No events in this period.') ]);
	var eventsMore = E('button', { 'class': 'cbi-button', 'type': 'button', 'style': 'display:none;margin-top:.7rem' });
	var eventsExpanded = false;

	var speedResults = E('div', { 'class': 'ikev2-speed-results' });
	var speedMeta = E('p', { 'class': 'ikev2-speed-meta' });
	var speedNote = E('p', { 'class': 'ikev2-speed-meta', 'style': 'display:none' });
	var speedResult = common.inlineResult();
	var speedButton = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button' }, [ _('Test speed') ]);

	// The live panel exists only while a test runs: which transfer is going,
	// its rate, and the router's CPU load, all from the action's own poll.
	var liveStep = E('span', {});
	var liveRate = E('b', {});
	var liveCpuFill = E('span', { 'style': 'transform:scaleX(0)' });
	var liveCpuValue = E('b', {});
	var livePanel = E('div', { 'class': 'ikev2-speed-live', 'style': 'display:none', 'aria-live': 'polite' }, [
		E('div', { 'class': 'ikev2-speed-live-head' }, [ liveStep, liveRate ]),
		E('div', { 'class': 'ikev2-speed-live-cpu' }, [
			E('span', {}, [ _('Router CPU') ]),
			E('div', { 'class': 'ikev2-speed-bar cpu' }, [ liveCpuFill ]),
			liveCpuValue
		])
	]);
	function showLive(status) {
		var path = status.live_path === 'wan' ? _('Direct') : status.live_path === 'tunnel' ? _('Tunnel') : '';
		var direction = status.live_direction === 'up' ? _('Upload') : status.live_direction === 'down' ? _('Download') : '';
		liveStep.textContent = path && direction ? path + ' · ' + direction : _('Preparing...');
		var bps = qualityNumber(status.live_bps);
		liveRate.textContent = bps == null ? '' : formatRate(bps);
		var cpu = qualityNumber(status.live_cpu);
		liveCpuFill.style.transform = 'scaleX(' + Math.min(Math.max(cpu || 0, 0), 100) / 100 + ')';
		liveCpuFill.className = cpu >= 90 ? 'bad' : cpu >= 70 ? 'warn' : '';
		liveCpuValue.textContent = cpu == null ? '-' : formatPercent(cpu, 0);
	}

	function choice(options, value) {
		return E('select', { 'class': 'cbi-input-select' }, options.map(function(option) {
			return E('option', { 'value': option[0], 'selected': option[0] === value ? '' : null }, [ option[1] ]);
		}));
	}
	function serviceById(id) {
		return speedServices.filter(function(item) { return item.id === id; })[0] || speedServices[0];
	}
	// One service picker per path, each with its own custom address.
	function servicePicker(path) {
		var picker = {
			select: choice(speedServices.map(function(item) { return [ item.id, item.label ]; }),
				summary['speed_setting_' + path + '_service'] || 'cloudflare'),
			url: E('input', { 'type': 'text', 'placeholder': 'https://example.net/1GB.bin',
				'value': summary['speed_setting_' + path + '_url'] || '' })
		};
		picker.urlRow = E('div', { 'class': 'ikev2-speed-url' }, [ picker.url ]);
		picker.value = function() {
			return picker.select.value === 'custom' ? picker.url.value.trim() : '-';
		};
		return picker;
	}
	var tunnelPicker = servicePicker('tunnel');
	var wanPicker = servicePicker('wan');
	var speedDirection = choice([
		[ 'down', _('Download') ], [ 'up', _('Upload') ], [ 'both', _('Both') ]
	], summary.speed_setting_direction || 'down');
	var speedStreams = choice([ [ '1', '1' ], [ '4', '4' ], [ '8', '8' ] ], summary.speed_setting_streams || '1');
	var speedHint = E('p', { 'class': 'ikev2-speed-meta' });
	function option(label, control, extra) {
		return E('label', { 'class': 'ikev2-speed-option' }, [ E('span', {}, [ label ]), control, extra || '' ]);
	}
	// An upload needs at least one path on a service that takes it; the other
	// path then reports its upload as unavailable.
	function syncSpeedChoice() {
		var tunnel = serviceById(tunnelPicker.select.value);
		var wan = serviceById(wanPicker.select.value);
		var upload = tunnel.upload || wan.upload;
		Array.prototype.forEach.call(speedDirection.options || [], function(item) {
			item.disabled = !upload && item.value !== 'down';
		});
		if (!upload)
			speedDirection.value = 'down';
		tunnelPicker.urlRow.style.display = tunnel.id === 'custom' ? '' : 'none';
		wanPicker.urlRow.style.display = wan.id === 'custom' ? '' : 'none';
		var hints = [ tunnel.hint ? _('Tunnel: %s').format(tunnel.hint) : '', wan.hint && wan.id !== 'selectel' ? wan.hint : '' ]
			.filter(Boolean);
		speedHint.textContent = hints.join(' ');
		speedHint.style.display = hints.length ? '' : 'none';
	}
	tunnelPicker.select.addEventListener('change', syncSpeedChoice);
	wanPicker.select.addEventListener('change', syncSpeedChoice);
	syncSpeedChoice();

	var segments = qualityWindows.map(function(item) {
		var button = E('button', { 'type': 'button', 'aria-pressed': String(item.id === windowId) }, [ item.label ]);
		button.addEventListener('click', function() {
			if (windowId === item.id)
				return;
			windowId = item.id;
			segments.forEach(function(other, i) {
				other.setAttribute('aria-pressed', String(qualityWindows[i].id === windowId));
			});
			chart.node.classList.add('loading');
			refresh();
		});
		return button;
	});
	var switcher = E('div', { 'class': 'ikev2-seg', 'role': 'group', 'aria-label': _('Period') }, segments);

	function renderEvents(events) {
		var shown = eventsExpanded ? events : events.slice(0, 6);
		eventList.replaceChildren.apply(eventList, shown.map(function(event) {
			var view = qualityEvent(event);
			return E('li', {}, [
				E('time', {}, [ common.formatDateTime(event.ts) ]),
				E('span', { 'class': 'dot ' + view.tone }),
				E('span', {}, [ view.text ])
			]);
		}));
		eventsQuiet.style.display = events.length ? 'none' : '';
		eventsMore.style.display = events.length > 6 ? '' : 'none';
		eventsMore.textContent = eventsExpanded ? _('Show fewer') : _('Show all (%d)').format(events.length);
	}
	eventsMore.addEventListener('click', function() {
		eventsExpanded = !eventsExpanded;
		renderEvents(parseQualityEvents(summary.events));
	});

	// A column per direction: the tunnel and the direct path on one scale, so
	// the shorter bar looks shorter, and the tunnel's share of the direct rate.
	// A transfer the path cut after a few kilobytes says so instead of drawing
	// an empty bar; a service that takes no upload says that.
	// Each redraw built the bars from zero, so a background refresh or a
	// switch of period replayed the grow animation over unchanged figures. A
	// bar starts from the share it last showed and moves only when it changes.
	var shownShare = {};
	function renderSpeed() {
		var columns = [];
		[ [ 'down', _('Download'), '↓' ], [ 'up', _('Upload'), '↑' ] ].forEach(function(direction) {
			var values = [ 'tunnel', 'wan' ].map(function(path) {
				var key = 'speed_' + path + '_' + direction[0];
				var raw = summary[key + '_bps'];
				return {
					key: key,
					path: path,
					raw: raw,
					bps: qualityNumber(raw),
					stalled: summary[key + '_stalled'] === '1'
				};
			});
			if (values[0].raw == null && values[1].raw == null)
				return;
			var top = Math.max(values[0].bps || 0, values[1].bps || 0, 1);
			var rows = values.map(function(item) {
				var share = item.stalled ? 0 : Math.max(item.bps || 0, 0) / top;
				var from = shownShare[item.key] != null ? shownShare[item.key] : 0;
				var fill = E('span', { 'style': 'transform:scaleX(' + from + ')' });
				shownShare[item.key] = share;
				if (from !== share)
					window.requestAnimationFrame(function() {
						fill.style.transform = 'scaleX(' + share + ')';
					});
				var value;
				if (item.stalled)
					value = E('b', { 'class': 'warn', 'title': _('The connection stopped after a few kilobytes: this path cuts transfers to that server.') },
						[ _('cut off') ]);
				else if (item.raw === 'unavailable')
					value = E('b', { 'class': 'muted', 'title': _('This service accepts no uploads.') }, [ _('n/a') ]);
				else if (item.raw === 'limited')
					value = E('b', { 'class': 'warn', 'title': _('The service answered 429: it limits requests from this address for a while. Pick another service.') },
						[ _('rate-limited') ]);
				else
					value = E('b', {}, [ item.bps == null ? _('failed') : formatRate(item.bps) ]);
				return E('div', { 'class': 'ikev2-speed-row' }, [
					E('div', { 'class': 'ikev2-speed-row-head' }, [
						E('span', {}, [ item.path === 'tunnel' ? _('Tunnel') : _('Direct') ]), value
					]),
					E('div', { 'class': 'ikev2-speed-bar ' + (item.path === 'tunnel' ? 'tunnel' : 'direct') }, [ fill ])
				]);
			});
			var ratio = values[0].bps && values[1].bps && !values[0].stalled && !values[1].stalled ?
				E('div', { 'class': 'ikev2-speed-ratio' }, [
					_('Tunnel: %s of direct').format(formatPercent(values[0].bps * 100 / values[1].bps, 0)) ]) : '';
			columns.push(E('div', { 'class': 'ikev2-speed-column' }, [
				E('div', { 'class': 'ikev2-speed-column-title' }, [ direction[2] + ' ' + direction[1] ])
			].concat(rows, [ ratio ])));
		});
		speedNote.style.display = 'none';
		if (!columns.length) {
			speedResults.replaceChildren();
			speedResults.style.display = 'none';
			speedMeta.textContent = _('Not measured yet. Each direction downloads or uploads real data for up to 8 seconds per path; avoid it on a metered connection.');
			return;
		}
		speedResults.style.display = '';
		speedResults.replaceChildren.apply(speedResults, columns);
		var tunnelService = serviceById(summary.speed_tunnel_service || summary.speed_service);
		var wanService = serviceById(summary.speed_wan_service || summary.speed_service);
		var parts = [ tunnelService.id === wanService.id ? tunnelService.label :
			_('Tunnel %s, direct %s').format(tunnelService.label, wanService.label) ];
		if (summary.speed_streams)
			parts.push(Number(summary.speed_streams) > 1 ?
				_('%s streams').format(summary.speed_streams) : _('1 stream'));
		var loaded = qualityNumber(summary.speed_loaded_rtt);
		if (loaded != null)
			parts.push(_('Latency under load %s').format(formatMs(loaded)));
		var cpu = Math.max(qualityNumber(summary.speed_tunnel_down_cpu) || 0, qualityNumber(summary.speed_tunnel_up_cpu) || 0,
			qualityNumber(summary.speed_wan_down_cpu) || 0, qualityNumber(summary.speed_wan_up_cpu) || 0);
		if (cpu)
			parts.push(_('Router CPU up to %s').format(formatPercent(cpu, 0)));
		parts.push(_('Measured %s').format(common.formatDateTime(summary.speed_checked)));
		speedMeta.textContent = parts.join(' · ');
		// The test ends on the router itself, where TLS and the TCP stack run
		// on the CPU. Forwarded traffic of the LAN takes the hardware path.
		if (cpu >= 90) {
			speedNote.textContent = _('The router\'s CPU limited this test: the transfers end on the router, where encryption and the TCP stack run in software. Devices on the LAN going direct are forwarded by hardware offload and are not held back by it. Fewer streams load the router less.');
			speedNote.style.display = '';
		}
	}

	function renderSummary() {
		var samples = Number(summary.samples || 0);
		var view = qualityVerdicts[summary.quality] || qualityVerdicts.unknown;
		verdictText.className = view.tone;
		verdictText.textContent = view.text;
		verdictCause.textContent = summary.quality_cause === 'wan' ?
			_('The direct connection loses packets too: the provider is the likely cause.') :
			summary.quality_cause === 'tunnel' ?
				_('The direct connection is clean: the problem is in the tunnel or beyond it.') : '';
		var stable = Number(summary.stable_since);
		verdictStable.textContent = summary.state === 'up' && stable ?
			_('Stable for %s').format(common.formatDuration(Number(summary.generated) - stable)) : '';

		var p50 = qualityNumber(summary.rtt_p50);
		var overhead = qualityNumber(summary.overhead_ms);
		latency.value.textContent = formatMs(p50);
		latency.detail.textContent = p50 == null ? _('Median of the period') :
			_('95%% under %s').format(formatMs(qualityNumber(summary.rtt_p95))) +
				(overhead != null ? ' · ' + _('+%s over direct').format(formatMs(Math.max(overhead, 0))) : '');
		loss.value.textContent = formatPercent(qualityNumber(summary.loss));
		loss.detail.textContent = _('Direct: %s').format(formatPercent(qualityNumber(summary.wan_loss)));
		availability.value.textContent = formatPercent(qualityNumber(summary.availability), 1);
		var outages = Number(summary.outages || 0);
		var maintained = Number(summary.maintenance_samples || 0);
		availability.detail.textContent = (outages ?
			_('Outages: %d, offline %s').format(outages, common.formatDuration(summary.down_seconds)) :
			_('No outages')) +
			(maintained ? ' · ' + _('%d min of maintenance not counted').format(maintained) : '');
		jitter.value.textContent = formatMs(qualityNumber(summary.jitter));
		var reconnects = Number(summary.reconnects || 0);
		var restarts = Number(summary.resolver_restarts || 0);
		jitter.detail.textContent = _('Reconnects: %d').format(reconnects) +
			(restarts ? ' · ' + _('resolver restarts: %d').format(restarts) : '');

		var windowInfo = qualityWindows.filter(function(item) { return item.id === windowId; })[0];
		empty.style.display = samples ? 'none' : '';
		chart.node.style.display = samples ? '' : 'none';
		legend.style.display = samples ? '' : 'none';
		if (samples)
			chart.update({
				window: Number(summary.window) || 3600,
				generated: Number(summary.generated) || Math.floor(Date.now() / 1000),
				tick: windowInfo.tick,
				points: parseQualityPoints(summary.points),
				events: parseQualityEvents(summary.events),
				label: _('Tunnel latency over the last %s').format(windowInfo.label)
			});
		chart.node.classList.remove('loading');
		renderEvents(parseQualityEvents(summary.events));
		renderSpeed();
	}

	function refresh() {
		var mine = ++generation;
		return L.resolveDefault(fs.exec(qualityHelper, [ 'summary', windowId ]), { stdout: '' })
			.then(function(response) {
				// A slower answer for a window the user has already left.
				if (mine !== generation)
					return;
				summary = common.parseKeyValues((response && response.stdout) || '');
				renderSummary();
			});
	}

	speedButton.addEventListener('click', function() {
		if (busy.speed)
			return;
		busy.speed = true;
		showLive({});
		livePanel.style.display = '';
		common.runJob({
			button: speedButton,
			result: speedResult,
			busy: _('Testing...'),
			failure: _('Speed test failed'),
			startPath: qualityHelper,
			startArgs: [ 'speed-test-async', tunnelPicker.select.value, wanPicker.select.value,
				speedDirection.value, speedStreams.value, tunnelPicker.value(), wanPicker.value() ],
			statusPath: qualityHelper,
			statusArgs: [ 'action-status' ],
			// The live panel names each step; the result beside the button
			// stays for an outcome worth reading.
			progress: false,
			onProgress: function(status) {
				if (status.state === 'running')
					showLive(status);
			},
			timeout: 120000,
			interval: 1000
		}).then(function(status) {
			busy.speed = false;
			livePanel.style.display = 'none';
			// The new figures are the result: no caption to go with them.
			if (status && status.state === 'ok')
				speedResult.clear();
			return refresh();
		});
	});

	var node = common.section(_('Connection quality'),
		_('Measured by the router once a minute: pings through the tunnel and directly over WAN, side by side. History is kept for a day and starts again after a reboot.'),
		E('div', {}, [
			verdict,
			E('div', { 'class': 'ikev2-grid ikev2-quality-grid' }, [
				latency.node, loss.node, availability.node, jitter.node
			]),
			chart.node,
			empty,
			legend,
			E('div', { 'class': 'ikev2-quality-lower' }, [
				E('div', {}, [ E('h4', {}, [ _('Events') ]), eventList, eventsQuiet, eventsMore ]),
				E('div', {}, [
					E('h4', {}, [ _('Speed') ]),
					speedResults,
					speedMeta,
					speedNote,
					livePanel,
					E('div', { 'class': 'ikev2-speed-options' }, [
						option(_('Tunnel service'), tunnelPicker.select, tunnelPicker.urlRow),
						option(_('Direct service'), wanPicker.select, wanPicker.urlRow),
						option(_('Direction'), speedDirection),
						option(_('Streams'), speedStreams)
					]),
					speedHint,
					E('div', { 'class': 'ikev2-actions bar' }, [ speedResult.node, speedButton ])
				])
			])
		]),
		switcher);
	var background = pageBackground();
	if (background)
		node.style.setProperty('--ikev2-bg', background);

	return {
		node: node,
		start: function() {
			renderSummary();
			poll.add(refresh, 60);
		}
	};
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'client-get' ]),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' }),
				fs.exec(helper, [ 'advanced-mode', 'outbound' ]),
				fs.exec(helper, [ 'advanced-read', 'outbound' ]),
				L.resolveDefault(fs.exec(systemHelper, [ 'dns-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(systemHelper, [ 'dns-segments-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(qualityHelper, [ 'summary', '1h' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(helper, [ 'tunnels-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(helper, [ 'tunnels-status' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Outbound IKEv2 Tunnel'),
				_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var dnsValue = common.parseKeyValues((data[4] && data[4].stdout) || '');
		var dnsSegments = parseDnsSegments((data[5] && data[5].stdout) || '');
		var customMode = (data[2].stdout || '').trim() === '1';
		var outbound = findOutbound(common.parseSwanmon(data[1]));
		var child = outbound && Object.values(outbound['child-sas'] || {})
			.find(function(item) { return item.name === 'proxy4'; });
		var statusPill = common.pill('', 'neutral');
		var rawModePill = common.pill('', 'neutral');

		function liveCard(label, extraClass) {
			var valueNode = E('div', { 'class': 'ikev2-card-value' });
			var detailNode = E('div', { 'class': 'ikev2-card-detail' });
			return {
				node: E('div', { 'class': 'ikev2-card ' + (extraClass || '') }, [
					E('div', { 'class': 'ikev2-card-label' }, [ label ]),
					valueNode,
					detailNode
				]),
				value: valueNode,
				detail: detailNode
			};
		}

		var gatewayCard = liveCard(_('Remote gateway'));
		var virtualCard = liveCard(_('Virtual IPv4'));
		var trafficCard = liveCard(_('Current SA traffic'));
		var accumulatedTrafficCard = liveCard(_('Accumulated tunnel traffic'));

		function updateConnectionView() {
			common.setPill(statusPill,
				customMode ? _('Custom config') : (child ? _('Connected') : _('Disconnected')),
				customMode ? 'warn' : (child ? 'good' : 'bad'));
			common.setPill(rawModePill,
				customMode ? _('Override active') : _('Generated'),
				customMode ? 'warn' : 'good');
			gatewayCard.value.textContent = outbound ? outbound['remote-host'] :
				(value.remote_address || '-');
			gatewayCard.detail.textContent = outbound ? outbound['remote-id'] : (value.remote_id || '');
			virtualCard.value.textContent = outbound && (outbound['local-vips'] || [])[0] || '-';
			virtualCard.detail.textContent = child ?
				common.formatDuration(child['install-time']) + ' ' + _('online') : '';
			var down = child ? Number(child['bytes-in'] || 0) : 0;
			var up = child ? Number(child['bytes-out'] || 0) : 0;
			trafficCard.value.textContent = common.formatBytes(down + up);
			trafficCard.detail.textContent = child ?
				_('Down %s, up %s').format(common.formatBytes(down), common.formatBytes(up)) +
					' · ' + _('Counter age: %s').format(common.formatDuration(child['install-time'])) :
				_('No active traffic SA');
			var interfacePresent = value.interface_present === '1';
			var totalDown = Number(value.interface_bytes_in || 0);
			var totalUp = Number(value.interface_bytes_out || 0);
			accumulatedTrafficCard.value.textContent = interfacePresent ?
				common.formatBytes(totalDown + totalUp) : '-';
			accumulatedTrafficCard.detail.textContent = interfacePresent ?
				_('Down %s, up %s').format(common.formatBytes(totalDown), common.formatBytes(totalUp)) +
					' · ' + _('Since ipsec-out was created') :
				_('ipsec-out is unavailable');
		}

		function refreshClientState() {
			return Promise.all([
				L.resolveDefault(fs.exec(helper, [ 'client-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' })
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				outbound = findOutbound(common.parseSwanmon(results[1]));
				child = outbound && Object.values(outbound['child-sas'] || {})
					.find(function(item) { return item.name === 'proxy4'; });
				updateConnectionView();
			});
		}
		updateConnectionView();
		poll.add(refreshClientState, 5);
		var quality = qualitySection(common.parseKeyValues((data[6] && data[6].stdout) || ''));
		quality.start();
		var enabled = input('checkbox', value.enabled);
		var address = input('text', value.remote_address, {
			'placeholder': _('IPv4 address or hostname')
		});
		var remoteId = input('text', value.remote_id);
		var username = input('text', value.username, { 'autocomplete': 'off' });
			var password = input('password', '', {
				'placeholder': _('Leave blank to keep the current password'),
				'autocomplete': 'new-password'
		});
		var dpd = common.choiceWithCustom(value.dpd, [
			{ value: '30', label: '30 ' + _('seconds') + ' — ' + _('recommended') },
			{ value: '60', label: '60 ' + _('seconds') },
			{ value: '120', label: '120 ' + _('seconds') }
		], { type: 'number', attrs: { 'min': '10', 'max': '300' } });
		var mtu = common.choiceWithCustom(value.mtu, [
			{ value: '1400', label: '1400 — ' + _('recommended') },
			{ value: '1360', label: '1360 — ' + _('constrained networks') },
			{ value: '1280', label: '1280 — ' + _('minimum') },
			{ value: '1500', label: '1500 — ' + _('no reduction') }
		], { type: 'number', attrs: { 'min': '1280', 'max': '1500' } });
		var reconnectCooldown = common.choiceWithCustom(value.reconnect_cooldown || '15', [
			{ value: '15', label: '15 ' + _('seconds') + ' — ' + _('recommended') },
			{ value: '30', label: '30 ' + _('seconds') },
			{ value: '60', label: '60 ' + _('seconds') }
		], { type: 'number', attrs: { 'min': '15', 'max': '300' } });
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save and connect')
		]);
		var saveOnly = E('button', { 'class': 'cbi-button' }, [
			_('Save')
		]);
		var reconnect = E('button', { 'class': 'cbi-button cbi-button-neutral' }, [
			_('Reconnect')
		]);
		var tunnelDnsUpstream = dnsEndpointEditor(
			value.tunnel_dns_upstream ||
				'https://dns.google/dns-query https://dns.cloudflare.com/dns-query',
			'https://dns.example/dns-query', _('Add DoH server'),
			_('No tunnel DNS servers added'),
			// The tunnel resolver is a sing-box server of type "https" bound to
			// ipsec-out, so DoH is the only scheme it can carry. The router
			// takes at most four servers and four bootstrap addresses.
			{ protocol: 'doh', max: 4 });
		// Plain IPv4 on port 53 only: that is what the tunnel resolver accepts,
		// and offering DoH, DoT or DoQ here led to a refusal on save.
		var tunnelDnsBootstrap = dnsEndpointEditor(
			value.tunnel_dns_bootstrap ||
				'8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53',
			'1.1.1.1:53', _('Add bootstrap server'),
			_('No bootstrap servers added'),
			{ bootstrap: true, protocols: [ 'plain' ], max: 4 });
		var connectResult = common.inlineResult();
		var rawResult = common.inlineResult();
		var rawToggle = E('button', { 'class': 'cbi-button' }, [ _('Edit raw config') ]);
		var rawText = E('textarea', { 'class': 'ikev2-domain-editor' }, [
			data[3].stdout || ''
		]);
		var rawSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save custom config')
		]);
		var rawReset = E('button', { 'class': 'cbi-button cbi-button-reset' }, [
			_('Reset to generated')
		]);
		var rawPanel = E('div', {
			'style': 'display:none;margin-top:1rem'
		}, [
			E('div', { 'class': 'ikev2-note warn' }, [
				_('Custom mode replaces the generated outbound connection. Credentials remain managed separately by the EAP fields above.')
			]),
			rawText,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:.7rem' }, [
				rawResult.node,
				rawReset,
				rawSave
			])
		]);

		rawToggle.addEventListener('click', function() {
			rawPanel.style.display = rawPanel.style.display === 'none' ? '' : 'none';
		});

		rawSave.addEventListener('click', function() {
			return writeProfileInput(rawText.value).then(function(token) {
				return runManagerJob(rawSave, rawResult,
					[ 'advanced-start', 'outbound', token ],
					_('Validating and reconnecting...'), _('Loaded'),
					_('Custom configuration was rejected'), 120000, function(st) {
						if (st && st.state !== 'timeout') {
							customMode = true;
							rawTracker.reset();
							return refreshClientState();
						}
					});
			}).catch(function(error) {
				rawResult.err(error.message || error);
				});
		});

		rawReset.addEventListener('click', function() {
			return runManagerJob(rawReset, rawResult,
				[ 'advanced-reset-start', 'outbound' ],
				_('Restoring and reconnecting...'), _('Restored'), _('Reset failed'), 120000,
				function(st) {
					if (st && st.state !== 'timeout') {
						customMode = false;
						rawTracker.reset();
						return refreshClientState();
					}
				});
		});

			function writeClientInput(mode) {
				var tunnelUpstream = tunnelDnsUpstream.values();
				var tunnelBootstrap = tunnelDnsBootstrap.values();
				if (!tunnelUpstream.length || !tunnelUpstream.every(function(endpoint) {
					return validDnsEndpoint('doh', endpoint);
				}))
					return Promise.reject(new Error(_('Tunnel DNS requires valid HTTPS endpoints.')));
				if (!tunnelBootstrap.length || !tunnelBootstrap.every(function(endpoint) {
					return validBootstrapEndpoint(endpoint) && /:53$/.test(endpoint);
				}))
					return Promise.reject(new Error(_('Tunnel DNS bootstrap requires IPv4 addresses on port 53.')));
				var token = common.inputToken();
				var payload = [
				mode,
				enabled.checked ? '1' : '0',
				address.value.trim(),
				remoteId.value.trim(),
				username.value.trim(),
				dpd.value(),
				mtu.value(),
				password.value,
				reconnectCooldown.value(),
				'custom',
				tunnelUpstream.join(' '),
				tunnelBootstrap.join(' ')
			].join('\n') + '\n';
				return fs.write('/var/run/ikev2-manager-client-' + token + '.in', payload, 384 /* 0600 */)
					.then(function() { return token; });
			}

		function runClientInputJob(button, mode, busy, success, failure, timeout) {
				return writeClientInput(mode).then(function(token) {
					return runManagerJob(button, connectResult, [ 'client-input', token ],
					busy, success, failure, timeout, function(st) {
						// The form, the tunnel DNS lists included, is on the router now.
						if (st && st.state !== 'timeout') {
							clientTracker.reset();
							tunnelTracker.reset();
						}
						return refreshClientState();
					});
			}).catch(function(error) {
				connectResult.err(error.message || error);
			});
		}

		saveOnly.addEventListener('click', function() {
			return runClientInputJob(saveOnly, 'save',
				_('Saving...'), _('Saved'), _('Save failed'), 120000);
		});

		save.addEventListener('click', function() {
			return runClientInputJob(save, 'set',
				enabled.checked ? _('Saving and connecting...') : _('Saving and stopping...'),
				enabled.checked ? _('Saved and connected') : _('Saved and disabled'),
				_('Apply failed'), 150000);
		});

		// Reconnect the existing tunnel without changing saved settings.
		reconnect.addEventListener('click', function() {
			return runManagerJob(reconnect, connectResult, [ 'reconnect-client' ],
				_('Reconnecting...'), _('Reconnected'), _('Reconnect failed'), 90000,
				refreshClientState);
		});

		var dnsManaged = E('select', { 'class': 'cbi-input-select' }, [
			E('option', {
				'value': '0',
				'selected': dnsValue.managed !== '1' ? '' : null
			}, [ _('Keep existing router DNS') ]),
			E('option', {
				'value': '1',
				'selected': dnsValue.managed === '1' ? '' : null
			}, [ _('Manage DNS upstream') ])
		]);
		var initialProtocol = dnsValue.protocol || dnsValue.current_protocol || 'doh';
		if (!dnsProtocols.some(function(item) { return item.id === initialProtocol; }))
			initialProtocol = 'doh';
		var initialMode = dnsValue.upstream_mode || dnsValue.current_upstream_mode ||
			'load_balance';
		var dnsUpstreamMode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', {
				'value': 'load_balance',
				'selected': initialMode === 'load_balance' ? '' : null
			}, [ _('Load balance') ]),
			E('option', {
				'value': 'parallel',
				'selected': initialMode === 'parallel' ? '' : null
			}, [ _('First response') ]),
			E('option', {
				'value': 'fastest_addr',
				'selected': initialMode === 'fastest_addr' ? '' : null
			}, [ _('Fastest address') ])
		]);
		var endpointPlaceholder = 'https://dns.example/dns-query';
		var dnsUpstream = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'upstream', 'current_upstream', ''),
			endpointPlaceholder, _('Add DNS server'), _('No DNS servers added'),
			{ choosable: true });
		var dnsBootstrap = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'bootstrap', 'current_bootstrap',
				'1.1.1.1:53 1.0.0.1:53'),
			'1.1.1.1:53', _('Add bootstrap server'), _('No bootstrap servers added'),
			{ bootstrap: true, choosable: true,
				protocols: [ 'plain', 'doh', 'dot', 'doq' ] });
		var dnsFallback = dnsEndpointEditor(
			configuredDnsValue(dnsValue, 'fallback', 'current_fallback', ''),
			endpointPlaceholder, _('Add fallback server'), _('No fallback servers added'),
			{ choosable: true });
		var dnsWanFallback = input('checkbox', '1');
		dnsWanFallback.checked = dnsValue.wan_fallback === '1';
		// Where names outside the selected domains and the segments go in
		// Reliable mode: straight from dnsmasq, or through sing-box, which alone
		// can give them the compatibility answer. Matching by address has no
		// sing-box to send them to.
		var dnsVia = input('checkbox', '1');
		var dnsCompat = input('checkbox', '1');
		dnsVia.checked = dnsValue.via_singbox === '1';
		dnsCompat.checked = dnsValue.https_compat === '1';
		function reliableMode() { return dnsValue.engine === 'fakeip'; }
		// Resolving every name through the tunnel happens in sing-box, so it
		// takes this path whatever the switch says.
		function syncDnsPath() {
			var tunnel = dnsValue.tunnel_resolve === '1';
			dnsVia.disabled = !reliableMode() || tunnel;
			dnsCompat.disabled = !reliableMode() || !(dnsVia.checked || tunnel);
		}
		dnsVia.addEventListener('change', syncDnsPath);
		// Ordinary names normally resolve over WAN. Sending them through the
		// tunnel-bound resolver removes that exposure but leaves no fallback,
		// because sing-box does not fail over between DNS servers, so it is its
		// own control with its own confirmation rather than part of Apply DNS.
		var tunnelResolve = input('checkbox', '1');
		tunnelResolve.checked = dnsValue.tunnel_resolve === '1';
		var tunnelDnsResult = common.inlineResult();
		var tunnelDnsApply = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Apply tunnel DNS') ]);
		// While the tunnel resolves everything, client queries never reach the
		// router resolver below. Saying so there keeps the next reader from
		// tuning a group that is not in the path.
		var routerDnsBypassNote = E('p', { 'class': 'ikev2-panel-note' }, [
			_('Client queries currently resolve through the tunnel and do not use this resolver. It still resolves names for the router\'s own direct connections, and destination segments keep working independently.')
		]);
		routerDnsBypassNote.style.display = dnsValue.tunnel_resolve === '1' ? '' : 'none';
		var dnsResult = common.inlineResult();
		var dnsStatus = common.pill('', 'neutral');
		var dnsSave = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Apply DNS') ]);
		var dnsRows = E('div', { 'class': 'ikev2-form-grid' }, [
			common.fieldLabel(_('Query strategy')),
			dnsUpstreamMode,
			common.fieldLabel(_('Primary DNS servers')),
			dnsUpstream.node,
			common.fieldLabel(_('Bootstrap DNS')),
			dnsBootstrap.node,
			common.fieldLabel(_('Fallback DNS servers')),
			dnsFallback.node,
			common.fieldLabel(_('WAN provider resolvers'),
				_('Adds the resolvers published by the WAN provider to the fallback group above. They are not a further tier: the group is used as a whole once the primary group fails, and the provider entries are selected on equal terms with the ones you configured.')),
			common.toggleRow(dnsWanFallback, _('Use WAN-provided DNS'),
				_('These queries are unencrypted and visible to the provider. They are never used for tunnel-routed destinations.'))
		]);
		var dnsManagedRows = E('div', { 'class': 'ikev2-dns-managed' }, [ dnsRows ]);
		var segmentStatus = common.pill('', 'neutral');
		// Segments are their own section rather than a disclosure inside the
		// router resolver: they resolve independently of it, and stay in the path
		// even when every other name is sent through the tunnel. Each configured
		// segment is its own block so the page opens on what exists instead of on
		// an empty creation form.
		var segmentList = E('div', { 'class': 'ikev2-segment-list' });
		var segmentAdd = E('button', {
			'class': 'cbi-button cbi-button-add ikev2-wide-button', 'type': 'button'
		}, [ _('Add DNS segment') ]);
		var segmentRows = E('div', {}, [ segmentList, segmentAdd ]);
		var segmentSeq = 0;

		// One block per segment. Everything a block needs - fields,
		// validation, result line, Save and Delete - lives in this closure, so
		// blocks never share state and a draft block is just a block without a
		// stored counterpart.
		function segmentBlock(item) {
			var seq = ++segmentSeq;
			var id = item ? item.id :
				common.inputToken().replace(/-/g, '').slice(0, 16);
			var name = input('text', item ? item.name : '', { 'placeholder': 'national' });
			var enabled = input('checkbox', '1');
			var via = input('checkbox', '1');
			var httpsCompat = input('checkbox', '1');
			var wanFallback = input('checkbox', '1');
			var domains = input('text', item ? item.domains : '',
				{ 'placeholder': 'ru su xn--p1ai' });
			var mode = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'load_balance' }, [ _('Load balance') ]),
				E('option', { 'value': 'parallel' }, [ _('First response') ]),
				E('option', { 'value': 'fastest_addr' }, [ _('Fastest address') ])
			]);
			enabled.checked = !item || item.enabled === '1';
			via.checked = !!item && item.via_singbox === '1';
			httpsCompat.checked = !item || item.https_compat !== '0';
			function syncPath() {
				via.disabled = !reliableMode();
				httpsCompat.disabled = !reliableMode() || !via.checked;
			}
			via.addEventListener('change', syncPath);
			syncPath();
			wanFallback.checked = !!item && item.wan_fallback === '1';
			mode.value = item ? item.mode : 'load_balance';
			var upstream = dnsEndpointEditor(item ? item.upstream : '',
				'udp://77.88.8.8:53', _('Add DNS server'), _('No DNS servers added'),
				{ choosable: true });
			var bootstrap = dnsEndpointEditor(item ? item.bootstrap : '',
				'77.88.8.8:53', _('Add bootstrap server'), _('No bootstrap servers added'),
				{ bootstrap: true, choosable: true,
					protocols: [ 'plain', 'doh', 'dot', 'doq' ] });
			var fallback = dnsEndpointEditor(item ? item.fallback : '',
				'https://dns.cloudflare.com/dns-query', _('Add fallback server'),
				_('Inherit global DNS servers'), { choosable: true });
			// An empty fallback field is not "no fallback": it inherits the global
			// fallback group and then the global primary group. When the WAN fallback
			// is enabled that inheritance includes the provider's plaintext resolver,
			// so the inherited list is spelled out. A configured list needs no such
			// line - it would only repeat the fields directly above it, which read
			// as the global group leaking in whenever the two happen to coincide.
			var inherits = !item || item.inherits_fallback === '1';
			var effective = item ? (item.fallback_effective || '') : '';
			// With its own list, the provider's servers are what the router adds
			// after it; the line names them, as the lease has them now.
			var configured = item ? (item.fallback || '').split(' ').filter(Boolean) : [];
			var provided = effective.split(' ').filter(function(endpoint) {
				return endpoint && configured.indexOf(endpoint) < 0;
			});
			var fallbackEffective = inherits ?
				E('div', { 'class': 'cbi-value-description' }, [
					effective ?
						_('Inherited from the global groups: %s')
							.format(effective.split(' ').join(', ')) :
						_('No fallback is available for this segment.')
				]) :
				(item && item.wan_fallback === '1' ?
					E('div', { 'class': 'cbi-value-description' }, [
						provided.length ?
							_('Then the provider DNS servers: %s').format(provided.join(', ')) :
							_('The provider has handed out no DNS servers yet.')
					]) : '');
			// The stored protocol summarises the group rather than constraining
			// it, exactly as it already does for the router resolver: dnsproxy
			// parses each upstream by its own scheme.
			function segmentProtocol() {
				var first = upstream.values()[0] || '';
				var detected = dnsEndpointProtocol(first);
				return detected === 'unknown' ?
					(item ? item.protocol : 'udp') : detected;
			}
			var result = common.inlineResult();
			var save = E('button', {
				'class': 'cbi-button cbi-button-apply', 'type': 'button'
			}, [ _('Save segment') ]);
			var remove = E('button', {
				'class': 'cbi-button cbi-button-remove', 'type': 'button'
			}, [ item ? _('Delete segment') : _('Discard segment') ]);


			function runSegment(action, button) {
				var payload = [ action, id, name.value.trim(),
					enabled.checked ? '1' : '0', domains.value.trim(),
					segmentProtocol(), mode.value, upstream.values().join(' '),
					bootstrap.values().join(' '), fallback.values().join(' '),
					httpsCompat.checked ? '1' : '0',
					wanFallback.checked ? '1' : '0',
					via.checked ? '1' : '0' ].join('\n') + '\n';
				var token = common.inputToken();
				// The input file is written before the job starts; a failed write
				// must still end in a visible result rather than a silent click.
				return fs.write('/tmp/ikev2-manager-dns-segment-' + token + '.in', payload, 384)
					.then(function() {
						return common.runJob({
							button: button, result: result,
							busy: _('Applying DNS segment...'), success: _('DNS segment applied.'),
							failure: _('DNS segment failed.'),
							startPath: systemHelper,
							startArgs: [ 'dns-segment-input', token ],
							statusPath: systemHelper, statusArgs: [ 'action-status' ],
							timeout: 120000,
							// The list is drawn again from the router, so the
							// outcome goes on the new block's button.
							onSuccess: function() {
								flashSegment = action === 'set' ? id : null;
								return refreshSegments();
							}
						});
					}, function(error) {
						result.err(_('Could not save the DNS segment: %s').format(error.message || error));
					});
			}

			save.addEventListener('click', function() {
				var upstreams = upstream.values();
				var bootstraps = bootstrap.values();
				var fallbacks = fallback.values();
				if (!/^[A-Za-z0-9_]+$/.test(name.value.trim())) {
					return common.refuse(save, result, _('Segment name may contain only letters, digits and underscores.'));
				}
				if (!domains.value.trim() || !upstreams.length || !bootstraps.length) {
					return common.refuse(save, result, _('Domains, upstreams and bootstrap servers are required.'));
				}
				if (!upstreams.every(validDnsEndpointAny)) {
					return common.refuse(save, result, _('Invalid DNS upstream'));
				}
				if (!bootstraps.every(validBootstrapEndpoint)) {
					return common.refuse(save, result, _('Bootstrap DNS must contain IPv4:port entries'));
				}
				if (!fallbacks.every(function(value) {
					return validDnsEndpoint(dnsEndpointProtocol(value), value);
				})) {
					return common.refuse(save, result, _('Invalid fallback DNS endpoint'));
				}
				return runSegment('set', save);
			});
			// A draft has nothing stored yet, so removing it is a local discard
			// rather than a transaction against the router.
			remove.addEventListener('click', function() {
				if (!item) {
					node.remove();
					renderSegments();
					return;
				}
				if (!window.confirm(_('Delete this DNS segment?'))) return;
				return runSegment('delete', remove);
			});

			var title = item ? (item.name || item.id) : _('New segment');
			var node = E('div', { 'class': 'ikev2-segment-block' }, [
				E('div', { 'class': 'ikev2-segment-title' }, [
					E('strong', {}, [ title ]),
					common.pill(item && item.enabled !== '1' ? _('Disabled') : _('Enabled'),
						item && item.enabled !== '1' ? 'neutral' : 'good')
				]),
				E('div', { 'class': 'ikev2-form-grid' }, [
					common.fieldLabel(_('Name')), name,
					common.toggleRow(enabled, _('Enabled')),
					common.toggleRow(via, _('Resolve through sing-box'),
						_('Off: dnsmasq sends this segment straight to its resolver group. On: its queries pass through sing-box, which can answer them for browser compatibility. Applies in Reliable mode.')),
					common.toggleRow(httpsCompat, _('Browser compatibility'),
						_('Return an empty successful HTTPS DNS response for this segment so browsers safely fall back to A and AAAA. Needs the sing-box path.')),
					common.fieldLabel(_('Domain suffixes'), _('Space-separated, for example: ru su')), domains,
					common.fieldLabel(_('Query strategy')), mode,
					common.fieldLabel(_('Primary DNS servers')), upstream.node,
					common.fieldLabel(_('Bootstrap DNS')), bootstrap.node,
					common.fieldLabel(_('Fallback DNS servers'),
						_('Empty inherits the global resolver group, providing an independent recovery path.')),
					// One cell: the note belongs under the list, not in the
					// next row of the label column.
					E('div', {}, [ fallback.node, fallbackEffective ]),
					common.toggleRow(wanFallback, _('Provider DNS as a last resort'),
						_('Adds the DNS servers your internet provider hands out after the fallback servers. They answer in plain text and are asked only when every other server of this segment has failed.'))
				]),
				E('div', { 'class': 'ikev2-actions bar' }, [ result.node, remove, save ])
			]);
			// Grey until the segment differs from what was loaded; a new one
			// until something is entered.
			common.trackChanges(save, [ name, enabled, via, httpsCompat, wanFallback, domains, mode,
				upstream.node, bootstrap.node, fallback.node ]);
			node.saveButton = save;
			return node;
		}

		var flashSegment = null;
		function renderSegments() {
			segmentList.replaceChildren();
			if (!dnsSegments.length)
				segmentList.appendChild(E('div', { 'class': 'ikev2-dns-empty' }, [
					_('No DNS segments configured.')
				]));
			dnsSegments.forEach(function(item) {
				var block = segmentBlock(item);
				segmentList.appendChild(block);
				if (item.id === flashSegment)
					common.flashButton(block.saveButton, 'ok', _('Saved'), _('DNS segment applied.'));
			});
			flashSegment = null;
		}
		segmentAdd.addEventListener('click', function() {
			var empty = segmentList.querySelector('.ikev2-dns-empty');
			if (empty) empty.remove();
			segmentList.appendChild(segmentBlock(null));
		});

		function refreshSegments() {
			return common.execChecked(systemHelper, [ 'dns-segments-get' ],
				_('Could not refresh DNS segments')).then(function(response) {
				dnsSegments = parseDnsSegments(response.stdout || '');
				renderSegments();
			});
		}




		function syncDnsVisibility() {
			var managed = dnsManaged.value === '1';
			dnsManagedRows.style.display = managed ? '' : 'none';
			// Segment workers only run under managed DNS, so the editor follows it.
			segmentRows.style.display = managed ? '' : 'none';
			common.setPill(segmentStatus, managed ? _('Independent') : _('Requires managed DNS'),
				managed ? 'good' : 'neutral');
		}

		function updateDnsState(next) {
			dnsValue = common.parseKeyValues((next && next.stdout) || '');
			if (dnsValue.managed === '1' && dnsValue.segment_health === 'degraded') {
				common.setPill(dnsStatus, _('Segment degraded'), 'bad');
			}
			else if (dnsValue.managed === '1') {
				common.setPill(dnsStatus,
					dnsValue.running === '1' ? _('Managed') : _('Stopped'),
					dnsValue.running === '1' ? 'good' : 'bad');
			}
			else {
				common.setPill(dnsStatus, _('Existing settings'), 'neutral');
			}
			syncDnsPath();
		}

		renderSegments();
		syncDnsVisibility();
		dnsManaged.addEventListener('change', syncDnsVisibility);

		// One Apply for the whole block. The servers are stored with the client
		// profile in save mode, which does not reconnect, and the resolution path
		// goes through its own validated helper. An unchanged path is not
		// re-applied, so editing a server list never restarts the resolver.
		tunnelDnsApply.addEventListener('click', function() {
			var wanted = tunnelResolve.checked ? '1' : '0';
			var applied = dnsValue.tunnel_resolve === '1' ? '1' : '0';
			return common.runAction({
				button: tunnelDnsApply,
				result: tunnelDnsResult,
				busy: _('Applying tunnel DNS...'),
				failure: _('Could not apply tunnel DNS'),
				run: function() {
					return writeClientInput('save').then(function(token) {
						return common.execChecked(helper, [ 'client-input', token ],
							_('Could not save the tunnel DNS servers'));
					}).then(function() {
						if (wanted === applied)
							return null;
						return common.execChecked('/usr/libexec/ikev2-domain-router',
							[ 'tunnel-resolve', wanted ],
							_('Could not change the resolution path'));
					});
				},
				onSuccess: function() {
					dnsValue.tunnel_resolve = wanted;
					syncDnsPath();
					// This saves the whole tunnel form in save mode, not only the lists.
					clientTracker.reset();
					tunnelTracker.reset();
					routerDnsBypassNote.style.display = wanted === '1' ? '' : 'none';
					tunnelDnsResult.ok(wanted === applied ? _('Tunnel DNS saved.') :
						(wanted === '1' ? _('Saved. All names now resolve through the tunnel.') :
							_('Saved. Ordinary names resolve over WAN again.')));
					return refreshClientState();
				},
				onError: function() {
					// The helper restores the previous setting on failure, so the
					// control must go back to what the router actually has.
					tunnelResolve.checked = applied === '1';
					tunnelTracker.update();
				}
			});
		});

		dnsSave.addEventListener('click', function() {
			return common.runAction({
				button: dnsSave,
				result: dnsResult,
				busy: _('Applying and testing DNS...'),
				failure: _('DNS apply failed'),
				run: function() {
					var upstream = dnsUpstream.values();
					var bootstrap = dnsBootstrap.values();
					var fallback = dnsFallback.values();
					if (dnsManaged.value === '1') {
						if (!upstream.length || !upstream.every(validDnsEndpointAny))
							throw new Error(_('Invalid DNS upstream'));
						if (!bootstrap.length || !bootstrap.every(validBootstrapEndpoint))
							throw new Error(_('Bootstrap DNS must contain IPv4:port entries or DoH/DoT/DoQ endpoints with a literal IPv4 address'));
						if (!fallback.every(function(value) {
							return validDnsEndpoint(dnsEndpointProtocol(value), value);
						}))
							throw new Error(_('Invalid fallback DNS endpoint'));
					}
						var token = common.inputToken();
						var payload = [
						dnsManaged.value,
						dnsEndpointProtocol(upstream[0] || '') === 'unknown' ?
							initialProtocol : dnsEndpointProtocol(upstream[0]),
						'custom',
						dnsUpstreamMode.value,
						upstream.join(' '),
						bootstrap.join(' '),
						fallback.join(' '),
						dnsWanFallback.checked ? '1' : '0',
						dnsVia.checked ? '1' : '0',
						dnsCompat.checked ? '1' : '0'
					].join('\n') + '\n';
						return fs.write('/tmp/ikev2-manager-dns-' + token + '.in', payload, 384)
							.then(function() {
								return common.execChecked(systemHelper, [ 'dns-set-async', token ],
								_('DNS settings rejected'));
						})
						.then(function(response) {
							var started = common.parseKeyValues(response.stdout || '');
							if (!started.action_id)
								throw new Error(_('DNS apply did not start'));
							return common.pollAction(systemHelper,
								[ 'action-status', started.action_id ], started.action_id, {
									timeout: 90000,
									interval: 1000,
									onProgress: function(st) {
										common.showProgress(dnsResult, st.message,
											_('Applying and testing DNS...'));
									}
								});
						})
						.then(function(st) {
							if (!st) {
								dnsResult.warn(_('The operation continues in the background. You can use the button again.'));
								return;
							}
							if (st.state === 'error')
								throw new Error(st.message ? _(st.message) : _('DNS apply failed'));
							dnsResult.ok(_('DNS is working'));
							return L.resolveDefault(fs.exec(systemHelper, [ 'dns-get' ]), { stdout: '' })
								.then(function(next) { updateDnsState(next); dnsTracker.reset(); });
						});
				}
			});
		});

		updateDnsState({ stdout: (data[4] && data[4].stdout) || '' });

		// Everything that qualifies the connection profile without being part of
		// setting it up: timers, MTU, and the generated swanctl config itself.
		var connectionAdvanced = common.advancedPanel(E('div', {}, [
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Advanced connectivity') ]),
				E('div', { 'class': 'ikev2-form-grid' }, [
					common.fieldLabel(_('DPD interval'),
						_('Dead peer detection in seconds.')),
					dpd.node,
					common.fieldLabel(_('XFRM MTU'),
						_('Keep 1400 unless PMTU diagnostics show a problem.')),
					mtu.node,
					common.fieldLabel(_('Reconnect cooldown'),
						_('Minimum delay between automatic connection attempts, in seconds.')),
					reconnectCooldown.node
				])
			]),
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Advanced strongSwan configuration') ]),
				E('p', { 'class': 'ikev2-panel-note' }, [
					_('Inspect the generated swanctl connection or replace it with a manually maintained profile.')
				]),
				rawPanel,
				E('div', { 'class': 'ikev2-actions spread', 'style': 'margin-top:1rem' }, [
					rawModePill, rawToggle
				])
			])
		]), _('Advanced connection settings'));

		// Save buttons are grey until what they send has changed. "Save",
		// "Save and connect" and "Apply tunnel DNS" all store the tunnel form with
		// its DNS lists; only the last also applies the resolution path, which is
		// compared with what the router has applied rather than with the page.
		// The tunnels after the first. Each is a block of its own, as a DNS
		// segment is: fields, Save, Delete and its own result, and a draft is a
		// block without a stored counterpart.
		var tunnels = parseTunnels((data[7] && data[7].stdout) || '');
		var tunnelStatus = parseTunnelStatus((data[8] && data[8].stdout) || '');
		var tunnelList = E('div', { 'class': 'ikev2-segment-list' });
		var tunnelAdd = E('button', {
			'class': 'cbi-button cbi-button-add ikev2-wide-button', 'type': 'button'
		}, [ _('Add tunnel') ]);
		var tunnelRows = E('div', {}, [ tunnelList, tunnelAdd ]);
		var tunnelStates = {};
		var flashTunnel = null;

		function tunnelName(index) {
			if (String(index) === '1')
				return _('Main tunnel');
			var found = tunnels.find(function(item) { return item.index === String(index); });
			return found && found.name ? found.name : _('Tunnel %s').format(index);
		}

		function showTunnelState(index) {
			var view = tunnelStates[index];
			if (!view)
				return;
			var state = tunnelStatus[index] || {};
			if (view.disabled)
				common.setPill(view.pill, _('Disabled'), 'neutral');
			else
				common.setPill(view.pill, state.up === '1' ? _('Connected') : _('Disconnected'),
					state.up === '1' ? 'good' : 'bad');
			var carries = (state.carries || '').split(',').filter(Boolean).map(tunnelName);
			view.detail.textContent = [
				state.address ? _('Address %s').format(state.address) : '',
				carries.length ? _('Carries: %s').format(carries.join(', ')) : ''
			].filter(Boolean).join(' · ');
		}

		// The main tunnel's own switch for what every other tunnel has in its
		// block: applied at once, like the tunnels themselves.
		var mainBackup = input('checkbox', value.backup === '0' ? '0' : '1');
		var mainBackupResult = common.inlineResult();
		mainBackup.addEventListener('change', function() {
			var wanted = mainBackup.checked;
			return runManagerJob(mainBackup, mainBackupResult,
				[ 'client-backup', wanted ? '1' : '0' ],
				_('Applying...'), _('Saved.'), _('Tunnel settings failed.'), 180000).then(function(st) {
				if (!st || st.state === 'error')
					mainBackup.checked = !wanted;
			});
		});

		function tunnelBlock(item) {
			var name = input('text', item ? item.name : '', { 'placeholder': _('Netherlands') });
			var enabledTunnel = input('checkbox', '1');
			enabledTunnel.checked = !item || item.enabled === '1';
			var remote = input('text', item ? item.remote_address : '', {
				'placeholder': _('IPv4 address or hostname')
			});
			var identity = input('text', item ? item.remote_id : '');
			var user = input('text', item ? item.username : '', { 'autocomplete': 'off' });
			var secret = input('password', '', {
				'placeholder': item ? _('Leave blank to keep the current password') : '',
				'autocomplete': 'new-password'
			});
			var backup = input('checkbox', '1');
			backup.checked = !item || item.backup !== '0';
			var tunnelDpd = common.choiceWithCustom(item ? item.dpd : '30', [
				{ value: '30', label: '30 ' + _('seconds') + ' — ' + _('recommended') },
				{ value: '60', label: '60 ' + _('seconds') },
				{ value: '120', label: '120 ' + _('seconds') }
			], { type: 'number', attrs: { 'min': '10', 'max': '300' } });
			var tunnelMtu = common.choiceWithCustom(item ? item.mtu : '1400', [
				{ value: '1400', label: '1400 — ' + _('recommended') },
				{ value: '1360', label: '1360 — ' + _('constrained networks') },
				{ value: '1280', label: '1280 — ' + _('minimum') },
				{ value: '1500', label: '1500 — ' + _('no reduction') }
			], { type: 'number', attrs: { 'min': '1280', 'max': '1500' } });
			var result = common.inlineResult();
			var saveTunnel = E('button', {
				'class': 'cbi-button cbi-button-apply', 'type': 'button'
			}, [ _('Save tunnel') ]);
			var removeTunnel = E('button', {
				'class': 'cbi-button cbi-button-remove', 'type': 'button'
			}, [ item ? _('Delete tunnel') : _('Discard tunnel') ]);

			function runTunnel(action, button) {
				var payload = (action === 'delete' ?
					[ 'delete', item.index, '', '', '', '', '', '', '', '', '' ] :
					[ 'save', item ? item.index : 'new', name.value.trim(),
						enabledTunnel.checked ? '1' : '0', remote.value.trim(),
						identity.value.trim(), user.value.trim(), tunnelDpd.value(),
						tunnelMtu.value(), backup.checked ? '1' : '0', secret.value ])
					.join('\n') + '\n';
				var token = common.inputToken();
				// Written before the job starts; a failed write still ends in a
				// visible result rather than a silent click.
				return fs.write('/var/run/ikev2-manager-tunnel-' + token + '.in', payload, 384)
					.then(function() {
						return runManagerJob(button, result, [ 'tunnel-input', token ],
							action === 'delete' ? _('Removing the tunnel...') : _('Saving and connecting...'),
							action === 'delete' ? _('Tunnel removed.') : _('Tunnel saved.'),
							_('Tunnel settings failed.'), 180000, function(st) {
								if (st && st.state === 'timeout')
									return;
								flashTunnel = action === 'delete' ? null : 'saved';
								return refreshTunnels();
							});
					}, function(error) {
						result.err(_('Could not save the tunnel: %s').format(error.message || error));
					});
			}

			saveTunnel.addEventListener('click', function() {
				if (!/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,31}$/.test(name.value.trim()))
					return common.refuse(saveTunnel, result,
						_('Tunnel name: letters, digits, spaces, dots and dashes, up to 32 characters.'));
				if (!remote.value.trim() || !identity.value.trim() || !user.value.trim())
					return common.refuse(saveTunnel, result,
						_('Remote address, remote identity and EAP username are required.'));
				if (!item && !secret.value)
					return common.refuse(saveTunnel, result, _('EAP password is required for a new tunnel.'));
				return runTunnel('save', saveTunnel);
			});
			removeTunnel.addEventListener('click', function() {
				if (!item) {
					node.remove();
					renderTunnels();
					return;
				}
				if (!window.confirm(_('Delete this tunnel? Services, lists and devices sent through it go back to the main tunnel.')))
					return;
				return runTunnel('delete', removeTunnel);
			});

			var pill = common.pill('', 'neutral');
			var detail = E('div', { 'class': 'cbi-value-description' });
			var node = E('div', { 'class': 'ikev2-segment-block ikev2-tunnel-block' }, [
				E('div', { 'class': 'ikev2-segment-title' }, [
					E('strong', {}, [ item ? (item.name || _('Tunnel %s').format(item.index)) : _('New tunnel') ]),
					pill
				]),
				detail,
				E('div', { 'class': 'ikev2-form-grid' }, [
					common.fieldLabel(_('Name')), name,
					common.toggleRow(enabledTunnel, _('Enabled')),
					common.fieldLabel(_('Remote address'),
						_('IPv4 address or hostname of the IKEv2 gateway.')),
					remote,
					common.fieldLabel(_('Remote identity'),
						_('Certificate identity expected from the VPS.')),
					identity,
					common.fieldLabel(_('EAP username')), user,
					common.fieldLabel(_('New EAP password'),
						_('Visible while editing; leave blank to preserve the saved secret.')),
					secret,
					common.toggleRow(backup, _('Stand in for other tunnels'),
						_('When another tunnel drops, its traffic moves here until it is back. Off: only what is sent to this tunnel uses it.')),
					common.fieldLabel(_('DPD interval'),
						_('Dead peer detection in seconds.')),
					tunnelDpd.node,
					common.fieldLabel(_('XFRM MTU'),
						_('Keep 1400 unless PMTU diagnostics show a problem.')),
					tunnelMtu.node
				]),
				E('div', { 'class': 'ikev2-actions bar' }, [ result.node, removeTunnel, saveTunnel ])
			]);
			if (item) {
				tunnelStates[item.index] = { pill: pill, detail: detail, disabled: item.enabled !== '1' };
				showTunnelState(item.index);
			}
			else
				common.setPill(pill, _('Not saved'), 'neutral');
			common.trackChanges(saveTunnel, [ name, enabledTunnel, remote, identity, user, secret,
				backup, tunnelDpd.node, tunnelMtu.node ]);
			node.saveButton = saveTunnel;
			return node;
		}

		function renderTunnels() {
			tunnelList.replaceChildren();
			tunnelStates = {};
			if (!tunnels.length)
				tunnelList.appendChild(E('div', { 'class': 'ikev2-dns-empty' }, [
					_('Only the main tunnel is configured.')
				]));
			tunnels.forEach(function(item) {
				tunnelList.appendChild(tunnelBlock(item));
			});
			if (flashTunnel && tunnelList.lastChild && tunnelList.lastChild.saveButton)
				common.flashButton(tunnelList.lastChild.saveButton, 'ok', _('Saved'), _('Tunnel saved.'));
			flashTunnel = null;
			tunnelAdd.disabled = tunnels.length >= 7;
		}
		tunnelAdd.addEventListener('click', function() {
			var empty = tunnelList.querySelector('.ikev2-dns-empty');
			if (empty)
				empty.remove();
			tunnelList.appendChild(tunnelBlock(null));
		});

		function refreshTunnels() {
			return Promise.all([
				common.execChecked(helper, [ 'tunnels-get' ], _('Could not refresh the tunnels')),
				L.resolveDefault(fs.exec(helper, [ 'tunnels-status' ]), { stdout: '' })
			]).then(function(results) {
				tunnels = parseTunnels(results[0].stdout || '');
				tunnelStatus = parseTunnelStatus(results[1].stdout || '');
				renderTunnels();
			});
		}

		// The state only: a block being edited is not drawn again.
		poll.add(function() {
			return L.resolveDefault(fs.exec(helper, [ 'tunnels-status' ]), { stdout: '' })
				.then(function(response) {
					tunnelStatus = parseTunnelStatus(response.stdout || '');
					Object.keys(tunnelStates).forEach(showTunnelState);
				});
		}, 5);
		renderTunnels();

		var clientTracker = common.trackChanges([ save, saveOnly ], [
			enabled, address, remoteId, username, password, dpd.node, mtu.node,
			reconnectCooldown.node, tunnelDnsUpstream.node, tunnelDnsBootstrap.node
		]);
		var tunnelTracker = common.trackChanges(tunnelDnsApply,
			[ tunnelDnsUpstream.node, tunnelDnsBootstrap.node, tunnelResolve ], {
				read: function() {
					return common.formState([ tunnelDnsUpstream.node, tunnelDnsBootstrap.node ]) +
						(tunnelResolve.checked === (dnsValue.tunnel_resolve === '1') ? '' : '|path');
				}
			});
		var dnsTracker = common.trackChanges(dnsSave, [ dnsManaged, dnsVia, dnsCompat,
			dnsUpstreamMode, dnsUpstream.node, dnsBootstrap.node, dnsFallback.node,
			dnsWanFallback ]);
		var rawTracker = common.trackChanges(rawSave, [ rawText ]);

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Outbound IKEv2 Tunnel'),
					_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.'),
					statusPill),
				E('div', { 'class': 'ikev2-grid' }, [
					gatewayCard.node,
					virtualCard.node,
					trafficCard.node,
					accumulatedTrafficCard.node
				]),
				quality.node,
				common.section(_('Connection'),
					_('Changing these values reloads the tunnel profile and reconnects it. Policy routing stays in place.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.toggleRow(enabled, _('Enable client')),
							common.fieldLabel(_('Remote address'),
								_('IPv4 address or hostname of the IKEv2 gateway.')),
							address,
							common.fieldLabel(_('Remote identity'),
								_('Certificate identity expected from the VPS.')),
							remoteId,
							common.fieldLabel(_('EAP username')),
							username,
							common.fieldLabel(_('New EAP password'),
								_('Visible while editing; leave blank to preserve the saved secret.')),
							password
						]),
						connectionAdvanced.panel,
						E('div', { 'class': 'ikev2-actions bar' }, [ connectResult.node, reconnect, saveOnly, save ])
					]),
					connectionAdvanced.toggle),
				common.section(_('More tunnels'),
					_('Every enabled tunnel stays connected. When one drops, its traffic moves at once to the next one up and comes back after the tunnel has stayed up for two minutes; nothing falls back to the WAN. Which tunnel a service, a list or a device uses, and whether it may move, is chosen on the Policy Routing and Overview pages.'),
					E('div', {}, [
						common.toggleRow(mainBackup, _('The main tunnel stands in for the others'),
							_('When another tunnel drops, its traffic moves to the main one until it is back. Off: only what is sent to the main tunnel uses it.'),
							mainBackupResult.node),
						tunnelRows
					])),
				common.section(_('Tunnel DNS'),
					_('Resolves VPN-routed destinations through the outbound tunnel. Servers are tried in order; failover occurs only after two failed checks and a successful probe of the next server.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('DoH servers'),
								_('The first server is primary. Additional servers are ordered fallbacks.')),
							tunnelDnsUpstream.node,
							common.fieldLabel(_('Bootstrap DNS')),
							tunnelDnsBootstrap.node
						]),
						common.toggleRow(tunnelResolve,
							_('Resolve all names through the tunnel'),
							_('Off by default. Ordinary names are normally resolved over WAN, which is where per-protocol DNS filtering is applied. Turning this on removes that exposure, but it also removes the fallback group: while the tunnel is down, no name resolves for any client. Selected domains and destination segments are unaffected.')),
						E('div', { 'class': 'ikev2-actions bar' }, [
							tunnelDnsResult.node, tunnelDnsApply
						])
					]),
					common.pill(_('Fail-closed'), 'good')),
				common.section(_('Router DNS upstream'),
					_('Choose the public DNS upstream. dnsmasq asks it directly; in reliable mode only the selected domains go through sing-box, unless the switch below sends every other name there too.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('DNS management'),
								_('Existing settings are preserved until managed DNS is enabled.')),
							dnsManaged,
							common.toggleRow(dnsVia, _('Resolve through sing-box'),
								_('Off: dnsmasq sends names outside the selected domains and segments straight to the upstream and caches them, so they keep resolving when sing-box fails. On: they pass through sing-box like the selected domains. Applies in Reliable mode.')),
							common.toggleRow(dnsCompat, _('Browser compatibility'),
								_('Return an empty successful HTTPS DNS response for these names so browsers safely fall back to A and AAAA. Needs the sing-box path.'))
						]),
						routerDnsBypassNote,
						dnsManagedRows,
						E('div', { 'class': 'ikev2-actions bar' }, [ dnsResult.node, dnsSave ])
					]),
					dnsStatus),
				common.section(_('Destination DNS segments'),
					_('Send explicit domain suffixes to an independent resolver group. A segment resolves on its own terms whatever the rest of the policy does — including while every other name goes through the tunnel. Each has its own protocol and query strategy; unlisted names keep the global policy. Suffixes cannot overlap between enabled segments, at most eight run at once, and lists are stored locally rather than rebuilt with domain policy.'),
					segmentRows,
					segmentStatus)
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
