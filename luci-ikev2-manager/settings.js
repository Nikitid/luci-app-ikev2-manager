'use strict';
'require view';
'require fs';
'require ikev2-manager.shared-v11 as common';

var helper = '/usr/libexec/ikev2-manager';
var systemHelper = '/usr/libexec/ikev2-manager-system';
var devicesHelper = '/usr/libexec/ikev2-devices';

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

function writeProfileInput(value) {
	var token = common.inputToken();
	return fs.write('/var/run/ikev2-manager-profile-' + token + '.in', value, 384)
		.then(function() { return token; });
}

function parseNamedValues(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var eq = line.indexOf('=');
		return eq > 0 ? { name: line.slice(0, eq), value: line.slice(eq + 1).trim() } : null;
	}).filter(Boolean);
}

function ipv4Number(value) {
	var parts = String(value || '').split('.');
	if (parts.length !== 4 || parts.some(function(part) {
		return !/^\d+$/.test(part) || Number(part) > 255;
	})) return null;
	return parts.reduce(function(total, part) { return total * 256 + Number(part); }, 0);
}

function cidrRange(value) {
	var parts = String(value || '').split('/');
	var address = ipv4Number(parts[0]);
	var prefix = Number(parts[1]);
	if (address == null || prefix < 0 || prefix > 32) return null;
	var size = Math.pow(2, 32 - prefix);
	var start = Math.floor(address / size) * size;
	return { start: start, end: start + size - 1 };
}

function poolRange(value) {
	var parts = String(value || '').split('-');
	var start = ipv4Number(parts[0]);
	var end = ipv4Number(parts[1]);
	return start == null || end == null || start > end ? null : { start: start, end: end };
}

function rangesOverlap(a, b) {
	return a && b && a.start <= b.end && a.end >= b.start;
}

function addressPlanPicker(current, networks) {
	var candidates = [
		{ pool: '10.20.30.10-10.20.30.100', gateway: '10.20.30.1/24', dns: '10.20.30.1' },
		{ pool: '10.30.40.10-10.30.40.100', gateway: '10.30.40.1/24', dns: '10.30.40.1' },
		{ pool: '10.66.0.10-10.66.0.100', gateway: '10.66.0.1/24', dns: '10.66.0.1' },
		{ pool: '172.27.0.10-172.27.0.100', gateway: '172.27.0.1/24', dns: '172.27.0.1' }
	];
	var connected = (networks || []).map(function(network) { return cidrRange(network.value); })
		.filter(Boolean);
	var currentKey = [ current.pool, current.gateway, current.dns ].join('|');
	var plans = candidates.filter(function(plan) {
		var key = [ plan.pool, plan.gateway, plan.dns ].join('|');
		return key === currentKey || !connected.some(function(network) {
			return rangesOverlap(poolRange(plan.pool), network);
		});
	}).map(function(plan) {
		plan.key = [ plan.pool, plan.gateway, plan.dns ].join('|');
		return plan;
	});
	var customKey = '__ikev2_custom_plan__';
	var pool = input('text', current.pool, { 'placeholder': '10.20.30.10-10.20.30.100' });
	var gateway = input('text', current.gateway, { 'placeholder': '10.20.30.1/24' });
	var dns = input('text', current.dns, { 'placeholder': '10.20.30.1' });
	var custom = E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
		common.fieldLabel(_('Client IPv4 pool')), pool,
		common.fieldLabel(_('Pool gateway'), _('Router address and prefix assigned to ipsec-in.')), gateway,
		common.fieldLabel(_('DNS for VPN clients')), dns
	]);
	var select = E('select', { 'class': 'cbi-input-select' }, plans.map(function(plan) {
		return E('option', { 'value': plan.key }, [
			plan.gateway.replace(/\.1\/24$/, '.0/24') + ' — ' + plan.pool
		]);
	}).concat([ E('option', { 'value': customKey }, [ _('Custom…') ]) ]));
	var node = E('div', { 'class': 'ikev2-choice-custom' }, [ select, custom ]);

	function sync() { custom.style.display = select.value === customKey ? '' : 'none'; }
	function setValue(next) {
		pool.value = next.pool || '';
		gateway.value = next.gateway || '';
		dns.value = next.dns || '';
		var key = [ pool.value, gateway.value, dns.value ].join('|');
		select.value = plans.some(function(plan) { return plan.key === key; }) ? key : customKey;
		sync();
	}
	select.addEventListener('change', function() {
		var plan = plans.find(function(item) { return item.key === select.value; });
		if (plan) {
			pool.value = plan.pool;
			gateway.value = plan.gateway;
			dns.value = plan.dns;
		}
		sync();
	});
	setValue(current);
	return {
		node: node,
		values: function() { return { pool: pool.value.trim(), gateway: gateway.value.trim(), dns: dns.value.trim() }; },
		setValue: setValue
	};
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'server-get' ]),
				fs.exec(helper, [ 'server-access-get' ]),
				fs.exec(helper, [ 'advanced-mode', 'inbound' ]),
				fs.exec(helper, [ 'advanced-read', 'inbound' ]),
				L.resolveDefault(fs.exec(helper, [ 'acme-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(devicesHelper, [ 'networks' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(devicesHelper, [ 'zones' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(systemHelper, [ 'get' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Inbound VPN Server'),
				_('Remote devices connect to the router over IKEv2. Routes advertised by strongSwan and firewall permissions are controlled independently.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var access = common.parseKeyValues(data[1].stdout);
		var acme = common.parseKeyValues((data[4] && data[4].stdout) || '');
		var networks = parseNamedValues((data[5] && data[5].stdout) || '');
		var zones = parseNamedValues((data[6] && data[6].stdout) || '');
		var system = common.parseKeyValues((data[7] && data[7].stdout) || '');
		var customMode = (data[2].stdout || '').trim() === '1';
		var enabled = input('checkbox', value.enabled);
		var identities = (acme.identities || '').trim().split(/\s+/).filter(Boolean);
		if (value.identity && identities.indexOf(value.identity) < 0) identities.unshift(value.identity);
		var identity = common.choiceWithCustom(value.identity, identities.map(function(name) {
			return { value: name, label: name };
		}), { placeholder: 'vpn.example.com' });
		var addressPlan = addressPlanPicker({
			pool: value.pool4, gateway: value.gateway4, dns: value.dns4
		}, networks);
		var routedNetworks = networks.filter(function(network) {
			return network.name !== system.wan_interface;
		}).map(function(network) { return network.value; }).join(' ');
		var trafficChoices = [ { value: '0.0.0.0/0', label: _('All IPv4 traffic (full tunnel)') } ];
		if (routedNetworks)
			trafficChoices.push({ value: routedNetworks, label: _('Internal router networks') + ' — ' + routedNetworks });
		var localTs = common.choiceWithCustom(access.local_ts, trafficChoices, {
			placeholder: '0.0.0.0/0'
		});
		var allowInternet = input('checkbox', access.allow_internet);
		var allowLan = input('checkbox', access.allow_lan);
		var allowRouter = input('checkbox', access.allow_router);
		var allowAllRouterPorts = input('checkbox', access.router_ports ? '0' : '1');
		var routerPorts = input('text', access.router_ports, {
			'placeholder': '80 443 1111 7681'
		});
		var internalZones = zones.filter(function(zone) {
			var zoneNetworks = zone.value.split(/\s+/).filter(Boolean);
			return zone.name !== access.firewall_zone && zone.name !== access.outbound_zone &&
				zoneNetworks.indexOf(system.wan_interface) < 0;
		});
		var lanZones = common.multiChoiceWithCustom(access.lan_zones,
			internalZones.map(function(zone) {
				return { value: zone.name, name: zone.name, meta: zone.value || '' };
			}), { placeholder: 'lan guest iot' });
		var firewallZone = common.choiceWithCustom(access.firewall_zone, [
			{ value: 'ikev2in', label: _('Automatic') + ' — ikev2in' }
		], { placeholder: 'ikev2in' });
		var outboundZone = common.choiceWithCustom(access.outbound_zone, [
			{ value: 'ikev2out', label: _('Automatic') + ' — ikev2out' }
		], { placeholder: 'ikev2out' });
		var certSource = common.choiceWithCustom(value.cert_source, [
			{ value: '/etc/ssl/acme', label: _('Automatic') + ' — /etc/ssl/acme' }
		], { placeholder: '/etc/ssl/acme' });
		var certFile = common.choiceWithCustom(value.cert_file, [
			{ value: '', label: _('Automatic from identity') }
		], { placeholder: '/etc/ssl/acme/vpn.example.com.fullchain.crt' });
		var keyFile = common.choiceWithCustom(value.key_file, [
			{ value: '', label: _('Automatic from identity') }
		], { placeholder: '/etc/ssl/acme/vpn.example.com.key' });
		var mtu = common.choiceWithCustom(value.mtu, [
			{ value: '1400', label: '1400 — ' + _('recommended') },
			{ value: '1360', label: '1360 — ' + _('constrained networks') },
			{ value: '1280', label: '1280 — ' + _('minimum') },
			{ value: '1500', label: '1500 — ' + _('no reduction') }
		], { type: 'number', attrs: { 'min': '1280', 'max': '1500' } });
		var dpd = common.choiceWithCustom(value.dpd, [
			{ value: '30', label: '30 ' + _('seconds') + ' — ' + _('recommended') },
			{ value: '60', label: '60 ' + _('seconds') },
			{ value: '120', label: '120 ' + _('seconds') }
		], { type: 'number', attrs: { 'min': '10', 'max': '300' } });
		var ikeRekey = common.choiceWithCustom(value.ike_rekey, [
			{ value: '14400', label: '4 ' + _('hours') + ' — ' + _('recommended') },
			{ value: '28800', label: '8 ' + _('hours') },
			{ value: '86400', label: '24 ' + _('hours') }
		], { type: 'number', attrs: { 'min': '3600', 'max': '86400' } });
		var childRekey = common.choiceWithCustom(value.child_rekey, [
			{ value: '3600', label: '1 ' + _('hour') + ' — ' + _('recommended') },
			{ value: '7200', label: '2 ' + _('hours') },
			{ value: '14400', label: '4 ' + _('hours') }
		], { type: 'number', attrs: { 'min': '900', 'max': '86400' } });
		var mobike = input('checkbox', value.mobike);
		var fragmentation = input('checkbox', value.fragmentation);
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save server')
		]);
		var serverResult = common.inlineResult();
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
		var rawResult = common.inlineResult();
		var rawModePill = common.pill('', 'neutral');
		var rawPanel = E('div', {
			'style': 'display:none;margin-top:1rem'
		}, [
			E('div', { 'class': 'ikev2-note warn' }, [
				_('Custom mode replaces the generated inbound connection and pool blocks. Normal form values remain stored but do not change the active strongSwan profile until generated mode is restored.')
			]),
			rawText,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:.7rem' }, [
				rawResult.node,
				rawReset,
				rawSave
			])
		]);

		function updateRouterAccessControls() {
			allowAllRouterPorts.disabled = !allowRouter.checked;
			routerPorts.disabled = !allowRouter.checked || allowAllRouterPorts.checked;
		}

		allowRouter.addEventListener('change', updateRouterAccessControls);
		allowAllRouterPorts.addEventListener('change', updateRouterAccessControls);

		rawToggle.addEventListener('click', function() {
			rawPanel.style.display = rawPanel.style.display === 'none' ? '' : 'none';
		});

		rawSave.addEventListener('click', function() {
			return writeProfileInput(rawText.value).then(function(token) {
				return common.runJob({
					button: rawSave,
					result: rawResult,
					busy: _('Validating and loading...'),
					success: _('Loaded'),
					failure: _('Custom configuration was rejected'),
					startPath: helper,
					startArgs: [ 'advanced-start', 'inbound', token ],
					statusPath: helper,
					statusArgs: [ 'action-status' ],
					timeout: 90000,
					timeoutMessage: _('The operation continues in the background. You can use the button again.'),
					onSuccess: function(st) {
						if (st && st.state !== 'timeout') {
							customMode = true;
							updateServerPills();
							rawTracker.reset();
						}
					}
				});
			}).catch(function(error) {
				rawResult.err(error.message || error);
			});
		});

		rawReset.addEventListener('click', function() {
			return common.runJob({
				button: rawReset,
				result: rawResult,
				busy: _('Restoring generator...'),
				success: _('Restored'),
				failure: _('Reset failed'),
				startPath: helper,
				startArgs: [ 'advanced-reset-start', 'inbound' ],
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 90000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout') {
						customMode = false;
						return refreshServerState().then(function() { rawTracker.reset(); });
					}
				}
			});
		});

			save.addEventListener('click', function() {
				if (allowRouter.checked && !allowAllRouterPorts.checked &&
				    !routerPorts.value.trim()) {
					serverResult.err(_('Enter at least one allowed router port or enable all router ports.'));
					return;
				}
				var planValues = addressPlan.values();
				var serverValues = [
					enabled.checked ? '1' : '0',
				identity.value(),
				planValues.pool,
				planValues.gateway,
				planValues.dns,
				certSource.value(),
				certFile.value(),
				keyFile.value(),
				dpd.value(),
				ikeRekey.value(),
				childRekey.value(),
				mtu.value(),
					mobike.checked ? '1' : '0',
					fragmentation.checked ? '1' : '0',
					localTs.value(),
				allowInternet.checked ? '1' : '0',
				allowLan.checked ? '1' : '0',
				allowRouter.checked ? '1' : '0',
				allowAllRouterPorts.checked ? '' : routerPorts.value.trim(),
				lanZones.value(),
					firewallZone.value(),
					outboundZone.value()
				];
			return common.runAction({
				button: save,
				result: serverResult,
				busy: _('Saving...'),
				failure: _('Server settings rejected'),
					run: function() {
						var token = common.inputToken();
						return fs.write('/var/run/ikev2-manager-server-' + token + '.in',
							serverValues.join('\n') + '\n', 384 /* 0600 */)
							.then(function() {
								return common.execChecked(helper, [ 'server-input', token ],
									_('Server settings rejected'));
							})
							.then(function(response) {
							var started = common.parseKeyValues(response.stdout || '');
							if (!started.action_id) {
								serverResult.ok(_('Saved'));
								return;
							}
							return common.pollAction(helper,
								[ 'action-status', started.action_id ], started.action_id, {
								timeout: 120000,
								interval: 1500,
								onProgress: function(st) {
									if (st.action_id === started.action_id)
										common.showProgress(serverResult, st.message, _('Saving...'));
								}
							}).then(function(st) {
								if (!st) {
									serverResult.warn(_('The operation continues in the background. You can use the button again.'));
								}
								else if (st.state === 'error') {
									throw new Error(st.message ? _(st.message) : _('Apply failed'));
								}
								else {
									serverResult.ok(_('Saved'));
								}
							});
						});
				},
				// Either way the form is reloaded from the router, which is what the
				// Save button then compares against.
				onSuccess: function() {
					return refreshServerState().then(function() { serverTracker.reset(); });
				},
				onError: function() {
					return refreshServerState().then(function() { serverTracker.reset(); });
				}
			});
		});

			// ACME certificate
		var acmeEmail = input('text', acme.email, { 'placeholder': 'you@example.com' });
		var acmeMethod = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'dns', 'selected': acme.method !== 'http' ? '' : null },
				[ _('DNS-01 (DNS provider API)') ]),
				E('option', { 'value': 'http', 'selected': acme.method === 'http' ? '' : null },
					[ _('HTTP-01 (webroot, needs inbound port 80)') ])
		]);
		var providerList = (acme.providers || '').trim().split(/\s+/).filter(Boolean);
		if (!providerList.length)
			providerList = [ 'dns_timeweb' ];
		var acmeProvider = E('select', { 'class': 'cbi-input-select' },
			providerList.map(function(p) {
				return E('option', {
					'value': p,
					'selected': p === acme.dns_provider ? '' :
						(!acme.dns_provider && p === 'dns_timeweb' ? '' : null)
				}, [ p ]);
			}));
		var acmeCreds = E('textarea', {
			'class': 'ikev2-domain-editor',
			'style': 'min-height:4rem',
			'placeholder': acme.has_credentials === '1' ?
				_('Stored — leave empty to keep, or paste to replace') :
				_('Paste your API token here')
		}, []);
		var acmeStaging = input('checkbox', acme.staging);
		var acmeSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save ACME settings') ]);
		var acmeRequest = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Request certificate') ]);
		var acmeResult = common.inlineResult();

		var dnsRows = E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
			common.fieldLabel(_('DNS provider'),
				_('acme.sh dns_* plugin. Timeweb needs TW_Token.')),
			acmeProvider,
			common.fieldLabel(_('Provider credentials'),
				_('For Timeweb just paste the API token. Multi-field providers: one VAR="value" per line.')),
			acmeCreds
		]);
		function syncAcmeMethod() {
			dnsRows.style.display = acmeMethod.value === 'dns' ? '' : 'none';
		}
		acmeMethod.addEventListener('change', syncAcmeMethod);
		syncAcmeMethod();

		// Hand the settings to the backend through a file, not a command
		// argument. The token is large and secret; passing it on the exec
		// command line is brittle (rpcd's file-exec ACL globs the arguments and
		// arbitrary base64 broke the match) and leaks it into the process list.
			// A one-shot token prevents concurrent LuCI sessions from sharing an
			// input file; only the non-secret token is passed on the command line.
			function writeAcmeInput() {
				var token = common.inputToken();
				var payload = [
				acmeEmail.value.trim(),
				acmeMethod.value,
				acmeProvider.value,
				acmeStaging.checked ? '1' : '0'
			].join('\n') + '\n' + acmeCreds.value + '\n';
				return fs.write('/tmp/ikev2-acme-' + token + '.in', payload, 384 /* 0600 */)
					.then(function() { return token; });
			}

			acmeSave.addEventListener('click', function() {
				return common.runAction({
				button: acmeSave,
				result: acmeResult,
				busy: _('Saving...'),
				success: _('ACME settings saved.'),
				failure: _('ACME settings rejected'),
					run: function() {
						return writeAcmeInput().then(function(token) {
							return common.execChecked(helper, [ 'acme-set', token ], _('ACME settings rejected'));
						});
					},
					onSuccess: function() {
						return refreshServerState().then(function() { acmeTracker.reset(); });
					}
				});
			});

		acmeRequest.addEventListener('click', function() {
			return common.runAction({
				button: acmeRequest,
				result: acmeResult,
				busy: _('Requesting...'),
				failure: _('Certificate request failed.'),
				run: function() {
					acmeResult.busy(_('Saving settings...'));
						return writeAcmeInput().then(function(token) {
							return common.execChecked(helper, [ 'acme-set', token ], _('ACME settings rejected'));
						}).then(function() {
						return common.execChecked(helper, [ 'acme-issue' ], _('Certificate request failed.'));
					}).then(function(response) {
						var started = common.parseKeyValues(response.stdout || '');
						if (!started.action_id)
							throw new Error(_('Certificate request did not start.'));
							return common.pollAction(helper,
								[ 'action-status', started.action_id ], started.action_id, {
							timeout: 300000,
							interval: 2500,
							onProgress: function(st) {
								common.showProgress(acmeResult, st.message, _('Requesting...'));
							}
						});
					}).then(function(st) {
						if (!st) {
							acmeResult.warn(
								_('The certificate request continues in the background. You can use the button again.'));
						}
						else if (st.state === 'error') {
							throw new Error(st.message ? _(st.message) : _('Certificate request failed.'));
						}
						else {
							acmeResult.ok(st.message ? _(st.message) : _('Certificate issued.'));
							// The request saved the ACME settings first.
							acmeTracker.reset();
							return refreshServerState();
						}
					});
				}
			});
		});

		var acmeStatusPill = acme.cert_present === '1' ?
			common.pill(_('Certificate present') +
				(acme.cert_expiry ? ' · ' + common.formatDate(acme.cert_expiry) : ''), 'good') :
			common.pill(_('No certificate'), 'bad');
		var certSubjectPill = common.pill('', 'neutral');

		// Reflect runtime reality, not just the UCI flag: an enabled server with no
		// usable certificate is not actually serving, so warn instead of "Enabled".
		var serverStatusPill = common.pill('', 'neutral');

		function updateServerPills() {
			common.setPill(rawModePill,
				customMode ? _('Override active') : _('Generated'),
				customMode ? 'warn' : 'good');
			if (acme.cert_subject) {
				common.setPill(certSubjectPill, acme.cert_subject, 'neutral');
				certSubjectPill.style.display = '';
			}
			else {
				certSubjectPill.style.display = 'none';
			}
			if (acme.cert_present === '1') {
				common.setPill(acmeStatusPill,
					_('Certificate present') +
						(acme.cert_expiry ? ' · ' + common.formatDate(acme.cert_expiry) : ''),
					'good');
			}
			else {
				common.setPill(acmeStatusPill, _('No certificate'), 'bad');
			}

			if (customMode) {
				common.setPill(serverStatusPill, _('Custom config'), 'warn');
			}
			else if (value.enabled !== '1') {
				common.setPill(serverStatusPill, _('Disabled'), 'neutral');
			}
			else if (acme.cert_present !== '1') {
				common.setPill(serverStatusPill, _('Enabled — no certificate'), 'warn');
			}
			else if (acme.conn_loaded === '1') {
				common.setPill(serverStatusPill, _('Enabled'), 'good');
			}
			else {
				common.setPill(serverStatusPill, _('Enabled — not loaded'), 'warn');
			}
		}

			function refreshServerState() {
				return Promise.all([
					L.resolveDefault(fs.exec(helper, [ 'server-get' ]), { stdout: '' }),
					L.resolveDefault(fs.exec(helper, [ 'server-access-get' ]), { stdout: '' }),
					L.resolveDefault(fs.exec(helper, [ 'acme-get' ]), { stdout: '' }),
					L.resolveDefault(fs.exec(helper, [ 'advanced-mode', 'inbound' ]), { stdout: '0' })
				]).then(function(results) {
					value = common.parseKeyValues(results[0].stdout || '');
					access = common.parseKeyValues(results[1].stdout || '');
					acme = common.parseKeyValues(results[2].stdout || '');
					customMode = (results[3].stdout || '').trim() === '1';
					enabled.checked = value.enabled === '1';
					identity.setValue(value.identity || '');
					addressPlan.setValue({
						pool: value.pool4 || '', gateway: value.gateway4 || '', dns: value.dns4 || ''
					});
					certSource.setValue(value.cert_source || '');
					certFile.setValue(value.cert_file || '');
					keyFile.setValue(value.key_file || '');
					dpd.setValue(value.dpd || '');
					ikeRekey.setValue(value.ike_rekey || '');
					childRekey.setValue(value.child_rekey || '');
					mtu.setValue(value.mtu || '');
					mobike.checked = value.mobike === '1';
					fragmentation.checked = value.fragmentation === '1';
					localTs.setValue(access.local_ts || '');
					allowInternet.checked = access.allow_internet === '1';
					allowLan.checked = access.allow_lan === '1';
					allowRouter.checked = access.allow_router === '1';
					routerPorts.value = access.router_ports || '';
					allowAllRouterPorts.checked = !access.router_ports;
					lanZones.setValue(access.lan_zones || '');
					firewallZone.setValue(access.firewall_zone || '');
					outboundZone.setValue(access.outbound_zone || '');
					updateRouterAccessControls();
					updateServerPills();
				});
		}
		updateServerPills();
		updateRouterAccessControls();

		var accessAdvanced = common.advancedPanel(
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Firewall zone integration') ]),
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Inbound VPN zone')), firewallZone.node,
					common.fieldLabel(_('Outbound IKEv2 zone')), outboundZone.node
				])
			]), _('Advanced access settings'));

		var behaviorAdvanced = common.advancedPanel(E('div', {}, [
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Advanced timers') ]),
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('DPD interval')), dpd.node,
					common.fieldLabel(_('IKE rekey')), ikeRekey.node,
					common.fieldLabel(_('CHILD rekey')), childRekey.node
				])
			]),
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Certificate paths') ]),
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('ACME certificate directory')), certSource.node,
					common.fieldLabel(_('Certificate file override')), certFile.node,
					common.fieldLabel(_('Private key override')), keyFile.node
				])
			]),
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Advanced strongSwan configuration') ]),
				E('p', { 'class': 'ikev2-panel-note' }, [
					_('Inspect the generated swanctl connection or replace it with a manually maintained profile.')
				]),
				rawPanel,
				E('div', { 'class': 'ikev2-actions spread', 'style': 'margin-top:1rem' }, [
					rawModePill,
					rawToggle
				])
			])
		]), _('Advanced connection settings'));

		var accessPanel = common.section(
			_('Client routes and access'),
			_('Global defaults for inbound clients. Individual overrides are configured on the VPN Users page.'),
			E('div', {}, [
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Advertised IPv4 destinations'),
						_('Space-separated CIDRs. Use 0.0.0.0/0 for a full-tunnel client route.')),
					localTs.node,
					common.fieldLabel(_('Allow Internet'),
						_('Permit forwarding to home WAN and the outbound IKEv2 policy path.')),
					common.switchLabel(allowInternet),
					common.fieldLabel(_('Allow internal networks'),
						_('Permit forwarding to the LAN firewall zones listed below.')),
					common.switchLabel(allowLan),
					common.fieldLabel(_('Internal firewall zones')),
					lanZones.node,
					common.fieldLabel(_('Allow router itself'),
						_('Allows router services on its LAN, VPN and public addresses. This also enables same-router public-IP loopback.')),
					common.switchLabel(allowRouter),
					common.fieldLabel(_('Allow all router ports'),
						_('Permit every router service from authenticated inbound VPN clients. The restricted port list is disabled while this is on.')),
					common.switchLabel(allowAllRouterPorts),
					common.fieldLabel(_('Allowed router ports'),
						_('Complete TCP/UDP allowlist used when all ports are off. Keep LuCI and SSH ports in this list or inbound VPN management access will stop.')),
					routerPorts
				]),
				accessAdvanced.panel
			]),
			accessAdvanced.toggle
		);

		// Staging issues untrusted certificates, so it belongs with the other
		// options that qualify the request rather than in the row of fields the
		// request is actually made from.
		var acmeAdvanced = common.advancedPanel(
			E('div', { 'class': 'ikev2-advanced-group' }, [
				E('h4', {}, [ _('Testing') ]),
				common.toggleRow(acmeStaging, _('Use the staging CA'),
					_('Issues untrusted certificates against the Let\'s Encrypt staging service, which has no rate limits. Clients reject the result; turn it off before issuing the certificate they will use.'))
			]), _('Advanced certificate settings'));

		var acmePanel = common.section(
			_('ACME certificate'),
			_('Issue and renew the public certificate used by VPN clients.'),
			E('div', {}, [
				E('p', { 'class': 'ikev2-panel-note' }, [
					_('The public identity above must be a DNS name pointing to this router.')
				]),
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Account email'),
						_('Used for the Let\'s Encrypt account and expiry notices.')),
					acmeEmail,
					common.fieldLabel(_('Challenge method'),
						_('DNS-01 works behind NAT and without port 80. HTTP-01 needs inbound TCP 80 to this router.')),
					acmeMethod
				]),
				dnsRows,
				acmeAdvanced.panel,
				E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
					acmeResult.node,
					acmeSave,
					acmeRequest
				])
			]),
			E('div', { 'class': 'ikev2-actions' }, [
				acmeStatusPill,
				certSubjectPill,
				acmeAdvanced.toggle
			])
		);

		var behaviorPanel = common.section(
			_('Connection behavior'),
			_('How an established session survives a client changing network. Timers, certificate paths and the raw strongSwan profile are in the advanced options.'),
			E('div', {}, [
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('MOBIKE'),
						_('Keeps the VPN session when a phone moves between Wi-Fi and mobile data.')),
					common.switchLabel(mobike),
					common.fieldLabel(_('IKE fragmentation'),
						_('Avoids oversized IKE packets on constrained networks.')),
					common.switchLabel(fragmentation),
					common.fieldLabel(_('XFRM MTU')), mtu.node
				]),
				behaviorAdvanced.panel
			]),
			behaviorAdvanced.toggle
		);

		// Each save button is grey until something it sends has changed. The
		// server controls are listed rather than taken from their sections,
		// which also hold the raw profile and ACME fields with buttons of their own.
		var serverTracker = common.trackChanges(save, [
			enabled, identity.node, addressPlan.node, certSource.node, certFile.node,
			keyFile.node, dpd.node, ikeRekey.node, childRekey.node, mtu.node, mobike,
			fragmentation, localTs.node, allowInternet, allowLan, allowRouter,
			allowAllRouterPorts, routerPorts, lanZones.node, firewallZone.node,
			outboundZone.node
		]);
		var acmeTracker = common.trackChanges(acmeSave,
			[ acmeEmail, acmeMethod, dnsRows, acmeStaging ]);
		var rawTracker = common.trackChanges(rawSave, [ rawText ]);

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Inbound VPN Server'),
					_('Remote devices connect to the router over IKEv2. Routes advertised by strongSwan and firewall permissions are controlled independently.')),
				common.section(_('Service'),
					_('Server identity and the address pool handed to inbound clients.'),
					E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
						common.fieldLabel(_('Enable server'),
							_('Listen on WAN UDP 500 and 4500.')),
						common.switchLabel(enabled),
						common.fieldLabel(_('Public identity'),
							_('Choose a detected ACME name or enter another DNS name.')),
						identity.node,
						common.fieldLabel(_('VPN address plan'),
							_('Presets that overlap a connected router network are hidden.')),
						addressPlan.node
					]),
					serverStatusPill),
				accessPanel,
				acmePanel,
				behaviorPanel,
				E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
					serverResult.node,
					save
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
