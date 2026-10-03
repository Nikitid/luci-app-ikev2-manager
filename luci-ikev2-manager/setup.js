'use strict';
'require view';
'require fs';
'require ikev2-manager.shared-v13 as common';

var helper = '/usr/libexec/ikev2-manager-system';
var devicesHelper = '/usr/libexec/ikev2-devices';
var managerHelper = '/usr/libexec/ikev2-manager';
var depsStatusFile = '/tmp/ikev2-manager-deps.status';

function parseStatus(text) {
	var out = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var eq = line.indexOf('=');
		if (eq > 0) out[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return out;
}

function dependenciesReady(doctor) {
	return doctor && doctor.dependencies_ok === '1';
}

function dependenciesKnown(doctor) {
	return doctor && (doctor.dependencies_ok === '1' || doctor.dependencies_ok === '0');
}

// install-deps detaches and reports through depsStatusFile; poll until the
// run after `prev` finishes (state ok/error) or the deadline passes.
function pollDeps(actionId, deadline, result) {
	return L.resolveDefault(fs.read(depsStatusFile), '').then(function(txt) {
		var st = parseStatus(txt);
		if (st.action_id === actionId && st.state === 'running')
			common.showProgress(result, st.message, _('Working...'));
		if ((st.state === 'ok' || st.state === 'error') && st.action_id === actionId)
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(r) { window.setTimeout(r, 2000); }).then(function() {
			return pollDeps(actionId, deadline, result);
		});
	});
}

function runDepsJob(button, cmd, result, doneMsg, refresh, done) {
	return common.runAction({
		button: button,
		result: result,
		busy: _('Working...'),
		done: done,
		run: function() {
			return common.execChecked(helper, [ cmd ], _('Operation failed')).then(function(response) {
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId)
					throw new Error(_('Action did not start'));
				return pollDeps(actionId, Date.now() + 300000, result);
			}).then(function(st) {
				if (!st) {
					result.warn(_('The operation continues in the background. You can use the button again.'));
				}
				else if (st.state === 'error') {
					throw new Error(st.message ? _(st.message) : _('Operation failed'));
				}
				else {
					result.ok(doneMsg);
					return refresh();
				}
			});
		}
	});
}

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

// "name=192.168.2.0/24" lines from `ikev2-devices networks`
function parseNetworks(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var eq = line.indexOf('=');
		return eq > 0 ? { name: line.slice(0, eq), cidr: line.slice(eq + 1) } : null;
	}).filter(Boolean);
}

function parseDeviceDump(stdout) {
	var entries = [];
	(stdout || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		line = line.trim();
		if (!line) return;
		var entry = {};
		line.split(' ').forEach(function(part) {
			var eq = part.indexOf('=');
			if (eq > 0) entry[part.slice(0, eq)] = part.slice(eq + 1);
		});
		if (entry.addr && entry.mode) entries.push(entry);
	});
	return entries;
}

// The tunnels the router has, the main one first, from tunnels-get.
function parseTunnelChoices(stdout) {
	var choices = [ { index: '1', name: _('Main tunnel') } ], current = null;
	String(stdout || '').split('\n').forEach(function(line) {
		var at = line.indexOf('=');
		if (at < 1)
			return;
		var key = line.slice(0, at), value = line.slice(at + 1);
		if (key === 'tunnel') {
			current = { index: value, name: _('Tunnel %s').format(value) };
			choices.push(current);
		}
		else if (current && key === 'name' && value)
			current.name = value;
	});
	return choices;
}

function parseClients(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('\t');
		if (!fields[0]) return null;
		return { addr: fields[0], name: fields[1] || '', mac: fields[2] || '' };
	}).filter(Boolean);
}

function parseDeviceStats(stdout) {
	var stats = {};
	(stdout || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var item = {};
		line.split(' ').forEach(function(field) {
			var eq = field.indexOf('=');
			if (eq > 0) item[field.slice(0, eq)] = field.slice(eq + 1);
		});
		if (item.addr && item.kind)
			stats[item.kind + ':' + item.addr] = item;
	});
	return stats;
}

function validateAddr(addr) {
	return addr.length > 0 && addr.length < 50 &&
		/^[0-9.]+(\/[0-9]{1,2})?$/.test(addr);
}

function domainRuntimeStatus(value) {
	// A pause refuses what reaches the tunnel on purpose; it is not a fault.
	if (value.routing_paused === '1') {
		return {
			label: _('Paused'), tone: 'warn',
			detail: _('Tunnel routing is paused: selected domains get no connection until you resume, and none of them goes through WAN.')
		};
	}
	if (value.domain_engine !== 'fakeip') {
		return {
			label: _('Matching by address'),
			tone: 'neutral',
			detail: _('Selected services are recognised by their resolved public IP addresses. Change it on the Policy Routing page.')
		};
	}
	if (value.domain_healthy === 'yes' && value.domain_data_plane === 'degraded') {
		return {
			label: _('Reliable mode needs attention'), tone: 'warn',
			detail: _('The tunnel carries traffic but the FakeIP resolver does not. It is restarted automatically.')
		};
	}
	if (value.domain_healthy === 'yes') {
		return {
			label: _('Reliable mode active'), tone: 'good',
			detail: _('sing-box FakeIP and nftables TProxy classify selected services. Configure the engine on the Policy Routing page.')
		};
	}
	var detail;
	if (value.domain_state === 'running')
		detail = _('Reliable domain routing is still updating.');
	else if (value.domain_service !== 'running')
		detail = _('The reliable domain-router service is stopped.');
	else if (value.domain_dnsmasq_resolver === 'mismatch')
		detail = _('dnsmasq does not resolve the way reliable mode set it up.');
	else if (value.domain_nft !== 'active')
		detail = _('Reliable-mode nftables rules are missing.');
	else if (value.domain_rule !== 'active')
		detail = _('Reliable-mode policy routing rule is missing.');
	else
		detail = value.domain_message ? _(value.domain_message) :
			_('Reliable domain routing failed a runtime health check.');
	return { label: _('Reliable mode degraded'), tone: 'bad', detail: detail };
}

// TUNNEL_NAMES maps a tunnel index to the name it is shown by.
function checkRows(doctor, tunnelNames) {
	var labels = {
		diagnostic_status: _('Readiness check'),
		firmware_source: _('Firmware source'),
		openwrt: _('OpenWrt release'),
		board_model: _('Router model'),
		target: _('OpenWrt target'),
		architecture: _('Architecture'),
		kernel: _('Kernel'),
		package_manager: _('Package manager'),
		package_feeds: _('Package feeds'),
		storage_free: _('Persistent storage free'),
		tmp_free: _('Temporary storage free'),
		memory_available: _('Available memory'),
		system_clock: _('System clock'),
		crypto_acceleration: _('Crypto acceleration'),
		flow_offloading: _('Flow offloading'),
		resource_conflict: _('Reserved resource conflicts'),
		upnp_ikev2_ports: _('UPnP reservation for IKEv2'),
		firewall4: _('firewall4'),
		firewall4_config: _('Firewall configuration'),
		dnsmasq_nftset: _('dnsmasq nftset support'),
		dnsproxy: _('Encrypted DNS proxy'),
		dns_segments: _('Destination DNS segments'),
		curl: _('HTTP client'),
		sing_box: _('sing-box domain router'),
		sing_box_fakeip: _('FakeIP allocator'),
		fakeip_data_plane: _('FakeIP data plane'),
		tunnel_vip_placement: _('Tunnel address placement'),
		nft_tproxy: _('nftables TProxy support'),
		pbr_policies: _('Policies left in PBR'),
		policy_routing_runtime: _('Policy routing runtime'),
		routing_pause: _('Tunnel pause'),
		failclosed_route: _('Fail-closed route'),
		failclosed_ipv6_route: _('IPv6 fail-closed route'),
		xfrm_module: _('XFRM interface module'),
		xfrm_ifid_conflict: _('XFRM if_id conflict'),
		xfrm_name_conflict: _('XFRM name conflict'),
		swanctl: _('strongSwan swanctl'),
		swanmon: _('strongSwan monitoring'),
		strongswan_kernel_netlink: _('strongSwan kernel-netlink'),
		strongswan_vici: _('strongSwan VICI'),
		strongswan_openssl: _('strongSwan OpenSSL'),
		strongswan_eap_mschapv2: _('strongSwan EAP-MSCHAPv2'),
		strongswan_eap_client_security: _('Outbound EAP security'),
		strongswan_eap_server_security: _('Inbound strongSwan version'),
		strongswan_running: _('Running strongSwan'),
		strongswan_cohort: _('strongSwan package cohort'),
		strongswan_x509: _('strongSwan X.509'),
		device_policy_runtime: _('Device policy runtime'),
		tunnels: _('Tunnels')
	};
	var rows = [];
	Object.keys(labels).forEach(function(key) {
		if (doctor[key] == null)
			return;
		var value = doctor[key];
		var good = value === 'ok' || value === 'none' || value.indexOf('ok:') === 0;
		var warn = value.indexOf('warn:') === 0;
		var notice = value.indexOf('notice:') === 0;
		var shown = value.replace(/^(ok|warn|notice|invalid):/, '');
		if ((key === 'storage_free' || key === 'tmp_free' || key === 'memory_available') &&
		    /^\d+KiB$/.test(shown)) {
			shown = common.formatBytes(Number(shown.slice(0, -3)) * 1024);
		}
		else if (key === 'strongswan_eap_server_security' && warn) {
			var cve = /^(.+)-cve-(\d{4}-\d+)-(awaiting-feed|update-available)$/.exec(shown);
			if (cve)
				shown = cve[3] === 'update-available' ?
					_('%s: vulnerable (CVE-%s); a fixed package is available, update strongSwan').format(cve[1], cve[2]) :
					_('%s: vulnerable (CVE-%s); waiting for a fixed package in the feed').format(cve[1], cve[2]);
		}
		else if (key === 'strongswan_running') {
			var pending = /^(.+)-restart-pending-(.+)$/.exec(shown);
			if (pending)
				shown = _('%s runs; the installed %s takes effect when charon restarts').format(pending[1], pending[2]);
			else if (shown === 'not-answering')
				shown = _('charon did not answer');
		}
		else if (key === 'tunnels' && warn) {
			shown = shown.split(',').map(function(item) {
				var problem = /^(exit-)?([1-7])(s)?-(.+)$/.exec(item);
				if (!problem)
					return item;
				var name = (tunnelNames || {})[problem[2]] || _('Tunnel %s').format(problem[2]);
				if (problem[1] && problem[3])
					return _('%s is off: what is bound to it without backup is refused').format(name);
				if (problem[1])
					return _('%s: its traffic has no tunnel left and is refused').format(name);
				if (problem[4] === 'no-password')
					return _('%s: no password').format(name);
				if (problem[4] === 'no-link')
					return _('%s: no interface').format(name);
				if (problem[4] === 'down')
					return _('%s: down').format(name);
				return item;
			}).join('; ');
		}
		else if (key === 'system_clock') {
			var clock = new Date(shown);
			if (!isNaN(clock.getTime()))
				shown = clock.toLocaleString();
		}
		rows.push({
			key: key,
			label: labels[key],
			value: common.pill(_(shown), good ? 'good' : (notice ? 'info' : (warn ? 'warn' : 'bad'))),
			tone: good ? 'good' : (notice ? 'info' : (warn ? 'warn' : 'bad'))
		});
	});
	return rows;
}

function rowPairs(rows) {
	return rows.map(function(row) { return [ row.label, row.value ]; });
}

function dependencyOverview(rows, detailsOpen) {
	var useful = {
		diagnostic_status: true,
		openwrt: true,
		storage_free: true,
		memory_available: true,
		resource_conflict: true,
		upnp_ikev2_ports: true,
		firewall4_config: true,
		dnsproxy: true,
		dns_segments: true,
		sing_box: true,
		sing_box_fakeip: true,
		fakeip_data_plane: true,
		tunnel_vip_placement: true,
		pbr_policies: true,
		policy_routing_runtime: true,
		routing_pause: true,
		failclosed_route: true,
		xfrm_module: true,
		strongswan_eap_client_security: true,
		strongswan_eap_server_security: true,
		strongswan_running: true,
		device_policy_runtime: true,
		tunnels: true
	};
	var issues = rows.filter(function(row) {
		return row.tone === 'bad' || row.tone === 'warn';
	});
	var details = rows.filter(function(row) { return useful[row.key]; });
	var half = Math.ceil(details.length / 2);
	return E('div', {}, [
		issues.length ? E('div', { 'class': 'ikev2-dependency-issues' },
			issues.map(function(row) {
				// A copy: the same node also goes into the technical details, and
				// a node inserted twice leaves this row empty.
				return E('div', { 'class': 'ikev2-health-row' }, [
					E('strong', {}, [ row.label ]),
					row.value.cloneNode(true)
				]);
			})) : '',
		E('details', { 'class': 'ikev2-diagnostics', 'open': detailsOpen ? '' : null }, [
			E('summary', {}, [ _('Technical details') ]),
			E('div', { 'class': 'ikev2-diagnostics-body' }, [
				E('div', { 'class': 'ikev2-two-col' }, [
					common.keyValueTable(rowPairs(details.slice(0, half))),
					common.keyValueTable(rowPairs(details.slice(half)))
				])
			])
		])
	]);
}

// One line of the outbound tunnel's last hour, with the page that explains it.
// Nothing here is polled: the overview is read once, and the tunnel page keeps
// the live view.
function qualityRow(summary) {
	var verdicts = {
		good: [ _('Good'), 'good' ],
		fair: [ _('Unstable'), 'warn' ],
		poor: [ _('Poor'), 'bad' ],
		down: [ _('No connection'), 'bad' ],
		off: [ _('Client disabled'), 'neutral' ],
		unknown: [ _('Collecting data'), 'neutral' ]
	};
	var verdict = verdicts[summary.quality] || verdicts.unknown;
	var parts = [];
	function number(value) {
		var n = parseFloat(value);
		return isFinite(n) ? n : null;
	}
	var rtt = number(summary.rtt_p50);
	var loss = number(summary.loss);
	var availability = number(summary.availability);
	if (rtt != null)
		parts.push(_('%s ms').format(Math.round(rtt)));
	if (loss != null)
		parts.push(_('loss %s%%').format(loss));
	if (availability != null)
		parts.push(_('availability %s%%').format(availability));
	var detail = parts.length ? _('Last hour: %s').format(parts.join(' · ')) :
		_('No measurements yet.');
	return E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:1rem' }, [
		E('span', { 'class': 'ikev2-health-copy' }, [
			E('strong', {}, [ _('Tunnel quality') ]),
			E('span', { 'class': 'ikev2-toggle-sub' }, [
				detail, ' ',
				E('a', { 'href': L.url('admin', 'services', 'ikev2-manager', 'client') }, [ _('Details') ])
			])
		]),
		common.pill(verdict[0], verdict[1])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'get' ]), { stdout: '' }),
			// A failed RPC is not evidence that packages are missing. Preserve an
			// explicit unknown state so the page cannot offer a destructive repair
			// for a transient diagnostic failure.
			L.resolveDefault(fs.exec(helper, [ 'doctor-ui' ]), {
				stdout: 'diagnostic_status=unavailable\ndependencies_ok=unknown\n'
			}),
			L.resolveDefault(fs.exec(devicesHelper, [ 'networks' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'dump' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'clients' ]), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/libexec/ikev2-device-routing', [ 'stats' ]), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/libexec/ikev2-tunnel-quality', [ 'summary', '1h' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(managerHelper, [ 'tunnels-get' ]), { stdout: '' })
		]);
	},

	// Persist a device change, then refresh every device panel from one snapshot
	// without forcing a page reload or losing the user's scroll position.
	deviceAction: function(args, busyBtn, result, onSaved) {
		var self = this;
		return common.runJob({
			button: busyBtn,
			result: result,
			busy: _('Saving...'),
			success: _('Saved'),
			failure: _('Operation failed'),
			startPath: helper,
			startArgs: [ 'device-async' ].concat(args),
			statusPath: helper,
			statusArgs: [ 'action-status' ],
			timeout: 150000,
			timeoutMessage: _('The operation continues in the background. You can use the button again.'),
			onSuccess: function(st) {
				if (st && st.state !== 'timeout') {
					return common.execChecked(devicesHelper, [ 'dump' ],
						_('Could not refresh device rules')).then(function(response) {
					(self.deviceRefreshers || []).forEach(function(refresh) {
						refresh(response.stdout || '');
					});
						if (onSaved)
							onSaved(response.stdout || '');
					});
				}
			}
		});
	},

	// Keep routing and independent PBR, DNS and DPI opt-outs in one compact row.
	// With more than one tunnel, a full-route device also names its tunnel.
	renderDevicePolicies: function(dumpStdout, clientsStdout, statsStdout, tunnelsStdout) {
		var self = this;
		var tunnels = parseTunnelChoices(tunnelsStdout);
		var several = tunnels.length > 1;
		var clients = parseClients(clientsStdout);
		var clientsByAddr = {};
		clients.forEach(function(client) { clientsByAddr[client.addr] = client; });
		var stats = parseDeviceStats(statsStdout);
		var list = E('div', { 'class': 'ikev2-device-policy-scroll' }, []);
		var result = common.inlineResult();
		var lastDump = dumpStdout;

		function policyCheck(entry, field, title, checks) {
			var checked = field === 'pbr' ? entry.mode === 'exclude' : entry[field] === '1';
			var control = E('input', {
				'type': 'checkbox',
				'checked': checked ? '' : null,
				'aria-label': title
			});
			var node = E('label', {
				'class': 'ikev2-policy-check',
				'title': title
			}, [ control, E('span', {}) ]);
			checks[field] = control;
			control.addEventListener('change', function() {
				// lockLastCheck keeps this from happening; a stale row is put back.
				if (!checks.pbr.checked && !checks.dns.checked && !checks.dpi.checked) {
					control.checked = true;
					return;
				}
				var values = [ 'set-exclusions', entry.addr,
					checks.pbr.checked ? '1' : '0',
					checks.dns.checked ? '1' : '0',
					checks.dpi.checked ? '1' : '0' ];
				Object.keys(checks).forEach(function(key) { checks[key].disabled = true; });
				self.deviceAction(values, null, result).then(function(status) {
					if (!status)
						refreshList(lastDump);
				});
			});
			return node;
		}

		// A full-route device sends everything into the tunnel. Ticked, what is
		// never to go through the tunnel goes to WAN for it too.
		function respectCheck(entry) {
			var title = _('Send destinations that never go through the tunnel to WAN for this device too');
			var control = E('input', {
				'type': 'checkbox',
				'checked': entry.respect === '1' ? '' : null,
				'aria-label': title
			});
			control.addEventListener('change', function() {
				control.disabled = true;
				self.deviceAction([ 'set-included', entry.addr, control.checked ? '1' : '0' ], null, result)
					.then(function(status) {
						if (!status)
							refreshList(lastDump);
					});
			});
			return E('label', { 'class': 'ikev2-policy-check', 'title': title }, [ control, E('span', {}) ]);
		}

		// The tunnel a full-route device leaves by. While it is down the
		// device moves to the next tunnel up, or, bound to it without backup,
		// waits for it; never to WAN.
		function tunnelSelect(entry) {
			var current = entry.exit || '1';
			var places = [];
			tunnels.forEach(function(choice) {
				places.push({ value: choice.index, label: choice.name });
				places.push({ value: choice.index + 's', label: _('%s, no backup').format(choice.name) });
			});
			var select = E('select', {
				'class': 'cbi-input-select',
				'aria-label': _('Tunnel')
			}, places.map(function(place) {
				return E('option', {
					'value': place.value,
					'selected': place.value === current ? '' : null
				}, [ place.label ]);
			}));
			select.addEventListener('change', function() {
				select.disabled = true;
				self.deviceAction([ 'set-exit', entry.addr, select.value ], null, result)
					.then(function(status) {
						if (!status)
							refreshList(lastDump);
					});
			});
			return select;
		}

		// An exclusion with nothing ticked has no effect and the router drops
		// it, so unticking the last box made the row vanish under the pointer.
		// That box stays ticked; Remove is what deletes the rule.
		function lockLastCheck(checks) {
			var ticked = Object.keys(checks).filter(function(key) { return checks[key].checked; });
			if (ticked.length !== 1)
				return;
			var last = checks[ticked[0]];
			last.disabled = true;
			last.parentNode.title = _('An exclusion keeps at least one of routing, DNS or Zapret. Use Remove to delete the rule.');
		}

		function refreshList(stdout) {
			lastDump = stdout;
			var entries = parseDeviceDump(stdout).filter(function(entry) {
				return entry.mode === 'fullroute' || entry.mode === 'exclude' ||
					entry.dns === '1' || entry.dpi === '1';
			});
			if (!entries.length) {
				list.replaceChildren(E('div', { 'class': 'ikev2-empty' }, [
					E('strong', {}, [ _('No device rules') ]),
					E('div', { 'class': 'cbi-section-descr' }, [
						_('All devices use the default routing, DNS and Zapret policies.') ])
				]));
				return;
			}

			list.replaceChildren(E('div', {
				'class': 'ikev2-device-policy-table' + (several ? ' ikev2-with-tunnel' : '')
			}, [
				E('div', { 'class': 'ikev2-device-policy-row head' }, [
					E('span', {}, [ _('Device / IP') ]),
					E('span', {}, [ _('Type') ]),
					E('span', {}, [ _('Routing') ]),
					E('span', {}, [ 'DNS' ]),
					E('span', {}, [ 'Zapret' ]),
					several ? E('span', {}, [ _('Tunnel') ]) : '',
					E('span', {}, [ _('Matched traffic') ]),
					E('span', {})
				])
			].concat(entries.map(function(entry) {
				var included = entry.mode === 'fullroute';
				var client = clientsByAddr[entry.addr];
				var hit = stats[(included ? 'fullroute' : 'exclude') + ':' + entry.addr] || {};
				var remove = E('button', {
					'class': 'cbi-button cbi-button-remove ikev2-square-action',
					'type': 'button',
					'title': _('Remove'),
					'aria-label': _('Remove')
				}, [ common.icon('trash') ]);
				remove.addEventListener('click', function() {
					self.deviceAction([ 'clear-policy', entry.addr ], remove, result);
				});
				var checks = {};
				var row = E('div', { 'class': 'ikev2-device-policy-row' }, [
					E('span', { 'class': 'ikev2-device-policy-name' }, [
						client && client.name ? E('strong', {}, [ client.name ]) : '',
						E('code', {}, [ entry.addr ])
					]),
					E('span', {}, [ common.pill(included ? _('Inclusion') : _('Exclusion'),
						included ? 'good' : 'warn') ]),
					included ? respectCheck(entry) :
						policyCheck(entry, 'pbr', _('Exclude from project routing'), checks),
					included ? E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]) :
						policyCheck(entry, 'dns', _('Use the device DNS without interception'), checks),
					included ? E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]) :
						policyCheck(entry, 'dpi', _('Bypass Zapret processing'), checks),
					!several ? '' : included ? tunnelSelect(entry) :
						E('span', { 'class': 'ikev2-policy-na' }, [ '—' ]),
					E('span', { 'class': 'ikev2-device-policy-traffic' }, [
						common.formatBytes(Number(hit.bytes || 0)) + ' · ' +
						_('%d packets').format(Number(hit.packets || 0)) ]),
					remove
				]);
				if (!included)
					lockLastCheck(checks);
				return row;
			}))));
		}

		refreshList(dumpStdout);
		(this.deviceRefreshers || (this.deviceRefreshers = [])).push(refreshList);

		var choices = clients.map(function(client) {
			return {
				value: client.addr,
				label: (client.name || _('Connected device')) + ' — ' + client.addr +
					(client.mac ? ' · ' + client.mac : '')
			};
		});
		var addr = common.choiceWithCustom(choices.length ? choices[0].value : '',
			choices, { placeholder: '192.168.2.55' });
		var type = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'exclude' }, [ _('Exclusion') ]),
			E('option', { 'value': 'include' }, [ _('Include — all traffic through VPN') ])
		]);
		var add = E('button', {
			'class': 'cbi-button cbi-button-add', 'type': 'button'
		}, [ _('Add') ]);
		add.addEventListener('click', function() {
			var value = addr.value();
			if (!validateAddr(value)) {
				result.err(_('Invalid address'));
				return;
			}
			var action = type.value === 'include' ?
				[ 'set-included', value ] : [ 'set-exclusions', value, '1', '0', '0' ];
			self.deviceAction(action, add, result, function() {
				addr.setValue(choices.length ? choices[0].value : '');
			});
		});

		return E('div', {}, [
			list,
			E('div', { 'class': 'ikev2-inline-form', 'style': 'margin-top:1rem' }, [
				E('div', { 'class': 'ikev2-device-picker' }, [ addr.node ]),
				type, result.node, add
			])
		]);
	},

	render: function(data) {
		var self = this;
		this.deviceRefreshers = [];
		var value = common.parseKeyValues(data[0].stdout);
		var doctor = common.parseKeyValues(data[1].stdout);
		var netList = parseNetworks(data[2].stdout);
		var tunnelNames = {};
		parseTunnelChoices((data[7] && data[7].stdout) || '').forEach(function(choice) {
			tunnelNames[choice.index] = choice.name;
		});
		var depRows = checkRows(doctor, tunnelNames);
		var ready = dependenciesReady(doctor);
		var quality = common.parseKeyValues((data[6] && data[6].stdout) || '');

		var enabled = input('checkbox', value.configured);
		var dnsEnforce = input('checkbox', value.dns_enforce);
		var blockDot = input('checkbox', value.block_dot);
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Apply router settings') ]);
		var applyResult = common.inlineResult();
		var saveTracker = null;
		var installDeps = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Install runtime dependencies') ]);
		var removeDeps = E('button', { 'class': 'cbi-button cbi-button-remove' }, [
			_('Reset app and remove dependencies') ]);
		// A redacted text report for a bug report, made on the router and saved
		// by the browser like a downloaded profile.
		// An encrypted copy of the settings, to restore here or on another
		// router; this router's networks and DNS snapshots stay its own.
		var exportPass = input('password', '', { 'autocomplete': 'new-password', 'placeholder': _('At least eight characters') });
		var exportButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('Download backup') ]);
		var exportResult = common.inlineResult();
		var importFile = E('input', { 'type': 'file', 'accept': '.ikev2backup,text/plain' });
		var importPass = input('password', '', { 'autocomplete': 'off' });
		var importButton = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Import backup') ]);
		var importResult = common.inlineResult();
		exportButton.addEventListener('click', function() {
			var pass = exportPass.value;
			if (pass.length < 8)
				return common.refuse(exportButton, exportResult, _('The passphrase must have at least eight characters'));
			return common.runAction({
				button: exportButton,
				result: exportResult,
				busy: _('Collecting...'),
				done: _('Downloaded'),
				run: function() {
					var token = common.inputToken();
					return fs.write('/tmp/ikev2-manager-backup-' + token + '.pass', pass, 384).then(function() {
						return common.execChecked(helper, [ 'backup-export', token ],
							_('Unable to create the backup'));
					}).then(function(response) {
						var stamp = new Date().toISOString().slice(0, 10);
						var blob = new Blob([ response.stdout || '' ], { type: 'text/plain;charset=utf-8' });
						var url = URL.createObjectURL(blob);
						var link = E('a', { 'href': url, 'download': 'ikev2-manager-' + stamp + '.ikev2backup' });
						document.body.appendChild(link);
						link.click();
						link.remove();
						window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
						exportPass.value = '';
						exportResult.ok(_('Backup downloaded. It holds the VPN passwords and the server key; keep it and its passphrase apart.'));
					});
				}
			});
		});
		importButton.addEventListener('click', function() {
			var file = importFile.files && importFile.files[0];
			var pass = importPass.value;
			if (!file)
				return common.refuse(importButton, importResult, _('Choose a backup file'));
			if (pass.length < 8)
				return common.refuse(importButton, importResult, _('The passphrase must have at least eight characters'));
			if (!window.confirm(_('Replace this router\'s IKEv2 settings, users, certificate and lists with the backup? Its networks, WAN and DNS snapshots stay as they are. The tunnels reconnect.')))
				return;
			var token = common.inputToken();
			// The inputs are written before the job starts, as for a DNS segment;
			// a failed write still ends in a result under the button.
			return file.text().then(function(text) {
				return Promise.all([
					fs.write('/tmp/ikev2-manager-backup-' + token + '.in', text.trim(), 384),
					fs.write('/tmp/ikev2-manager-backup-' + token + '.pass', pass, 384)
				]);
			}).then(function() {
				return common.runJob({
					button: importButton,
					result: importResult,
					busy: _('Importing...'),
					success: _('Settings imported.'),
					failure: _('Import failed'),
					startPath: helper,
					startArgs: [ 'backup-import-async', token ],
					statusPath: helper,
					statusArgs: [ 'action-status' ],
					timeout: 300000,
					onSuccess: function() {
						importPass.value = '';
						return refreshSetupState();
					}
				});
			}, function(error) {
				importResult.err(_('Could not read the backup file: %s').format(error.message || error));
			});
		});
		var reportButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Download report') ]);
		var reportResult = common.inlineResult();
		reportButton.addEventListener('click', function() {
			return common.runAction({
				button: reportButton,
				result: reportResult,
				busy: _('Collecting...'),
				done: _('Downloaded'),
				run: function() {
					return common.execChecked(helper, [ 'diagnostics' ],
						_('Could not collect the diagnostics report')).then(function(response) {
						var stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-');
						var blob = new Blob([ response.stdout || '' ], { type: 'text/plain;charset=utf-8' });
						var url = URL.createObjectURL(blob);
						var link = E('a', { 'href': url, 'download': 'ikev2-diagnostics-' + stamp + '.txt' });
						document.body.appendChild(link);
						link.click();
						link.remove();
						window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
						reportResult.ok(_('Report downloaded. Read it before attaching it anywhere.'));
					});
				}
			});
		});
		// Pause is the reversible counterpart of the reset below: nothing is
		// deleted, only the three things that put traffic into the tunnel stop.
		var routingPaused = value.routing_paused === '1';
		var pauseRouting = E('button', {
			'class': 'cbi-button ' + (routingPaused ? 'cbi-button-positive' : 'cbi-button-action')
		}, [ routingPaused ? _('Resume tunnel routing') : _('Pause tunnel routing') ]);
		var pauseResult = common.inlineResult();
		var pausePill = common.pill('', 'neutral');
		var pauseDescription = E('span', { 'class': 'ikev2-toggle-sub' });

		function updatePauseState() {
			pauseRouting.className = 'cbi-button ' +
				(routingPaused ? 'cbi-button-positive' : 'cbi-button-action');
			pauseRouting.textContent = routingPaused ?
				_('Resume tunnel routing') : _('Pause tunnel routing');
			common.setPill(pausePill, routingPaused ? _('Paused') : _('Routing active'),
				routingPaused ? 'warn' : 'good');
			pauseDescription.textContent = routingPaused ?
				_('Paused: selected destinations and full-tunnel devices have no connection, and none of them goes through WAN. All settings stay as configured.') :
				_('Stops using the tunnel without leaking: selected destinations and full-tunnel devices lose their connection until you resume. Other traffic is not affected.');
		}

		// Manual recovery: the same verified paths the watcher uses, for when
		// something is stuck and the automatic repair is still backing off.
		var reliableButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [ '' ]);
		var reliableResult = common.inlineResult();
		var reliableDetail = E('span', { 'class': 'ikev2-toggle-sub' });
		var pbrButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('Restart policy routing') ]);
		var pbrResult = common.inlineResult();
		var pbrDetail = E('span', { 'class': 'ikev2-toggle-sub' });

		function updateRecoveryState() {
			var fakeIp = value.domain_engine === 'fakeip';
			var restarts = Number(value.domain_data_plane_restarts || 0);
			var restartedAt = Number(value.domain_data_plane_restarted_at || 0);
			reliableButton.textContent = _('Restart reliable mode');
			reliableButton.disabled = !fakeIp;
			pbrButton.disabled = value.configured !== '1';
			pbrDetail.textContent = _('Rebuilds the policy routing rules and tables, then verifies the fail-closed routes. Traffic keeps flowing.');
			if (!fakeIp)
				reliableDetail.textContent = _('Reliable mode is not enabled.');
			else if (restarts && restartedAt)
				reliableDetail.textContent = _('Restarts the FakeIP resolver. Automatic restarts recently: %d, last at %s.')
					.format(restarts, common.formatDateTime(restartedAt));
			else
				reliableDetail.textContent = _('Restarts the FakeIP resolver. No automatic restarts recently.');
		}
		var domainRuntime = domainRuntimeStatus(value);
		var headerPill = common.pill('', 'neutral');
		// Which build is installed, next to the state it produced.
		var versionPill = value.version ?
			common.pill('v' + value.version, 'neutral') : '';
		var managedDescription = E('p', {});
		var managedToggle = common.toggleRow(enabled, _('Let the app manage the router'), '');
		var domainDetail = E('span', { 'class': 'ikev2-toggle-sub' });
		var domainPill = common.pill('', 'neutral');
		var depsChecks = E('div', {});
		var depsResult = common.inlineResult();
		var depsPill = common.pill('', 'neutral');

		function renderDependencyChecks() {
			depRows = checkRows(doctor, tunnelNames);
			// Keep the details open across a refresh if the reader opened them.
			var openDetails = depsChecks.querySelector && depsChecks.querySelector('details[open]');
			depsChecks.replaceChildren(dependencyOverview(depRows, !!openDetails));
		}

		function updateSetupState() {
			ready = dependenciesReady(doctor);
			var known = dependenciesKnown(doctor);
			domainRuntime = domainRuntimeStatus(value);
			enabled.checked = value.configured === '1';
			// Disabling must always remain available for an already managed router,
			// even when a runtime check is degraded. Package readiness only gates a
			// fresh enable; runtime drift is repaired by Apply, not dependency install.
			enabled.disabled = value.configured !== '1' && !ready;
			if (saveTracker)
				saveTracker.update();
			managedDescription.textContent = ready ?
				_('Master switch: lets the app create and own the router routing and firewall. Network and DNS changes are applied together by the button at the bottom.') :
				(known ? _('Install the runtime dependencies below first — then this switch becomes available.') :
					_('Runtime dependencies could not be checked. Reload the page and try again.'));
			var toggleSub = managedToggle.querySelector('.ikev2-toggle-sub');
			if (toggleSub)
				toggleSub.textContent = ready ?
					_('Creates and owns routing and firewall rules on the router.') :
				(known ? _('Available after runtime dependencies are installed.') :
					_('Available after the runtime check succeeds.'));
			common.setPill(headerPill,
				value.configured === '1' ? _('Configured') : _('Not configured'),
				value.configured === '1' ? 'good' : 'warn');
			domainDetail.textContent = domainRuntime.detail;
			common.setPill(domainPill, domainRuntime.label, domainRuntime.tone);
			common.setPill(depsPill,
				ready ? _('Ready') : (known ? _('Dependencies missing') : _('Check unavailable')),
				ready ? 'good' : (known ? 'bad' : 'warn'));
			installDeps.style.display = known && !ready ? '' : 'none';
			removeDeps.style.display = ready ? '' : 'none';
			renderDependencyChecks();
			updatePauseState();
			updateRecoveryState();
		}

		function refreshSetupState() {
			return Promise.all([
				common.execChecked(helper, [ 'get' ], _('Unable to refresh configuration')),
				common.execChecked(helper, [ 'doctor-ui' ], _('Unable to refresh system readiness'))
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				doctor = common.parseKeyValues(results[1].stdout || '');
				updateSetupState();
			});
		}

		// ── Network selectors ────────────────────────────────────────────
		var wanField, protectedField;

		// The inbound VPN server is a selectable "network": when on, its clients
		// (ipsec-in) follow the same domain policy as local networks.
		var vpnPick = value.server_enabled === '1'
			? common.netPick('__vpn__', _('VPN server'), _('Inbound clients (ipsec-in)'),
				value.source_include_vpn !== '0')
			: null;

		wanField = common.choiceWithCustom(value.wan_interface, netList.map(function(o) {
			return { value: o.name, label: o.name + ' — ' + o.cidr };
		}), { placeholder: 'wan' });
		protectedField = common.multiChoiceWithCustom(value.source_interfaces,
			netList.filter(function(o) { return o.name !== value.wan_interface; })
				.map(function(o) {
					return { value: o.name, name: o.name, meta: o.cidr };
				}),
			{
				placeholder: 'lan iot',
				prependNodes: vpnPick ? [ vpnPick.node ] : [],
				customBelow: true
			});
		var protectedNode = protectedField.node;

		save.addEventListener('click', function() {
			var selectedWan = wanField.value();
			var protectedVal = protectedField.value().split(/\s+/).filter(function(name) {
				return name && name !== selectedWan;
			}).join(' ');
			// Policy routing needs a local network to take traffic from; the
			// router refused an empty list with a message nobody could act on.
			if (!protectedVal)
				return common.refuse(save, applyResult, _('Keep at least one local network protected.'));
			var args = [
				'set',
				enabled.checked ? '1' : '0',
				selectedWan,
				protectedVal,
				dnsEnforce.checked ? '1' : '0',
				blockDot.checked ? '1' : '0',
				vpnPick ? (vpnPick.input.checked ? '1' : '0') : (value.source_include_vpn || '1')
			];
			args[0] = 'set-async';
			return common.runJob({
				button: save,
				result: applyResult,
				busy: enabled.checked ? _('Applying configuration...') : _('Disabling...'),
				success: enabled.checked ? _('Applied') : _('Disabled'),
				failure: _('Apply failed'),
				startPath: helper,
				startArgs: args,
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 150000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout')
						return refreshSetupState().then(function() { saveTracker.reset(); });
				}
			});
		});

		installDeps.addEventListener('click', function() {
			if (!window.confirm(_('Install missing runtime packages now? DNS/DHCP may restart briefly while dnsmasq-full replaces dnsmasq.')))
				return;
			runDepsJob(installDeps, 'install-deps', depsResult,
				_('Dependencies installed. Rechecking...'), refreshSetupState, _('Installed'));
		});

		// Read the new state back from the router instead of assuming it, so the
		// button, pill and recovery controls show what actually happened.
		function refreshRoutingState() {
			return refreshSetupState().then(function() {
				routingPaused = value.routing_paused === '1';
				updatePauseState();
				updateRecoveryState();
			});
		}

		// Pause and recovery are system actions: they report through the system
		// action status, not the dependency installer's status file.
		// `done` is the short word the button shows for a moment on success.
		function runSystemAction(button, verb, result, busy, success, failure, done) {
			return common.runJob({
				button: button,
				result: result,
				busy: busy,
				done: done,
				success: success,
				failure: failure,
				startPath: helper,
				startArgs: [ verb ],
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 150000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout')
						return refreshRoutingState();
				}
			});
		}

		pauseRouting.addEventListener('click', function() {
			return routingPaused ?
				runSystemAction(pauseRouting, 'routing-resume-async', pauseResult,
					_('Resuming tunnel routing...'), _('Tunnel routing resumed.'),
					_('Could not resume tunnel routing'), _('Resumed')) :
				runSystemAction(pauseRouting, 'routing-pause-async', pauseResult,
					_('Pausing tunnel routing...'), _('Tunnel routing paused; selected traffic is blocked until you resume.'),
					_('Could not pause tunnel routing'), _('Paused'));
		});

		reliableButton.addEventListener('click', function() {
			return runSystemAction(reliableButton, 'recover-reliable-async', reliableResult,
				_('Restarting reliable mode...'), _('Reliable mode restarted.'),
				_('Could not restart reliable mode'), _('Restarted'));
		});

		pbrButton.addEventListener('click', function() {
			return runSystemAction(pbrButton, 'pbr-restart-async', pbrResult,
				_('Restarting policy routing...'), _('Policy routing restarted; fail-closed routing verified.'),
				_('Policy routing restart failed'), _('Restarted'));
		});

		removeDeps.addEventListener('click', function() {
			if (!window.confirm(_('Reset the app and prepare it for removal? All app functions stop; its settings, users, secrets, generated files and app-owned dependencies are removed. Pre-install DNS/DHCP is restored. Shared packages required by other software are kept.')))
				return;
			runDepsJob(removeDeps, 'remove-deps', depsResult,
				_('Application reset completed.'), refreshSetupState, _('Reset complete'));
		});

		// Apply is grey until one of the settings it sends differs from what the
		// router has; an unmanaged router also needs its dependencies first.
		saveTracker = common.trackChanges(save,
			[ enabled, wanField.node, protectedNode, dnsEnforce, blockDot ], {
				blocked: function() { return value.configured !== '1' && !ready; }
			});
		updateSetupState();

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('IKEv2 Manager Overview'),
					_('Install the app safely, prepare dependencies, then enable the managed routing configuration only when the checks are green.'),
					[ versionPill, headerPill ]),
				E('section', { 'class': 'ikev2-section' }, [
					E('div', { 'class': 'ikev2-section-head' }, [
						E('div', {}, [
							E('h3', {}, [ _('Managed mode') ]),
							managedDescription
						])
					]),
					managedToggle,
					E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:1rem' }, [
						E('span', { 'class': 'ikev2-health-copy' }, [
							E('strong', {}, [ _('Domain routing') ]),
							domainDetail
						]),
						domainPill
					]),
					qualityRow(quality)
				]),
				common.section(_('Routing control'),
					_('Pause is a deliberate choice; the restarts are for when something is stuck and the automatic repair has not caught up yet. Each action runs in the background and reports its result under its button.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-health-row ikev2-action-row' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('Tunnel routing') ]),
								pauseDescription
							]),
							E('div', { 'class': 'ikev2-actions' }, [ pauseResult.node, pauseRouting ])
						]),
						E('div', { 'class': 'ikev2-health-row ikev2-action-row' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('Reliable mode') ]),
								reliableDetail
							]),
							E('div', { 'class': 'ikev2-actions' }, [ reliableResult.node, reliableButton ])
						]),
						E('div', { 'class': 'ikev2-health-row ikev2-action-row' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('Policy routing') ]),
								pbrDetail
							]),
							E('div', { 'class': 'ikev2-actions' }, [ pbrResult.node, pbrButton ])
						])
					]),
					pausePill),
				common.section(_('Runtime dependencies'),
					_('Required VPN, routing and DNS components. Only warnings and failures are shown until technical details are opened.'),
					E('div', {}, [
						depsChecks,
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
							depsResult.node,
							installDeps,
							removeDeps
						]),
						E('div', { 'class': 'ikev2-health-row ikev2-action-row', 'style': 'margin-top:1rem' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('Diagnostics report') ]),
								E('span', { 'class': 'ikev2-toggle-sub' }, [
									_('A text file of the router state for a bug report. Passwords, keys and tokens are left out; public and MAC addresses and host and user names are replaced.') ])
							]),
							E('div', { 'class': 'ikev2-actions' }, [ reportResult.node, reportButton ])
						])
					]),
					depsPill),
				common.section(_('Network integration'),
					_('Choose the WAN uplink and the networks this app protects. Firewall zones are detected automatically.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('WAN network'),
								_('The internet uplink. Receives UDP 500/4500 when the inbound server is enabled.')),
							wanField.node
						]),
						E('div', { 'style': 'margin-top:1.15rem' }, [
							common.fieldLabel(_('Protected networks'),
								_('Networks whose selected domains use the outbound tunnel.')),
							E('div', { 'style': 'margin-top:.6rem' }, [ protectedNode ])
						])
					])),
				common.section(_('Device rules'),
					_('Keep inclusions and exclusions in one list. Excluded devices can independently bypass project routing, DNS interception and Zapret.'),
					self.renderDevicePolicies(data[3].stdout, data[4].stdout, data[5].stdout,
						(data[7] && data[7].stdout) || '')),
				common.section(_('DNS policy'),
					null,
					E('div', {}, [
						E('div', { 'class': 'ikev2-two-col' }, [
							common.toggleRow(dnsEnforce, _('Redirect plain DNS'),
								_('Redirect TCP/UDP port 53 from protected zones to the router.')),
							common.toggleRow(blockDot, _('Block DNS-over-TLS'),
								_('Reject TCP/UDP port 853 from protected zones to WAN.'))
						]),
						E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:.85rem' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('IPv6 fail-fast') ]),
								E('span', { 'class': 'ikev2-toggle-sub' }, [
									_('Dual-stack clients drop to IPv4 instead of hanging when there is no IPv6 WAN.') ])
							]),
							common.pill(
								value.ipv6_failfast === 'active' ? _('active') :
									(value.ipv6_failfast === 'na' ? _('IPv6 WAN present') : _('off')),
								value.ipv6_failfast === 'active' ? 'good' : 'neutral')
						])
					])),
				E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
					E('span', { 'class': 'ikev2-field-help' }, [
						_('Applies managed mode, networks and DNS policy. When anything changed, policy routing and the FakeIP resolver are rebuilt, and connections may pause for a few seconds.')
					]),
					applyResult.node,
					save
				]),
				common.section(_('Settings backup'),
					_('An encrypted copy of the IKEv2 settings, VPN users and passwords, custom services and lists, the server certificate with its key and the ACME settings. Importing it here or on another router keeps that router\'s networks, WAN, firewall zones, original DNS and domain-routing engine.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('Backup passphrase'),
								_('Needed again to import. It is not stored anywhere.')),
							exportPass
						]),
						E('div', { 'class': 'ikev2-actions end' }, [ exportResult.node, exportButton ]),
						E('div', { 'class': 'ikev2-form-grid', 'style': 'margin-top:1rem' }, [
							common.fieldLabel(_('Backup file')), importFile,
							common.fieldLabel(_('Its passphrase')), importPass
						]),
						E('div', { 'class': 'ikev2-actions end' }, [ importResult.node, importButton ])
					]))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
