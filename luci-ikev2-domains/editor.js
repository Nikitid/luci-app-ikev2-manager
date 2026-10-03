'use strict';
'require view';
'require fs';
'require ikev2-manager.shared-v14 as common';

var domainFile    = '/etc/pbr-ikev2-domains.txt';
var manualFile    = '/etc/pbr-ikev2-domains.manual.txt';
var manualAddressFile = '/etc/pbr-ikev2-addresses.manual.txt';
var excludeFile = '/etc/pbr-ikev2-domains.exclude.txt';
var excludeAddressFile = '/etc/pbr-ikev2-addresses.exclude.txt';
var selectedFile  = '/etc/pbr-ikev2-community-selected.txt';
var statusFile    = '/tmp/ikev2-domains-community.status';
var communityHelper = '/usr/libexec/ikev2-domains-community';
var domainRouterHelper = '/usr/libexec/ikev2-domain-router';
var exitsFile = '/etc/pbr-ikev2-exits.txt';
var managerHelper = '/usr/libexec/ikev2-manager';
var serviceSelection = {};
var serviceRecords = [];
// Where each selected service and the two custom lists go, as the page holds
// it: target ("@domains", "@cidrs" or a service id) to a tunnel index (it may
// move to another tunnel while its own is down), an index followed by "s"
// (that tunnel or nothing), or "wan" (never through the tunnel). The first
// tunnel is the default.
var serviceExits = {};
// The tunnels the router has, by index.
var tunnelIndexes = { '1': true };

// The tunnels the router has, the main one first, from tunnels-get.
function parseTunnelChoices(stdout) {
	var choices = [ { index: '1', name: _('Main tunnel'), enabled: '1' } ], current = null;
	String(stdout || '').split('\n').forEach(function(line) {
		var at = line.indexOf('=');
		if (at < 1)
			return;
		var key = line.slice(0, at), value = line.slice(at + 1);
		if (key === 'tunnel') {
			current = { index: value, name: _('Tunnel %s').format(value), enabled: '1' };
			choices.push(current);
		}
		else if (current && key === 'name' && value)
			current.name = value;
		else if (current && key === 'enabled')
			current.enabled = value;
	});
	return choices;
}

// Which tunnels are connected, from tunnels-status: index to "1" or "0".
function parseTunnelStatus(stdout) {
	var up = {};
	String(stdout || '').split('\n').forEach(function(line) {
		var index = /(?:^| )tunnel=([1-7])(?: |$)/.exec(line), state = /(?:^| )up=([01])(?: |$)/.exec(line);
		if (index && state)
			up[index[1]] = state[1];
	});
	return up;
}

function parseExits(text) {
	var exits = {};
	String(text || '').split('\n').forEach(function(line) {
		var fields = line.trim().split(/\s+/);
		if (fields.length === 2 && /^([1-7]s?|wan)$/.test(fields[1]))
			exits[fields[0]] = fields[1];
	});
	return exits;
}

function recordOf(id) {
	for (var i = 0; i < serviceRecords.length; i++)
		if (serviceRecords[i].id === id)
			return serviceRecords[i];
	return null;
}

function severalTunnels() {
	return Object.keys(tunnelIndexes).length > 1;
}

// Where a target goes now. A choice made on the page wins; a service an
// earlier release marked as never through the tunnel stays there until it is
// moved. A tunnel the router no longer has sends its targets to the first,
// and with one tunnel there is nothing to be bound against.
function placeOf(target) {
	var own = target.charAt(0) === '@';
	var record = own ? null : recordOf(target);
	var token = serviceExits[target] || (record && record.mode === 'exclude' ? 'wan' : '1');
	if (token === 'wan')
		return own ? '1' : 'wan';
	var index = token.charAt(0);
	if (!tunnelIndexes[index])
		return '1';
	return token.length > 1 && !severalTunnels() ? index : token;
}

// The assignments as the helper stores them: only what differs from the
// first tunnel, and that one too for a service whose old mark it overrides.
function exitsText() {
	return [ '@domains', '@cidrs' ].concat(Object.keys(serviceSelection)).sort().map(function(target) {
		var token = placeOf(target), record = recordOf(target);
		if (token === '1' && !(record && record.mode === 'exclude'))
			return '';
		return target + ' ' + token + '\n';
	}).join('');
}

// An identifier for a new service from its name: the helper wants lowercase
// letters, digits and underscores, and a name in another script has none.
function serviceIdFrom(name) {
	var base = String(name || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
	if (base.length < 2)
		base = 'service';
	var id = base, n = 2;
	while (recordOf(id))
		id = base + '_' + (n++);
	return id;
}

function normalizeDomains(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var domains = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var domain = lines[i].trim().toLowerCase();

		if (!domain || domain.charAt(0) === '#')
			continue;

		var labels = domain.split('.');
		if (domain.length > 253 || domain.charAt(0) === '.' ||
		    domain.charAt(domain.length - 1) === '.' || domain.indexOf('..') !== -1 ||
		    labels.some(function(label) {
			    return !label || label.length > 63 || label.charAt(0) === '-' ||
				    label.charAt(label.length - 1) === '-';
		    }) || /\s/.test(domain) || domain.indexOf('@') !== -1 ||
		    domain.indexOf('/') !== -1 ||
		    domain.indexOf('full:') === 0 ||
		    domain.indexOf('regexp:') === 0 ||
		    !/^[a-z0-9._-]+$/.test(domain)) {
			throw new Error(
				_('Invalid entry on line %d: %s').format(i + 1, domain));
		}

		if (!seen[domain]) {
			seen[domain] = true;
			domains.push(domain);
		}
	}

	return domains;
}

function normalizeAddresses(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var addresses = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var entry = lines[i].trim();
		if (!entry || entry.charAt(0) === '#')
			continue;

		var parts = entry.split('/');
		if (parts.length > 2 || (parts.length === 2 &&
		    (!/^\d+$/.test(parts[1]) || +parts[1] > 32)))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var octets = parts[0].split('.');
		if (octets.length !== 4 || octets.some(function(octet) {
			return !/^\d+$/.test(octet) || +octet > 255;
		}))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var normalized = parts[0] + '/' + (parts.length === 2 ? +parts[1] : 32);
		if (!seen[normalized]) {
			seen[normalized] = true;
			addresses.push(normalized);
		}
	}

	return addresses;
}

function serviceLabel(name) {
	var labels = {
		openai: 'OpenAI',
		anthropic_ai: 'Anthropic',
		google_ai: 'Google AI',
		x_ai: 'xAI',
		hdrezka: 'HDRezka',
		google_play: 'Google Play',
		google_meet: 'Google Meet',
		digitalocean: 'DigitalOcean',
		cloudfront: 'CloudFront'
	};
	if (labels[name])
		return labels[name];
	return name.replace(/_/g, ' ').replace(/\b\w/g, function(letter) {
		return letter.toUpperCase();
	});
}

// Ordered service categories. Any catalog name not listed here falls into the
// trailing "Other" group, so adding a new service still shows up.
var SERVICE_CATEGORIES = [
	{ title: 'AI',
	  names: [ 'openai', 'anthropic_ai', 'google_ai', 'midjourney',
	           'perplexity', 'mistral', 'huggingface', 'stability_ai', 'x_ai' ] },
	{ title: 'Social & messaging',
	  names: [ 'telegram', 'discord', 'twitter', 'meta', 'linkedin' ] },
	{ title: 'Video & music',
	  names: [ 'youtube', 'tiktok', 'hdrezka', 'spotify', 'google_meet' ] },
	{ title: 'Games & stores',
	  names: [ 'roblox', 'google_play' ] },
	{ title: 'Infrastructure (broad — use with care)',
	  names: [ 'cloudflare', 'cloudfront', 'digitalocean', 'hetzner', 'ovh' ] }
];

var BROAD_SERVICES = /^(cloudflare|cloudfront|digitalocean|hetzner|ovh)$/;
function serviceTitle(record) {
	return record.label && record.label !== record.id ? record.label : serviceLabel(record.id);
}

// The catalogue in its categories: [ { title, records } ], the user's own
// services in a group of their own and whatever no category names in "Other".
function catalogGroups(records) {
	var byId = {}, used = {}, groups = [];
	records.forEach(function(record) { byId[record.id] = record; });
	function group(title, list) {
		if (list.length)
			groups.push({ title: title, records: list });
	}
	SERVICE_CATEGORIES.forEach(function(category) {
		group(category.title, category.names.filter(function(name) {
			return byId[name] && byId[name].origin !== 'custom';
		}).map(function(name) {
			used[name] = true;
			return byId[name];
		}));
	});
	function byTitle(a, b) { return serviceTitle(a).localeCompare(serviceTitle(b)); }
	group('Other', records.filter(function(record) {
		return record.origin !== 'custom' && !used[record.id];
	}).sort(byTitle));
	group('Custom services', records.filter(function(record) {
		return record.origin === 'custom';
	}).sort(byTitle));
	return groups;
}

function parseServiceRecords(text) {
	return (text || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('|');
		if ((fields.length !== 5 && fields.length !== 6) || !/^[a-z0-9_]+$/.test(fields[0]))
			return null;
		return {
			id: fields[0], label: fields[1], origin: fields[2],
			customized: fields[3], ip: fields[4], mode: fields[5] || 'route'
		};
	}).filter(Boolean);
}

function parseServiceDetails(text) {
	var details = { domains: '', cidrs: '' };
	var section = '';
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		if (line === '---domains---') { section = 'domains'; return; }
		if (line === '---cidrs---') { section = 'cidrs'; return; }
		if (section) {
			details[section] += line + '\n';
			return;
		}
		var eq = line.indexOf('=');
		if (eq > 0)
			details[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return details;
}

// `sources` prints page-level keys first, then one block per selected service
// introduced by a ---service--- line.
function parseSources(text) {
	var head = {};
	var services = [];
	var current = null;
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		if (line === '---service---') {
			current = {};
			services.push(current);
			return;
		}
		var eq = line.indexOf('=');
		if (eq > 0)
			(current || head)[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return { head: head, services: services };
}

function parseStatus(text) {
	var out = {};
	var lines = (text || '').replace(/\r/g, '').split('\n');
	for (var i = 0; i < lines.length; i++) {
		var eq = lines[i].indexOf('=');
		if (eq > 0)
			out[lines[i].slice(0, eq)] = lines[i].slice(eq + 1);
	}
	return out;
}

// Poll the status file until its `updated` timestamp differs from `prev`
// (meaning our apply run finished) or the deadline passes. Resolves with the
// parsed status object, or null on timeout.
function pollStatus(actionId, deadline, onProgress) {
	return L.resolveDefault(fs.exec(communityHelper, [ 'status', actionId ]), {
		stdout: ''
	}).then(function(response) {
		var st = parseStatus((response && response.stdout) || '');
		if (st.action_id === actionId && st.state === 'running' && onProgress)
			onProgress(st);
		if (st.action_id === actionId && (st.state === 'ok' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1500);
		}).then(function() {
			return pollStatus(actionId, deadline, onProgress);
		});
	});
}

function pollDomainRouter(actionId, deadline) {
	return L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
		code: 1, stdout: ''
	}).then(function(response) {
		var st = parseStatus((response || {}).stdout || '');
		if (st.action_id === actionId &&
		    (st.state === 'active' || st.state === 'disabled' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1000);
		}).then(function() {
			return pollDomainRouter(actionId, deadline);
		});
	});
}

function pollResolverDiagnostic(actionId, deadline) {
	return L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
		code: 1, stdout: ''
	}).then(function(response) {
		var st = parseStatus((response || {}).stdout || '');
		if (st.action_id === actionId && st.state === 'error')
			return st;
		if (st.action_id === actionId && st.state === 'active' &&
		    (st.message || '').indexOf('FakeIP diagnostic completed;') === 0)
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1000);
		}).then(function() {
			return pollResolverDiagnostic(actionId, deadline);
		});
	});
}

// Refresh the on-page status block without a full reload.
return view.extend({
	load: function() {
		return Promise.all([
			// Textarea is bound to the manual file only — never fall back to the
			// combined list, or clearing/editing would silently reappear.
			L.resolveDefault(fs.read(manualFile), ''),
			L.resolveDefault(fs.read(selectedFile), ''),
			L.resolveDefault(fs.read(statusFile), ''),
			L.resolveDefault(fs.exec(communityHelper, [ 'services' ]), {
				code: 1, stdout: ''
			}),
			L.resolveDefault(fs.read(domainFile), ''),
			L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.read(manualAddressFile), ''),
			L.resolveDefault(fs.exec(communityHelper, [ 'sources' ]), {
				code: 1, stdout: ''
			}),
			L.resolveDefault(fs.read(excludeFile), ''),
			L.resolveDefault(fs.read(excludeAddressFile), ''),
			L.resolveDefault(fs.exec(managerHelper, [ 'tunnels-get' ]), { code: 1, stdout: '' }),
			L.resolveDefault(fs.read(exitsFile), ''),
			L.resolveDefault(fs.exec(managerHelper, [ 'tunnels-status' ]), { code: 1, stdout: '' })
		]);
	},

	doSave: function(result, onUpdated) {
		var textarea   = document.querySelector('#ikev2-domain-list');
		var addressTextarea = document.querySelector('#ikev2-address-list');
		var excludeTextarea = document.querySelector('#ikev2-exclude-domain-list');
		var excludeAddressTextarea = document.querySelector('#ikev2-exclude-address-list');
		var domains;
		var addresses;
		var excluded;
		var excludedAddresses;
		var selected = Object.keys(serviceSelection).sort();

		if (!textarea || !addressTextarea || !excludeTextarea || !excludeAddressTextarea) {
			result.err(_('Editor is not ready.'));
			return Promise.reject(new Error('textarea-missing'));
		}

		try {
			domains = normalizeDomains(textarea.value);
			addresses = normalizeAddresses(addressTextarea.value);
			excluded = normalizeDomains(excludeTextarea.value);
			excludedAddresses = normalizeAddresses(excludeAddressTextarea.value);
		}
		catch (error) {
			result.err(error.message);
			return Promise.reject(error);
		}

		var manualValue   = domains.join('\n') + (domains.length ? '\n' : '');
		var addressValue = addresses.join('\n') + (addresses.length ? '\n' : '');
		var selectedValue = selected.join('\n') + (selected.length ? '\n' : '');
		var excludeValue = excluded.join('\n') + (excluded.length ? '\n' : '');
		var excludeAddressValue = excludedAddresses.join('\n') + (excludedAddresses.length ? '\n' : '');
		var exitsValue = exitsText();

			var token = common.inputToken();
			var inputPrefix = '/tmp/ikev2-domains-input-' + token;
			return Promise.all([
				fs.write(inputPrefix + '.domains', manualValue, 384),
				fs.write(inputPrefix + '.cidrs', addressValue, 384),
				fs.write(inputPrefix + '.services', selectedValue, 384),
				fs.write(inputPrefix + '.xdomains', excludeValue, 384),
				fs.write(inputPrefix + '.xcidrs', excludeAddressValue, 384),
				fs.write(inputPrefix + '.exits', exitsValue, 384)
			])
					.then(function() {
						result.busy(_('Rebuilding the routing list…'));
						return common.execChecked(communityHelper, [ 'schedule', token ],
							_('Unable to start the routing list rebuild')).then(function(response) {
							textarea.value = manualValue;
							addressTextarea.value = addressValue;
							excludeTextarea.value = excludeValue;
							excludeAddressTextarea.value = excludeAddressValue;
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollStatus(actionId, Date.now() + 120000, function(st) {
							common.showProgress(result, st.message);
						});
					});
				})
				.then(function(st) {
					if (onUpdated)
						onUpdated(st);

					// Resolve with whether the lists were stored, so the page knows
					// what to compare the Save button against afterwards.
					if (!st) {
						result.warn(_('Saved; rebuild continues in the background.'));
						return true;
					}
					if (st.state === 'ok') {
						result.ok(_('%s domains active').format(st.domains != null ? st.domains : '?'));
						return true;
					}
					result.err(_('Rebuild failed: %s').format(st.message ? _(st.message) : _('unknown error')));
					return false;
				})
			.catch(function(error) {
				if (error.message !== 'textarea-missing')
					result.err(_('Unable to save: %s').format(error.message));
				return false;
			});
	},


	render: function(data) {
		var self = this;

		/* ── Domains tab ────────────────────────────────────────────────── */
		var manual = data[0] || '';
		var manualAddresses = data[6] || '';
		var excludedDomains = data[8] || '';
		var excludedAddresses = data[9] || '';
		var selected = {};
		var selectedLines = (data[1] || '').trim().split(/\s+/).filter(Boolean);
		var status = (data[2] || '').trim();
		var statusData = parseStatus(status);
		var routerStatus = parseStatus(((data[5] || {}).stdout || ''));
		var fakeipActive = routerStatus.engine === 'fakeip' &&
			routerStatus.service === 'running' &&
			routerStatus.nft === 'active' &&
			routerStatus.rule === 'active';
		var activeDomains = (data[4] || '').split('\n').filter(function(line) {
			return line.trim() && line.trim().charAt(0) !== '#';
		}).length;
		var policyPill = common.pill('', 'neutral');
		function updatePolicyStatus(st) {
			if (st && st.state === 'error') {
				common.setPill(policyPill, _('Policy error'), 'bad');
				return;
			}
			var active = st ? st.state === 'ok' :
				(statusData.state === 'ok' || activeDomains > 0);
			common.setPill(policyPill, active ? _('Policy active') : _('Policy empty'),
				active ? 'good' : 'warn');
		}
		updatePolicyStatus(null);
		var catalogResult = data[3] || {};
		serviceRecords = parseServiceRecords(catalogResult.stdout || '');

		/* ── Tunnels ────────────────────────────────────────────────────── */
		var tunnelChoices = parseTunnelChoices(((data[10] || {}).stdout) || '');
		var tunnelUp = parseTunnelStatus(((data[12] || {}).stdout) || '');
		var several = tunnelChoices.length > 1;
		tunnelIndexes = {};
		tunnelChoices.forEach(function(choice) { tunnelIndexes[choice.index] = true; });
		serviceExits = parseExits(data[11] || '');

		for (var i = 0; i < selectedLines.length; i++)
			selected[selectedLines[i]] = true;
		serviceSelection = Object.assign({}, selected);

		var engineResult = common.inlineResult();
		var routerTraffic = E('input', {
			'type': 'checkbox',
			'class': 'cbi-input-checkbox',
			'checked': routerStatus.route_router_traffic === '1' ? '' : null
		});
		var routerTrafficResult = common.inlineResult();
		routerTraffic.addEventListener('change', function() {
			var desired = routerTraffic.checked;
			return runPageAction({
				button: routerTraffic,
				result: routerTrafficResult,
				busy: _('Saving...'),
				run: function() {
					return common.execChecked(domainRouterHelper,
						[ 'router-traffic', desired ? '1' : '0' ],
						_('Unable to update router traffic policy')).then(function() {
						routerTrafficResult.ok(_('Saved.'));
					}, function(error) {
						routerTraffic.checked = !desired;
						throw error;
					});
				}
			});
		});
		var logLevel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'error' }, [ _('Errors only') ]),
			E('option', { 'value': 'warn' }, [ _('Warnings (recommended)') ]),
			E('option', { 'value': 'info' }, [ _('Information') ]),
			E('option', { 'value': 'debug' }, [ _('Debug') ]),
			E('option', { 'value': 'trace' }, [ _('Trace') ])
		]);
		logLevel.value = routerStatus.log_level || 'warn';
		var logLevelResult = common.inlineResult();
		logLevel.addEventListener('change', function() {
			var previous = routerStatus.log_level || 'warn';
			var desired = logLevel.value;
			return runPageAction({
				button: logLevel,
				result: logLevelResult,
				busy: _('Applying...'),
				run: function() {
					return common.execChecked(domainRouterHelper, [ 'log-level', desired ],
						_('Unable to update log level')).then(function() {
						routerStatus.log_level = desired;
						logLevelResult.ok(_('Saved.'));
					}, function(error) {
						logLevel.value = previous;
						throw error;
					});
				}
			});
		});
		var resolverDiagnosticResult = common.inlineResult();
		var resolverDiagnosticButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button',
			'disabled': fakeipActive ? null : ''
		}, [ _('Capture debug log for 60 seconds') ]);
		resolverDiagnosticButton.addEventListener('click', function() {
			return runPageAction({
				button: resolverDiagnosticButton,
				result: resolverDiagnosticResult,
				busy: _('Capturing FakeIP diagnostics...'),
				run: function() {
					return common.execChecked(domainRouterHelper,
						[ 'diagnostic-start', '60' ],
						_('Unable to start FakeIP diagnostics')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollResolverDiagnostic(actionId, Date.now() + 90000);
					}).then(function(st) {
						if (!st) {
							resolverDiagnosticResult.warn(_('The diagnostic continues in the background.'));
							return;
						}
						if (st.state === 'error')
							throw new Error(st.message ? _(st.message) : _('Diagnostic failed'));
						resolverDiagnosticResult.ok(st.message ? _(st.message) : _('Diagnostic completed.'));
					});
				}
			});
		});
		function engineLabel(active) {
			return active ? _('Matching by name (FakeIP)') : _('Matching by address');
		}
		function engineText(active) {
			return active ?
				_('Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.') :
				_('dnsmasq recognises selected domains by the public addresses they resolve to. An address shared with another site takes that site into the tunnel too, and an address change can let a selected site bypass it until it is resolved again.');
		}
		function engineButtonText(active) {
			return active ? _('Match by address instead') : _('Match by name (FakeIP)');
		}
		var enginePill = common.pill(engineLabel(fakeipActive), fakeipActive ? 'good' : 'warn');
		var engineSummary = E('p', { 'class': 'ikev2-engine-summary' }, [ engineText(fakeipActive) ]);
		var engineButton = E('button', {
			'class': 'cbi-button ' + (fakeipActive ? 'cbi-button-reset' : 'cbi-button-apply')
		}, [ engineButtonText(fakeipActive) ]);
		function updateEngineState(active, message) {
			fakeipActive = active;
			common.setPill(enginePill, engineLabel(active), active ? 'good' : 'warn');
			engineSummary.textContent = engineText(active);
			engineButton.className = 'cbi-button ' +
				(active ? 'cbi-button-reset' : 'cbi-button-apply');
			engineButton.textContent = engineButtonText(active);
			resolverDiagnosticButton.disabled = !active;
			if (message)
				engineResult.ok(message);
		}
		engineButton.addEventListener('click', function() {
			var command = fakeipActive ? 'deactivate-async' : 'activate-async';
			var targetActive = !fakeipActive;
			return runPageAction({
				button: engineButton,
				result: engineResult,
				busy: fakeipActive ? _('Disabling...') : _('Enabling...'),
				run: function() {
					return common.execChecked(domainRouterHelper, [ command ],
						_('Unable to start routing-engine change')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollDomainRouter(actionId, Date.now() + 60000);
					}).then(function(st) {
						if (st && st.state === 'error')
							throw new Error(st.message ? _(st.message) : _('Operation failed'));
						return st;
					});
				},
				// Relabel only after the button is restored, or the restore puts the
				// old label back.
				onSuccess: function(st) {
					if (!st) {
						engineResult.warn(_('The operation continues in the background.'));
						return;
					}
					updateEngineState(targetActive, st.message ? _(st.message) : _('Saved.'));
				}
			});
		});

		var serviceResult = common.inlineResult();
		var serviceBusy = false;
		var saveBtn;
		var policyTracker = null;
		var dialogTracker = null;
		var dialogControls = [];
		var editingService = null;
		var serviceLoadSequence = 0;
		// The chip the action bar is about, and the field a click in the
		// catalogue adds a service to.
		var chosen = null;
		var activeZone = '1';

		/* ── The four lists of one's own ────────────────────────────────── */
		// Created here: the board shows how many entries the two routed ones
		// hold, and a click on their chips leads to them.
		var listText = {
			'@domains': manual, '@cidrs': manualAddresses,
			'@xdomains': excludedDomains, '@xcidrs': excludedAddresses
		};
		function listArea(key, id, value, placeholder) {
			var area = E('textarea', {
				'id': id,
				'class': 'cbi-input-textarea ikev2-domain-editor',
				'spellcheck': 'false',
				'placeholder': placeholder || null
			}, [ value ]);
			area.addEventListener('input', function() {
				listText[key] = area.value;
				drawBoard();
			});
			return area;
		}
		var listAreas = {
			'@domains': listArea('@domains', 'ikev2-domain-list', manual),
			'@cidrs': listArea('@cidrs', 'ikev2-address-list', manualAddresses, '203.0.113.10\n198.51.100.0/24'),
			'@xdomains': listArea('@xdomains', 'ikev2-exclude-domain-list', excludedDomains, 'bank.example'),
			'@xcidrs': listArea('@xcidrs', 'ikev2-exclude-address-list', excludedAddresses, '198.51.100.0/24')
		};
		function listCount(key) {
			return String(listText[key] || '').split('\n').filter(function(line) {
				return line.trim() && line.trim().charAt(0) !== '#';
			}).length;
		}
		function showList(key) {
			var area = listAreas[key];
			if (area.scrollIntoView)
				area.scrollIntoView({ block: 'center' });
			area.focus();
		}

		/* ── Routes: a field per tunnel ─────────────────────────────────── */
		var routeBar = E('div', { 'class': 'ikev2-route-bar' });
		var routeLanes = E('div', { 'class': 'ikev2-routes' });
		var catalogBody = E('div', {});
		var dialogHost = E('div', {});
		var catalogSearch = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': _('Find a service'),
			'aria-label': _('Find a service')
		});
		var newServiceButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, [ _('New service') ]);

		function tunnelName(index) {
			for (var i = 0; i < tunnelChoices.length; i++)
				if (tunnelChoices[i].index === index)
					return tunnelChoices[i].name;
			return _('Tunnel %s').format(index);
		}
		// Every place a target can be put, in the order the page shows them.
		function zoneTokens(target) {
			var tokens = [];
			tunnelChoices.forEach(function(choice) {
				tokens.push(choice.index);
				if (several)
					tokens.push(choice.index + 's');
			});
			if (!target || target.charAt(0) !== '@')
				tokens.push('wan');
			return tokens;
		}
		function zoneName(token) {
			if (token === 'wan')
				return _('Never through the tunnel');
			var name = several ? tunnelName(token.charAt(0)) : _('Through the tunnel');
			return token.length > 1 ? _('%s, no backup').format(name) : name;
		}
		function targetTitle(target) {
			if (target === '@domains')
				return _('My domains');
			if (target === '@cidrs')
				return _('My addresses');
			var record = recordOf(target);
			return record ? serviceTitle(record) : serviceLabel(target);
		}
		function placedTargets(token) {
			return [ '@domains', '@cidrs' ].concat(Object.keys(serviceSelection).sort(function(a, b) {
				return targetTitle(a).localeCompare(targetTitle(b));
			})).filter(function(target) {
				return placeOf(target) === token;
			});
		}

		function moveTarget(target, token) {
			if (serviceBusy)
				return;
			if (target.charAt(0) === '@') {
				if (token === 'wan') {
					serviceResult.warn(_('Your own lists that stay out of the tunnel are the two at the bottom of the page.'));
					return;
				}
			}
			else {
				if (!recordOf(target))
					return;
				serviceSelection[target] = true;
			}
			serviceExits[target] = token;
			chosen = target;
			serviceResult.clear();
			drawBoard();
		}
		function removeTarget(target) {
			if (serviceBusy || target.charAt(0) === '@')
				return;
			delete serviceSelection[target];
			delete serviceExits[target];
			if (chosen === target)
				chosen = null;
			serviceResult.clear();
			drawBoard();
		}

		// A chip is dragged between fields; a click does the same through the
		// action bar, for a touch screen and a keyboard. TOKEN is where it lies,
		// null in the catalogue.
		function chip(target, token) {
			var record = target.charAt(0) === '@' ? null : recordOf(target);
			var placed = token !== null;
			var node = E('span', {
				'class': 'ikev2-chip ikev2-route-chip' + (chosen === target ? ' selected' : '') +
					(record && BROAD_SERVICES.test(target) ? ' broad' : ''),
				'role': 'button',
				'tabindex': '0',
				'draggable': 'true',
				'data-target': target,
				'title': placed ? _('Drag it to another field, or click for its actions') :
					_('Click to add it to the highlighted field, or drag it into one')
			}, [
				placed && token !== 'wan' && token.length > 1 ? common.icon('lock') : '',
				E('span', {}, [ targetTitle(target) +
					(record ? '' : ' · ' + listCount(target)) ]),
				record && BROAD_SERVICES.test(target) ? E('span', {
					'class': 'ikev2-chip-mark',
					'title': _('Broad — may also route unrelated sites')
				}, [ '⚠' ]) : '',
				record && record.ip === '1' ? E('span', {
					'class': 'ikev2-chip-mark',
					'title': _('Includes direct service IP networks')
				}, [ 'IP' ]) : ''
			]);
			function activate() {
				if (serviceBusy)
					return;
				if (!placed) {
					moveTarget(target, activeZone);
					return;
				}
				chosen = chosen === target ? null : target;
				drawBoard();
			}
			node.addEventListener('click', activate);
			node.addEventListener('keydown', function(ev) {
				if (ev && (ev.key === 'Enter' || ev.key === ' ')) {
					if (ev.preventDefault)
						ev.preventDefault();
					activate();
				}
			});
			node.addEventListener('dragstart', function(ev) {
				if (ev && ev.dataTransfer) {
					ev.dataTransfer.setData('text/plain', target);
					ev.dataTransfer.effectAllowed = 'move';
				}
			});
			return node;
		}
		// The two exclusion lists always stay out of the tunnel: shown where
		// they belong, and a click leads to their text.
		function listChip(key, label) {
			var node = E('span', {
				'class': 'ikev2-chip ikev2-route-chip fixed',
				'role': 'button',
				'tabindex': '0',
				'title': _('Edit this list at the bottom of the page')
			}, [ E('span', {}, [ label + ' · ' + listCount(key) ]) ]);
			node.addEventListener('click', function() { showList(key); });
			return node;
		}
		// A place chips are dropped into. TOKEN is where they go, null for
		// the catalogue, which takes a service out of the policy.
		function dropZone(token, chips, emptyText) {
			var zone = E('div', {
				'class': 'ikev2-route-zone',
				'data-zone': token === null ? 'catalog' : token
			}, chips.length ? chips : [
				E('span', { 'class': 'ikev2-route-zone-empty' }, [ emptyText ])
			]);
			zone.addEventListener('dragover', function(ev) {
				if (ev && ev.preventDefault)
					ev.preventDefault();
				zone.classList.add('over');
			});
			zone.addEventListener('dragleave', function() { zone.classList.remove('over'); });
			zone.addEventListener('drop', function(ev) {
				var target = ev && ev.dataTransfer ? ev.dataTransfer.getData('text/plain') : '';
				if (ev && ev.preventDefault)
					ev.preventDefault();
				zone.classList.remove('over');
				if (!target)
					return;
				if (token === null)
					removeTarget(target);
				else
					moveTarget(target, token);
			});
			return zone;
		}
		function tunnelPill(choice) {
			if (choice.enabled !== '1')
				return common.pill(_('Off'), 'neutral');
			if (tunnelUp[choice.index] === '1')
				return common.pill(_('Connected'), 'good');
			if (tunnelUp[choice.index] === '0')
				return common.pill(_('Not connected'), 'warn');
			return '';
		}
		function lane(token, title, pill, zones) {
			var head = E('div', {
				'class': 'ikev2-route-lane-head',
				'title': _('Click to make this the field new services go to')
			}, [ E('strong', {}, [ title ]), pill || '' ]);
			head.addEventListener('click', function() {
				activeZone = token;
				drawBoard();
			});
			return E('div', {
				'class': 'ikev2-route-lane' + (activeZone === token ? ' active' : ''),
				'data-lane': token
			}, [ head ].concat(zones));
		}
		function zoneWithLabel(token, label) {
			return E('div', {}, [
				label ? E('div', { 'class': 'ikev2-route-zone-label' }, [ label ]) : '',
				dropZone(token, placedTargets(token).map(function(target) {
					return chip(target, token);
				}), _('Drop a service here'))
			]);
		}

		function drawBar() {
			var nodes;
			if (!chosen) {
				nodes = [ E('span', { 'class': 'ikev2-field-help' }, [
					_('Drag a service into a field, or click it to choose where it goes. A click in the catalogue adds a service to the highlighted field.') ]) ];
			}
			else {
				var target = chosen, current = placeOf(target), own = target.charAt(0) === '@';
				var bound = current !== 'wan' && current.length > 1;
				nodes = [ E('strong', {}, [ targetTitle(target) ]) ];
				// One row whatever the number of tunnels: the tunnel, and whether
				// the service is bound to it.
				var where = E('select', {
					'class': 'cbi-input-select',
					'aria-label': _('Where it goes'),
					'data-act': 'where'
				}, tunnelChoices.map(function(choice) {
					return E('option', {
						'value': choice.index,
						'selected': current !== 'wan' && current.charAt(0) === choice.index ? '' : null
					}, [ several ? choice.name : _('Through the tunnel') ]);
				}).concat(own ? [] : [
					E('option', { 'value': 'wan', 'selected': current === 'wan' ? '' : null }, [
						_('Never through the tunnel') ])
				]));
				where.addEventListener('change', function() {
					moveTarget(target, where.value === 'wan' ? 'wan' : where.value + (bound ? 's' : ''));
				});
				nodes.push(where);
				if (several) {
					var bind = E('button', {
						'class': 'cbi-button ikev2-icon-button' + (bound ? ' cbi-button-action' : ''),
						'type': 'button',
						'data-act': 'bind',
						'aria-pressed': bound ? 'true' : 'false',
						'disabled': current === 'wan' ? '' : null,
						'title': _('Without backup the service waits for its own tunnel and is refused while it is down')
					}, [ common.icon('lock'), E('span', {}, [ _('No backup') ]) ]);
					bind.addEventListener('click', function() {
						if (current !== 'wan')
							moveTarget(target, current.charAt(0) + (bound ? '' : 's'));
					});
					nodes.push(bind);
				}
				var edit = E('button', { 'class': 'cbi-button', 'type': 'button', 'data-act': 'edit' }, [
					target.charAt(0) === '@' ? _('Edit list') : _('Edit') ]);
				edit.addEventListener('click', function() {
					if (target.charAt(0) === '@')
						showList(target);
					else
						requestService(recordOf(target), edit);
				});
				nodes.push(edit);
				if (target.charAt(0) !== '@') {
					var remove = E('button', { 'class': 'cbi-button', 'type': 'button', 'data-act': 'remove' }, [ _('Remove') ]);
					remove.addEventListener('click', function() { removeTarget(target); });
					nodes.push(remove);
				}
			}
			routeBar.replaceChildren.apply(routeBar, nodes);
		}
		function drawCatalog() {
			var query = String(catalogSearch.value || '').trim().toLowerCase();
			var nodes = [];
			catalogGroups(serviceRecords.filter(function(record) {
				return !serviceSelection[record.id] &&
					(!query || serviceTitle(record).toLowerCase().indexOf(query) >= 0 ||
					 record.id.indexOf(query) >= 0);
			})).forEach(function(group) {
				nodes.push(E('div', { 'class': 'ikev2-chip-group' }, [
					E('h4', {}, [ _(group.title) ]),
					E('div', { 'class': 'ikev2-chips' }, group.records.map(function(record) {
						return chip(record.id, null);
					}))
				]));
			});
			if (!serviceRecords.length)
				nodes.push(E('p', { 'class': 'alert-message warning' }, [
					_('The service catalog is unavailable. Saved selections and local services are preserved.') ]));
			else if (!nodes.length)
				nodes.push(E('span', { 'class': 'ikev2-route-zone-empty' }, [
					query ? _('No service matches.') : _('Every service is in use. Drop one here to take it out.') ]));
			var zone = dropZone(null, nodes, '');
			zone.className += ' ikev2-route-catalog';
			catalogBody.replaceChildren(zone);
		}
		function drawBoard() {
			if (chosen && chosen.charAt(0) !== '@' && !serviceSelection[chosen])
				chosen = null;
			var lanes = tunnelChoices.map(function(choice) {
				return lane(choice.index, several ? choice.name : _('Through the tunnel'),
					several ? tunnelPill(choice) : '',
					several ? [
						zoneWithLabel(choice.index, _('With backup: moves to another tunnel while this one is down')),
						zoneWithLabel(choice.index + 's', _('No backup: refused while this tunnel is down'))
					] : [ zoneWithLabel(choice.index, '') ]);
			});
			lanes.push(lane('wan', _('Never through the tunnel'), '', [
				E('div', {}, [
					dropZone('wan', placedTargets('wan').map(function(target) {
						return chip(target, 'wan');
					}).concat([
						listChip('@xdomains', _('Excluded domains')),
						listChip('@xcidrs', _('Excluded addresses'))
					]), '')
				])
			]));
			routeLanes.replaceChildren.apply(routeLanes, lanes);
			drawBar();
			drawCatalog();
			if (policyTracker)
				policyTracker.update();
		}
		catalogSearch.addEventListener('input', drawCatalog);

		/* ── Service definitions ────────────────────────────────────────── */
		function setServiceControlsBusy(busy, activeButton) {
			serviceBusy = busy;
			[ newServiceButton, saveBtn, engineButton, resolverDiagnosticButton, routerTraffic,
			  logLevel, refreshSourcesButton ].concat(dialogControls).forEach(function(control) {
				if (!control || control === activeButton)
					return;
				control.disabled = busy ||
					(control === resolverDiagnosticButton && !fakeipActive);
			});
			// Releasing the page must not re-enable a Save that has nothing to save.
			if (!busy) {
				if (policyTracker)
					policyTracker.update();
				if (dialogTracker)
					dialogTracker.update();
			}
		}

		function runPageAction(options) {
			if (serviceBusy)
				return Promise.resolve(null);
			setServiceControlsBusy(true, options.button);
			return common.runAction(options).finally(function() {
				setServiceControlsBusy(false, options.button);
			});
		}

		function refreshServiceRecords() {
			return common.execChecked(communityHelper, [ 'services' ],
				_('Unable to refresh the service catalog')).then(function(response) {
				serviceRecords = parseServiceRecords(response.stdout || '');
			});
		}

		function serviceMeta(operation, id, label, mode) {
			return 'operation=' + operation + '\n' +
				'id=' + id + '\n' +
				'label=' + label + '\n' +
				'selected=' + (operation === 'delete' ? '0' : 'keep') + '\n' +
				'mode=' + mode + '\n';
		}

		function reconcileServiceRecord(operation, previous, id, label, hasCidrs) {
			serviceRecords = serviceRecords.filter(function(record) {
				return record.id !== id;
			});
			if (operation === 'delete')
				return;
			if (operation === 'reset') {
				serviceRecords.push({
					id: id, label: id, origin: 'builtin', customized: '0',
					ip: previous && previous.ip === '1' ? '1' : '0', mode: 'route'
				});
				return;
			}
			serviceRecords.push({
				id: id,
				label: label,
				origin: previous && previous.origin === 'custom' ? 'custom' :
					(previous ? 'override' : 'custom'),
				customized: '1',
				ip: hasCidrs ? '1' : '0',
				mode: previous ? previous.mode : 'route'
			});
		}

		function closeDialog() {
			serviceLoadSequence++;
			editingService = null;
			dialogControls = [];
			dialogTracker = null;
			dialogHost.replaceChildren();
		}

		// One window for a new service and for an existing one: its name, what
		// it covers and where it goes. The identifier comes from the name.
		function showServiceDialog(record, details) {
			editingService = record || null;
			var name = E('input', {
				'class': 'cbi-input-text',
				'type': 'text',
				// A name, not a person's: no contact autofill.
				'autocomplete': 'off',
				'placeholder': _('My service'),
				'value': details ? (details.label === record.id ? serviceLabel(record.id) : details.label) : ''
			});
			// Two lists, each the height of the page's own list editors: a
			// prepared service runs to dozens of lines.
			function listField(text, placeholder) {
				var area = E('textarea', {
					'class': 'cbi-input-textarea ikev2-domain-editor',
					'spellcheck': 'false',
					'placeholder': placeholder
				}, [ text ]);
				area.value = text;
				return area;
			}
			var domainsField = listField(details ? details.domains.replace(/\n+$/, '') : '',
				'example.com\nstatic.example.com');
			var cidrsField = listField(details ? details.cidrs.replace(/\n+$/, '') : '',
				'203.0.113.0/24');
			var here = record && serviceSelection[record.id] ? placeOf(record.id) : (record ? '' : activeZone);
			var place = E('select', { 'class': 'cbi-input-select' },
				(record ? [ E('option', { 'value': '', 'selected': here === '' ? '' : null }, [ _('Not in use') ]) ] : [])
					.concat(zoneTokens(null).map(function(token) {
						return E('option', {
							'value': token,
							'selected': token === here ? '' : null
						}, [ zoneName(token) ]);
					})));
			var result = common.inlineResult();
			var save = E('button', { 'class': 'cbi-button cbi-button-apply', 'type': 'button' }, [ _('Save service') ]);
			var cancel = E('button', { 'class': 'cbi-button', 'type': 'button' }, [ _('Cancel') ]);
			var reset = record && record.origin !== 'custom' && record.customized === '1' ?
				E('button', { 'class': 'cbi-button cbi-button-reset', 'type': 'button' }, [ _('Restore prepared service') ]) : null;
			var remove = record && record.origin === 'custom' ?
				E('button', { 'class': 'cbi-button cbi-button-negative', 'type': 'button' }, [ _('Delete service') ]) : null;
			var fields = [ name, domainsField, cidrsField, place ];
			dialogControls = fields.concat([ save, cancel, reset, remove ]);

			function form() {
				return {
					name: (name.value || '').trim(),
					domains: domainsField.value,
					cidrs: cidrsField.value,
					place: place.value
				};
			}
			function run(button, busyLabel, operation) {
				return runPageAction({
					button: button,
					result: result,
					busy: busyLabel,
					failure: _('Service update failed'),
					run: function() { return runServiceOperation(operation, form(), result); }
				});
			}
			function dismiss() {
				if (serviceBusy)
					return;
				if (dialogTracker && dialogTracker.dirty() &&
				    !window.confirm(_('Discard unsaved service changes?')))
					return;
				closeDialog();
			}
			save.addEventListener('click', function() { return run(save, _('Saving service...'), 'save'); });
			cancel.addEventListener('click', dismiss);
			if (reset)
				reset.addEventListener('click', function() {
					if (window.confirm(_('Discard this local override and restore the prepared service?')))
						return run(reset, _('Restoring service...'), 'reset');
				});
			if (remove)
				remove.addEventListener('click', function() {
					if (window.confirm(_('Delete this custom service?')))
						return run(remove, _('Deleting service...'), 'delete');
				});

			var panel = E('div', {
				'class': 'ikev2-dialog',
				'role': 'dialog',
				'aria-modal': 'true',
				'aria-label': record ? _('Edit service') : _('New service')
			}, [
				E('h3', {}, [ record ? _('Edit service') : _('New service') ]),
				// Labels above their fields: the lists take the full width.
				E('div', { 'class': 'ikev2-dialog-field' }, [
					common.fieldLabel(_('Service name')),
					name
				]),
				E('div', { 'class': 'ikev2-dialog-lists' }, [
					E('div', { 'class': 'ikev2-dialog-field' }, [
						common.fieldLabel(_('Domains'),
							_('One domain per line. Subdomains are included automatically.')),
						domainsField
					]),
					E('div', { 'class': 'ikev2-dialog-field' }, [
						common.fieldLabel(_('IPv4 addresses and networks'),
							_('Optional; one IPv4 address or CIDR per line.')),
						cidrsField
					])
				]),
				E('div', { 'class': 'ikev2-dialog-field' }, [
					common.fieldLabel(_('Where it goes'),
						several ? _('With backup it moves to another tunnel while its own is down; without, it is refused meanwhile.') : null),
					place
				]),
				record && record.origin !== 'custom' ? E('p', { 'class': 'ikev2-field-help' }, [
					_('A prepared service: saving keeps your own copy of its list on this router.') ]) : '',
				result.node,
				E('div', { 'class': 'ikev2-actions end' }, [ cancel, reset || '', remove || '', save ])
			]);
			var backdrop = E('div', { 'class': 'ikev2-dialog-backdrop' }, [ panel ]);
			backdrop.addEventListener('click', function(ev) {
				if (ev && ev.target === backdrop)
					dismiss();
			});
			backdrop.addEventListener('keydown', function(ev) {
				if (ev && ev.key === 'Escape')
					dismiss();
			});
			// The theme's own ground: the nearest ancestor that paints one.
			var ground = '';
			for (var node = dialogHost; node && !ground && window.getComputedStyle; node = node.parentNode) {
				var paint = node.nodeType === 1 ? window.getComputedStyle(node).backgroundColor : '';
				if (paint && paint !== 'transparent' && !/^rgba\(.*,\s*0\)$/.test(paint))
					ground = paint;
			}
			if (ground)
				panel.style.backgroundColor = ground;
			dialogHost.replaceChildren(backdrop);
			dialogTracker = common.trackChanges(save, fields);
			name.focus();
		}

		function requestService(record, sourceButton) {
			if (!record || serviceBusy)
				return Promise.resolve(null);
			var sequence = ++serviceLoadSequence;
			if (sourceButton)
				common.setBusy(sourceButton, true, _('Loading service...'));
			setServiceControlsBusy(true, sourceButton);
			return common.execChecked(communityHelper, [ 'service-read', record.id ],
				_('Unable to load service')).then(function(response) {
				if (sequence === serviceLoadSequence)
					showServiceDialog(record, parseServiceDetails(response.stdout || ''));
			}, function(error) {
				if (sequence === serviceLoadSequence)
					serviceResult.err(error.message);
			}).finally(function() {
				setServiceControlsBusy(false, sourceButton);
				if (sourceButton)
					common.setBusy(sourceButton, false);
			});
		}

		function runServiceOperation(operation, form, result) {
			var previous = editingService;
			var id = previous ? previous.id : serviceIdFrom(form.name);
			var label = form.name;
			var domains = [];
			var cidrs = [];
			if (operation === 'save') {
				if (!label || label.length > 80 || /[|\r\n]/.test(label))
					return Promise.reject(new Error(_('Enter a service name up to 80 characters.')));
				try {
					domains = normalizeDomains(form.domains);
					cidrs = normalizeAddresses(form.cidrs);
				}
				catch (error) {
					return Promise.reject(error);
				}
				if (!domains.length && !cidrs.length)
					return Promise.reject(new Error(_('Add at least one domain or IPv4 network.')));
			}
			var token = common.inputToken();
			var prefix = '/tmp/ikev2-service-input-' + token;
			return Promise.all([
				// The mark of an earlier release is kept as it is: where the
				// service goes is the board's to say, and the board overrides it.
				fs.write(prefix + '.meta', serviceMeta(operation, id, label,
					previous && previous.mode === 'exclude' ? 'exclude' : 'route'), 384),
				fs.write(prefix + '.domains', domains.join('\n') + (domains.length ? '\n' : ''), 384),
				fs.write(prefix + '.cidrs', cidrs.join('\n') + (cidrs.length ? '\n' : ''), 384)
			]).then(function() {
				return common.execChecked(communityHelper, [ 'service-schedule', token ],
					_('Unable to start service update'));
			}).then(function(response) {
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId)
					throw new Error(_('Action did not start'));
				return pollStatus(actionId, Date.now() + 120000, function(st) {
					common.showProgress(result, st.message);
				});
			}).then(function(st) {
				if (!st)
					return 'timeout';
				if (st.state !== 'ok')
					throw new Error(st.message ? _(st.message) : _('Service update failed'));
				return refreshServiceRecords().then(function() { return true; },
					function() { return false; });
			}).then(function(refreshed) {
				if (refreshed === 'timeout') {
					result.warn(_('The operation is still running in the background.'));
					return;
				}
				if (!refreshed)
					reconcileServiceRecord(operation, previous, id, label, cidrs.length > 0);
				if (operation === 'delete' || (operation === 'save' && form.place === '')) {
					delete serviceSelection[id];
					delete serviceExits[id];
				}
				else if (operation === 'save') {
					serviceSelection[id] = true;
					serviceExits[id] = form.place;
					chosen = id;
				}
				closeDialog();
				drawBoard();
				var success = operation === 'delete' ? _('Custom service deleted and policy rebuilt.') :
					(operation === 'reset' ? _('Prepared service restored and policy rebuilt.') :
					 _('Service saved. Active policy was rebuilt when required.'));
				if (policyTracker && policyTracker.dirty())
					success += ' ' + _('Press Save to apply where it goes.');
				if (refreshed)
					serviceResult.ok(success);
				else
					serviceResult.warn(success + ' ' + _('Reload the page to refresh the service catalog.'));
			});
		}

		newServiceButton.addEventListener('click', function() {
			if (!serviceBusy)
				showServiceDialog(null, null);
		});
		drawBoard();

		var domainsContent = E('div', {}, [
			common.section(_('Domain routing'),
				_('Selected domains go through the IKEv2 tunnel. Other traffic continues through the normal WAN.'),
				E('div', { 'class': 'ikev2-engine' }, [
					E('div', { 'class': 'ikev2-engine-head' }, [
						E('div', { 'class': 'ikev2-engine-state' }, [
							enginePill,
							engineSummary
						])
					]),
					E('div', { 'style': 'margin-top:1rem' }, [
						common.toggleRow(routerTraffic,
							_('Route router services by domain policy'),
							_('In Reliable mode, selected domains requested by services on this router use the outbound tunnel. Tunnel transport and local management addresses remain direct.'),
							routerTrafficResult.node)
					]),
					E('details', { 'class': 'ikev2-advanced', 'style': 'margin-top:1rem' }, [
						E('summary', {}, [ _('Logging') ]),
						E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
							common.fieldLabel(_('FakeIP resolver log level'),
								_('Warnings are quiet enough for normal operation. Information, debug and trace can quickly evict unrelated system events. Changing this while Reliable mode is active restarts its resolver.')),
							logLevel,
							common.fieldLabel(_('Temporary diagnostics'),
								_('Temporarily switches the FakeIP resolver to debug logging, then restores the selected normal level automatically. Starting and ending the capture restart the resolver.')),
							resolverDiagnosticButton
						]),
						Number(routerStatus.system_log_size || 0) > 0 &&
						Number(routerStatus.system_log_size || 0) < 512 ?
							E('div', { 'class': 'ikev2-note warn', 'style': 'margin-top:.75rem' }, [
								_('The system log buffer is only %s KiB. Keep the normal level at Warnings and use timed diagnostics for troubleshooting.').format(routerStatus.system_log_size)
							]) : '',
						logLevelResult.node,
						resolverDiagnosticResult.node
					]),
					E('details', { 'class': 'ikev2-advanced', 'style': 'margin-top:1rem' }, [
						E('summary', {}, [ _('How selected domains are recognised') ]),
						E('div', { 'class': 'ikev2-engine-head' }, [
							E('p', { 'class': 'ikev2-engine-summary' }, [
								_('By name (FakeIP), the default, recognises each selected domain by its name through sing-box. By address works without sing-box: dnsmasq records the addresses selected domains resolve to. The router never switches between them on its own.')
							]),
							E('div', { 'class': 'ikev2-engine-action' }, [
								engineResult.node,
								engineButton
							])
						])
					])
				])),
			common.section(_('Routes'),
				several ?
					_('Each field is a tunnel, and what lies in it goes through that tunnel. With backup a service moves to another tunnel while its own is down; without, it waits for its own and is refused meanwhile. Nothing goes to the WAN in either case.') :
					_('What lies in the first field goes through the tunnel; everything else continues through the normal WAN.'),
				E('div', {}, [
					routeBar,
					routeLanes,
					serviceResult.node
				])),
			common.section(_('Catalogue'),
				_('Prepared services and your own. A click adds one to the highlighted field; dragging one back here takes it out.'),
				catalogBody,
				E('div', { 'class': 'ikev2-actions' }, [ catalogSearch, newServiceButton ])),
			dialogHost,
			buildSourcesSection(data[7]),
			E('div', { 'class': 'ikev2-destination-editors' }, [
				common.section(_('Custom domains'),
					_('One plain domain per line. Custom entries are never overwritten by service updates.'),
					listAreas['@domains']),
				common.section(_('Custom IP addresses and networks'),
					_('One IPv4 address or CIDR network per line. A single address is stored as /32.'),
					listAreas['@cidrs']),
				common.section(_('Domains never through the tunnel'),
					_('One domain per line; its subdomains are excluded too. It wins over every selected service and custom domain.'),
					listAreas['@xdomains']),
				common.section(_('Addresses never through the tunnel'),
					_('One IPv4 address or CIDR network per line. Traffic to them never takes the tunnel, whatever selects it.'),
					listAreas['@xcidrs'])
			])
		]);

		var refreshSourcesButton;

		function sourceStamp(value) {
			return value ? common.formatDate(Number(value) * 1000) : '';
		}

		function describeSourceList(record, kind, now) {
			var origin = record[kind + '_origin'];
			var lines = [];
			var notes = [];
			if (!origin)
				return E('div', {}, [ '—' ]);
			var label = {
				bundled: _('Built into the package'),
				community: _('Community list'),
				vendor: _('Vendor list'),
				user: _('Custom definition')
			}[origin] || origin;
			var entries = record[kind + '_entries'] || record[kind + '_bundled'];
			lines.push(entries ? _('%s, %s entries').format(label, entries) : label);
			if (origin === 'vendor' && record[kind + '_url'])
				lines.push(_('from %s').format(record[kind + '_url'].replace(/^https?:\/\/([^\/]+).*$/, '$1')));
			if (record[kind + '_fetched'])
				lines.push(_('updated %s').format(sourceStamp(record[kind + '_fetched'])));
			if (Number(record[kind + '_added'] || 0) || Number(record[kind + '_removed'] || 0))
				lines.push(_('last change %s: +%s / −%s').format(sourceStamp(record[kind + '_changed']),
					record[kind + '_added'] || 0, record[kind + '_removed'] || 0));
			if (record[kind + '_sha256'])
				lines.push(E('span', { 'title': record[kind + '_sha256'] }, [
					_('SHA-256 %s').format(record[kind + '_sha256'].slice(0, 12))
				]));
			if (record[kind + '_stale'] === '1')
				notes.push(_('Not updated for %s').format(
					common.formatDuration(now - Number(record[kind + '_fetched'] || now))));
			if (record[kind + '_error'])
				notes.push(_('Last update failed: %s').format(_(record[kind + '_error'])));
			return E('div', {}, lines.map(function(line) {
				return E('div', {}, [ line ]);
			}).concat(notes.map(function(note) {
				return E('div', { 'class': 'ikev2-note warn', 'style': 'margin-top:.35rem' }, [ note ]);
			})));
		}

		function renderSourcesBody(body, text) {
			var parsed = parseSources(text);
			var head = parsed.head;
			var now = Number(head.now || Math.floor(Date.now() / 1000));
			var rows = [];
			var wasOpen = !!(body.querySelector && body.querySelector('details[open]'));
			while (body.firstChild)
				body.removeChild(body.firstChild);
			body.appendChild(E('p', {}, [
				head.refresh_last_success ?
					_('Last full update: %s').format(sourceStamp(head.refresh_last_success)) :
					_('Lists have not been updated on this router yet.')
			]));
			if (Number(head.refresh_last_error || 0) > Number(head.refresh_last_success || 0))
				body.appendChild(E('div', { 'class': 'ikev2-note warn' }, [
					_('The last scheduled update failed; the previous lists are still in use.')
				]));
			if (!parsed.services.length) {
				body.appendChild(E('p', {}, [ _('Select services above to see their list sources.') ]));
				return;
			}
			rows.push(E('strong', {}, [ _('Service') ]), E('strong', {}, [ _('Domains') ]),
				E('strong', {}, [ _('Networks') ]));
			parsed.services.forEach(function(record) {
				rows.push(E('div', {}, [ record.label || serviceLabel(record.service) ]),
					describeSourceList(record, 'domains', now),
					describeSourceList(record, 'networks', now));
			});
			// The table runs to a screen or more with every service selected; the
			// last update and a failure stay in view, the per-service list folds.
			body.appendChild(E('details', { 'class': 'ikev2-diagnostics', 'open': wasOpen ? '' : null }, [
				E('summary', {}, [ _('Sources for each service') ]),
				E('div', {
					'class': 'ikev2-diagnostics-body',
					'style': 'display:grid;grid-template-columns:minmax(7rem,1fr) 2fr 2fr;gap:.6rem 1rem;align-items:start;padding-top:.75rem'
				}, rows)
			]));
		}

		function buildSourcesSection(response) {
			var body = E('div', {});
			var result = common.inlineResult();
			renderSourcesBody(body, (response || {}).stdout || '');
			refreshSourcesButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('Update lists now') ]);
			refreshSourcesButton.addEventListener('click', function() {
				if (serviceBusy)
					return;
				setServiceControlsBusy(true, refreshSourcesButton);
				return common.runJob({
					button: refreshSourcesButton,
					result: result,
					busy: _('Updating lists...'),
					startPath: communityHelper,
					startArgs: [ 'refresh-schedule', 'force' ],
					statusPath: communityHelper,
					statusArgs: [ 'status' ],
					timeout: 180000,
					failure: _('Unable to start the list update'),
					success: _('Lists updated.'),
					onSuccess: function() {
						return L.resolveDefault(fs.exec(communityHelper, [ 'sources' ]), {
							stdout: ''
						}).then(function(fresh) {
							renderSourcesBody(body, (fresh || {}).stdout || '');
						});
					}
				}).finally(function() {
					setServiceControlsBusy(false, refreshSourcesButton);
				});
			});
			return common.section(_('List sources'),
				_('Where each selected service gets its domains and networks. Lists update after every boot and then once a day; a failed download keeps the last good copy.'),
				body, E('div', { 'class': 'ikev2-actions' }, [
					result.node,
					refreshSourcesButton
				]));
		}

		var saveResult = common.inlineResult();
		saveBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Save') ]);
		saveBtn.addEventListener('click', function() {
			return runPageAction({
				button: saveBtn,
				result: saveResult,
				busy: _('Saving...'),
				run: function() {
					return self.doSave(saveResult, updatePolicyStatus);
				},
				onSuccess: function(saved) {
					if (saved)
						policyTracker.reset();
				}
			});
		});

		// Save is grey until the custom lists or the selected services differ
		// from what was loaded or last saved.
		policyTracker = common.trackChanges(saveBtn, [ domainsContent ], {
			read: function() {
				var domains = domainsContent.querySelector('#ikev2-domain-list');
				var addresses = domainsContent.querySelector('#ikev2-address-list');
				var excluded = domainsContent.querySelector('#ikev2-exclude-domain-list');
				var excludedAddresses = domainsContent.querySelector('#ikev2-exclude-address-list');
				return JSON.stringify([ domains ? domains.value : '',
					addresses ? addresses.value : '', excluded ? excluded.value : '',
					excludedAddresses ? excludedAddresses.value : '',
					Object.keys(serviceSelection).sort(), exitsText() ]);
			}
		});

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Policy Routing'),
					_('Build the IPv4 VPN policy from curated services, custom destinations and per-device modes.'),
					policyPill),
				domainsContent,
				// A card like the other pages' save bars; left bare it sat on the
				// LuCI footer rule.
				E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
					E('span', { 'class': 'ikev2-field-help' }, [
						_('Saves where each service and list goes, then rebuilds the routing list.') ]),
					saveResult.node,
					saveBtn
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
