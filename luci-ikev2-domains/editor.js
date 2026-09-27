'use strict';
'require view';
'require fs';
'require ikev2-manager.shared-v11 as common';

var domainFile    = '/etc/pbr-ikev2-domains.txt';
var manualFile    = '/etc/pbr-ikev2-domains.manual.txt';
var manualAddressFile = '/etc/pbr-ikev2-addresses.manual.txt';
var selectedFile  = '/etc/pbr-ikev2-community-selected.txt';
var statusFile    = '/tmp/ikev2-domains-community.status';
var communityHelper = '/usr/libexec/ikev2-domains-community';
var domainRouterHelper = '/usr/libexec/ikev2-domain-router';
var serviceSelection = {};
var serviceRecords = [];

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
// Compact selectable chip (replaces the bulky per-service checkbox card).
function serviceChip(record, selected) {
	var name = record.id;
	var broad = BROAD_SERVICES.test(name);
	var ipNetworks = record.ip === '1';
	var input = E('input', {
		'type': 'checkbox',
		'class': 'ikev2-community-service',
		'value': name,
		'checked': selected[name] ? '' : null
	});
	var chip = E('label', {
		'class': 'ikev2-chip'
	}, [
		input,
		E('span', {}, [ record.label && record.label !== name ? record.label : serviceLabel(name) ]),
		broad ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Broad — may also route unrelated sites')
		}, [ '⚠' ]) : '',
		ipNetworks ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Includes direct service IP networks')
		}, [ 'IP' ]) : ''
	]);
	chip.className += (broad ? ' broad' : '') +
		(selected[name] ? ' selected' : '');
	input.addEventListener('change', function() {
		chip.classList.toggle('selected', input.checked);
		if (input.checked)
			serviceSelection[name] = true;
		else
			delete serviceSelection[name];
	});
	return chip;
}

// Group a flat catalog list into ordered category blocks. Unmatched names
// collect into a trailing "Other" group.
function renderServiceGroups(services, selected) {
	var available = {};
	services.forEach(function(record) { available[record.id] = record; });

	var used   = {};
	var blocks = [];

	function block(title, names) {
		var items = names.filter(function(n) {
			return available[n] && available[n].origin !== 'custom';
		})
			.map(function(n) {
				used[n] = true;
				return serviceChip(available[n], selected);
			});
		if (!items.length)
			return;
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _(title) ]),
			E('div', { 'class': 'ikev2-chips' }, items)
		]));
	}

	SERVICE_CATEGORIES.forEach(function(cat) { block(cat.title, cat.names); });

	var others = services.filter(function(record) {
		return record.origin !== 'custom' && !used[record.id];
	}).map(function(record) { return record.id; }).sort();
	block('Other', others);
	var custom = services.filter(function(record) {
		return record.origin === 'custom';
	}).sort(function(a, b) {
		return (a.label || a.id).localeCompare(b.label || b.id);
	});
	if (custom.length) {
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _('Custom services') ]),
			E('div', { 'class': 'ikev2-chips' }, custom.map(function(record) {
				return serviceChip(record, selected);
			}))
		]));
	}

	return blocks;
}

function parseServiceRecords(text) {
	return (text || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('|');
		if (fields.length !== 5 || !/^[a-z0-9_]+$/.test(fields[0]))
			return null;
		return {
			id: fields[0], label: fields[1], origin: fields[2],
			customized: fields[3], ip: fields[4]
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
			})
		]);
	},

	doSave: function(result, onUpdated) {
		var textarea   = document.querySelector('#ikev2-domain-list');
		var addressTextarea = document.querySelector('#ikev2-address-list');
		var domains;
		var addresses;
		var selected = Object.keys(serviceSelection).sort();

		if (!textarea || !addressTextarea) {
			result.err(_('Editor is not ready.'));
			return Promise.reject(new Error('textarea-missing'));
		}

		try {
			domains = normalizeDomains(textarea.value);
			addresses = normalizeAddresses(addressTextarea.value);
		}
		catch (error) {
			result.err(error.message);
			return Promise.reject(error);
		}

		var manualValue   = domains.join('\n') + (domains.length ? '\n' : '');
		var addressValue = addresses.join('\n') + (addresses.length ? '\n' : '');
		var selectedValue = selected.join('\n') + (selected.length ? '\n' : '');

			var token = common.inputToken();
			var inputPrefix = '/tmp/ikev2-domains-input-' + token;
			return Promise.all([
				fs.write(inputPrefix + '.domains', manualValue, 384),
				fs.write(inputPrefix + '.cidrs', addressValue, 384),
				fs.write(inputPrefix + '.services', selectedValue, 384)
			])
					.then(function() {
						result.busy(_('Rebuilding the routing list…'));
						return common.execChecked(communityHelper, [ 'schedule', token ],
							_('Unable to start the routing list rebuild')).then(function(response) {
							textarea.value = manualValue;
							addressTextarea.value = addressValue;
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
		// Two columns: the catalogue is a tall stack of short chip rows, so half
		// the width was empty and the custom services sat below the fold.
		var serviceCatalog = E('div', { 'class': 'ikev2-service-catalog' });
		var serviceEditor = E('div', {
			'class': 'ikev2-service-editor',
			'style': 'display:none;'
		});
		var serviceId = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': 'my_service'
		});
		var serviceName = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': _('My service')
		});
		var serviceDomains = E('textarea', {
			'class': 'cbi-input-textarea ikev2-domain-editor ikev2-domain-editor-small',
			'spellcheck': 'false',
			'placeholder': 'example.com\nstatic.example.com'
		});
		var serviceCidrs = E('textarea', {
			'class': 'cbi-input-textarea ikev2-domain-editor ikev2-domain-editor-small',
			'spellcheck': 'false',
			'placeholder': '203.0.113.0/24'
		});
		var serviceEditorTitle = E('h3');
		var servicePicker = E('select', {
			'class': 'cbi-input-select'
		});
		var servicePickerLabel = common.fieldLabel(_('Service to edit'),
			_('Choose a service to inspect or edit, or start a new one.'));
		var servicePickerControl = E('div', { 'class': 'ikev2-picker-row' });
		var serviceSave = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Save service') ]);
		var serviceReset = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'type': 'button'
		}, [ _('Restore prepared service') ]);
		var serviceDelete = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'type': 'button'
		}, [ _('Delete service') ]);
		var serviceCancel = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, [ _('Cancel') ]);
		var editingService = null;
		var serviceLoadSequence = 0;
		var serviceBusy = false;
		var serviceDirty = false;
		var manageServicesButton;
		var addServiceButton;
		var saveBtn;
		var policyTracker = null;
		var serviceTracker = null;

		var serviceFields = [ serviceId, serviceName, serviceDomains, serviceCidrs ];
		serviceFields.forEach(function(field) {
			field.addEventListener('input', function() { serviceDirty = true; });
			field.addEventListener('change', function() { serviceDirty = true; });
		});

		function serviceEditorVisible() {
			return serviceEditor.style.display !== 'none';
		}

		function confirmDiscardServiceChanges() {
			return !serviceEditorVisible() || !serviceDirty ||
				window.confirm(_('Discard unsaved service changes?'));
		}

		function setServiceControlsBusy(busy, activeButton) {
			serviceBusy = busy;
			serviceFields.forEach(function(field) {
				field.disabled = busy || (field === serviceId && !!editingService);
			});
			[ serviceSave, serviceReset, serviceDelete, serviceCancel,
			  manageServicesButton, addServiceButton, saveBtn, engineButton,
			  resolverDiagnosticButton, routerTraffic, logLevel, refreshSourcesButton ].forEach(function(button) {
				if (!button || button === activeButton)
					return;
				button.disabled = busy ||
					(button === resolverDiagnosticButton && !fakeipActive);
			});
			servicePicker.disabled = busy;
			var chips = serviceCatalog.querySelectorAll('input.ikev2-community-service');
			for (var i = 0; i < chips.length; i++)
				chips[i].disabled = busy;
			// Releasing the page must not re-enable a Save that has nothing to save.
			if (!busy) {
				if (policyTracker)
					policyTracker.update();
				if (serviceTracker)
					serviceTracker.update();
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

		function runServiceAction(button, busyLabel, operation) {
			return runPageAction({
				button: button,
				result: serviceResult,
				busy: busyLabel,
				failure: _('Service update failed'),
				run: operation
			});
		}

		function recordById(id) {
			for (var i = 0; i < serviceRecords.length; i++)
				if (serviceRecords[i].id === id)
					return serviceRecords[i];
			return null;
		}

		function renderCatalog() {
			while (serviceCatalog.firstChild)
				serviceCatalog.removeChild(serviceCatalog.firstChild);
			var nodes = renderServiceGroups(serviceRecords, serviceSelection);
			if (!nodes.length) {
				nodes.push(E('p', { 'class': 'alert-message warning' }, [
					_('The service catalog is unavailable. Saved selections and local services are preserved.')
				]));
			}
			nodes.forEach(function(node) { serviceCatalog.appendChild(node); });
		}

		function refreshServicePicker() {
			var current = servicePicker.value;
			var records = serviceRecords.slice().sort(function(a, b) {
				return (a.label || serviceLabel(a.id)).localeCompare(
					b.label || serviceLabel(b.id));
			});
			while (servicePicker.firstChild)
				servicePicker.removeChild(servicePicker.firstChild);
			records.forEach(function(record) {
				servicePicker.appendChild(E('option', {
					'value': record.id
				}, [ record.label && record.label !== record.id ?
					record.label : serviceLabel(record.id) ]));
			});
			if (recordById(current))
				servicePicker.value = current;
			else if (editingService && recordById(editingService.id))
				servicePicker.value = editingService.id;
		}

		function refreshServiceRecords() {
			return common.execChecked(communityHelper, [ 'services' ],
				_('Unable to refresh the service catalog')).then(function(response) {
				serviceRecords = parseServiceRecords(response.stdout || '');
				refreshServicePicker();
			});
		}

		function showServiceEditor(record, details) {
			editingService = record || null;
			serviceEditorTitle.textContent = record ?
				_('Edit service') : _('New service');
			// A new service has nothing to pick yet; the label and the control
			// are separate grid cells, so both have to go.
			servicePickerLabel.style.display = record ? '' : 'none';
			servicePickerControl.style.display = record ? '' : 'none';
			if (record)
				servicePicker.value = record.id;
			serviceId.value = record ? record.id : '';
			serviceId.disabled = !!record;
			serviceName.value = details ?
				(details.label === record.id ? serviceLabel(record.id) : details.label) : '';
			serviceDomains.value = details ? details.domains.replace(/\n$/, '') : '';
			serviceCidrs.value = details ? details.cidrs.replace(/\n$/, '') : '';
			serviceReset.style.display = record && record.origin !== 'custom' &&
				record.customized === '1' ? '' : 'none';
			serviceDelete.style.display = record && record.origin === 'custom' ? '' : 'none';
			serviceEditor.style.display = '';
			serviceDirty = false;
			if (serviceTracker)
				serviceTracker.reset();
			serviceResult.clear();
			(record ? serviceName : serviceId).focus();
		}

		function openService(record, sourceButton) {
			if (serviceBusy)
				return Promise.resolve(null);
			var sequence = ++serviceLoadSequence;
			if (sourceButton)
				common.setBusy(sourceButton, true, _('Loading service...'));
			setServiceControlsBusy(true, sourceButton);
			// A button already says it is loading; say it here only for a pick.
			if (sourceButton)
				serviceResult.clear();
			else
				serviceResult.busy(_('Loading service...'));
			return common.execChecked(communityHelper, [ 'service-read', record.id ],
				_('Unable to load service')).then(function(response) {
				if (sequence !== serviceLoadSequence)
					return;
				showServiceEditor(record, parseServiceDetails(response.stdout || ''));
			}, function(error) {
				if (sequence !== serviceLoadSequence)
					return;
				serviceResult.err(error.message);
			}).finally(function() {
				setServiceControlsBusy(false, sourceButton);
				if (sourceButton)
					common.setBusy(sourceButton, false);
			});
		}

		function requestService(record, sourceButton) {
			if (!record || serviceBusy)
				return Promise.resolve(null);
			if (serviceEditorVisible() && editingService &&
			    editingService.id === record.id) {
				serviceEditor.scrollIntoView({ block: 'nearest' });
				serviceName.focus();
				return Promise.resolve(record);
			}
			if (!confirmDiscardServiceChanges()) {
				if (editingService)
					servicePicker.value = editingService.id;
				return Promise.resolve(null);
			}
			serviceDirty = false;
			return openService(record, sourceButton);
		}

		function serviceMeta(operation, id, label) {
			return 'operation=' + operation + '\n' +
				'id=' + id + '\n' +
				'label=' + label + '\n' +
				'selected=' + (operation === 'delete' ? '0' : 'keep') + '\n';
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
					ip: previous && previous.ip === '1' ? '1' : '0'
				});
				return;
			}
			serviceRecords.push({
				id: id,
				label: label,
				origin: previous && previous.origin === 'custom' ? 'custom' :
					(previous ? 'override' : 'custom'),
				customized: '1',
				ip: hasCidrs ? '1' : '0'
			});
		}

		function runServiceOperation(operation) {
			var id = (serviceId.value || '').trim().toLowerCase();
			var label = (serviceName.value || '').trim();
			var previous = editingService;
			var domains = [];
			var cidrs = [];
			if (!/^[a-z0-9_]{2,48}$/.test(id))
				return Promise.reject(new Error(_('Service identifier must contain 2–48 lowercase letters, digits or underscores.')));
			if (!editingService && recordById(id))
				return Promise.reject(new Error(_('A service with this identifier already exists.')));
			if (operation === 'save') {
				if (!label || label.length > 80 || /[|\r\n]/.test(label))
					return Promise.reject(new Error(_('Enter a service name up to 80 characters.')));
				try {
					domains = normalizeDomains(serviceDomains.value);
					cidrs = normalizeAddresses(serviceCidrs.value);
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
				fs.write(prefix + '.meta', serviceMeta(operation, id, label), 384),
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
					common.showProgress(serviceResult, st.message);
				});
			}).then(function(st) {
				if (!st)
					return 'timeout';
				if (st.state !== 'ok')
					throw new Error(st.message ? _(st.message) : _('Service update failed'));
				if (operation === 'delete')
					delete serviceSelection[id];
				return refreshServiceRecords().then(function() { return true; },
					function() { return false; });
			}).then(function(refreshed) {
				if (refreshed === 'timeout') {
					serviceResult.warn(_('The operation is still running in the background.'));
					return;
				}
				if (!refreshed) {
					reconcileServiceRecord(operation, previous, id, label, cidrs.length > 0);
					refreshServicePicker();
				}
				serviceEditor.style.display = 'none';
				serviceDirty = false;
				renderCatalog();
				var success = operation === 'delete' ? _('Custom service deleted and policy rebuilt.') :
					(operation === 'reset' ? _('Prepared service restored and policy rebuilt.') :
					 _('Service saved. Active policy was rebuilt when required.'));
				if (refreshed)
					serviceResult.ok(success);
				else
					serviceResult.warn(success + ' ' + _('Reload the page to refresh the service catalog.'));
			});
		}

		serviceSave.addEventListener('click', function() {
			return runServiceAction(serviceSave, _('Saving service...'),
				function() { return runServiceOperation('save'); });
		});
		serviceReset.addEventListener('click', function() {
			if (!window.confirm(_('Discard this local override and restore the prepared service?')))
				return;
			return runServiceAction(serviceReset, _('Restoring service...'),
				function() { return runServiceOperation('reset'); });
		});
		serviceDelete.addEventListener('click', function() {
			if (!window.confirm(_('Delete this custom service?')))
				return;
			return runServiceAction(serviceDelete, _('Deleting service...'),
				function() { return runServiceOperation('delete'); });
		});
		serviceCancel.addEventListener('click', function() {
			if (serviceBusy || !confirmDiscardServiceChanges())
				return;
			serviceLoadSequence++;
			serviceEditor.style.display = 'none';
			serviceDirty = false;
			serviceResult.clear();
		});
		servicePicker.addEventListener('change', function() {
			var record = recordById(servicePicker.value);
			if (record)
				requestService(record, null);
		});

		addServiceButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, [ _('Add service') ]);
		addServiceButton.addEventListener('click', function() {
			if (serviceBusy || !confirmDiscardServiceChanges())
				return;
			serviceLoadSequence++;
			showServiceEditor(null, null);
		});
		servicePickerControl.appendChild(servicePicker);
		servicePickerControl.appendChild(addServiceButton);
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-service-editor-heading' }, [
			serviceEditorTitle
		]));
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
			servicePickerLabel, servicePickerControl,
			common.fieldLabel(_('Identifier'), _('Stable internal name; it cannot be changed after creation.')),
			serviceId,
			common.fieldLabel(_('Service name')),
			serviceName,
			common.fieldLabel(_('Domain suffixes'), _('One domain suffix per line. Subdomains are included automatically.')),
			serviceDomains,
			common.fieldLabel(_('IPv4 addresses and networks'), _('Optional; one IPv4 address or CIDR per line.')),
			serviceCidrs
		]));
		serviceEditor.appendChild(E('div', { 'class': 'ikev2-actions end' }, [
			serviceCancel, serviceReset, serviceDelete, serviceSave
		]));
		manageServicesButton = E('button', {
			'class': 'cbi-button cbi-button-action ikev2-icon-button',
			'type': 'button'
		}, [ common.icon('settings'), E('span', {}, [ _('Manage services') ]) ]);
		manageServicesButton.addEventListener('click', function() {
			var record = recordById(servicePicker.value) || serviceRecords[0];
			if (record)
				requestService(record, manageServicesButton);
			else
				showServiceEditor(null, null);
		});
		refreshServicePicker();
		renderCatalog();

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
			common.section(_('Services'),
				_('Prepared and user-created services stay in separate lists. Chips stage policy selection; the page Save button applies it. Service definitions are managed independently.'),
				E('div', {}, [
					serviceCatalog,
					serviceEditor,
					serviceResult.node
				]), E('div', { 'class': 'ikev2-actions' }, [
					manageServicesButton
				])),
			buildSourcesSection(data[7]),
			E('div', { 'class': 'ikev2-destination-editors' }, [
				common.section(_('Custom domains'),
					_('One plain domain per line. Custom entries are never overwritten by service updates.'),
					E('textarea', {
						'id': 'ikev2-domain-list',
						'class': 'cbi-input-textarea ikev2-domain-editor',
						'spellcheck': 'false'
					}, [ manual ])),
				common.section(_('Custom IP addresses and networks'),
					_('One IPv4 address or CIDR network per line. A single address is stored as /32.'),
					E('textarea', {
						'id': 'ikev2-address-list',
						'class': 'cbi-input-textarea ikev2-domain-editor',
						'spellcheck': 'false',
						'placeholder': '203.0.113.10\n198.51.100.0/24'
					}, [ manualAddresses ]))
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
				return JSON.stringify([ domains ? domains.value : '',
					addresses ? addresses.value : '', Object.keys(serviceSelection).sort() ]);
			}
		});
		serviceTracker = common.trackChanges(serviceSave, serviceFields);

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
						_('Saves the selected services and the custom lists, then rebuilds the routing list.') ]),
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
