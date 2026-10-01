'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require ikev2-manager.shared-v11 as common';

var helper = '/usr/libexec/ikev2-manager';

function sessionsByUser(sas) {
	var result = {};
	sas.forEach(function(item) {
		var sa = item['ikev2-in'];
		if (!sa)
			return;
		var user = sa['remote-eap-id'] || sa['remote-id'] || _('Unknown');
		var children = Object.values(sa['child-sas'] || {});
		var bytesIn = 0, bytesOut = 0;
		children.forEach(function(child) {
			bytesIn += Number(child['bytes-in'] || 0);
			bytesOut += Number(child['bytes-out'] || 0);
		});
		if (!result[user])
			result[user] = [];
		result[user].push({
			id: sa.uniqueid,
			host: sa['remote-host'],
			vips: sa['remote-vips'] || [],
			established: sa.established,
			// strongSwan reports traffic relative to the router. For a remote
			// VPN user, router bytes-out are downloaded by the client and
			// router bytes-in are uploaded by the client.
			bytesReceived: bytesOut,
			bytesSent: bytesIn
		});
	});
	return result;
}

function loadUsers() {
	return Promise.all([
		fs.exec(helper, [ 'users-show' ]),
		L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' }),
		L.resolveDefault(fs.exec(helper, [ 'server-get' ]), { stdout: '' }),
		L.resolveDefault(fs.exec(helper, [ 'diagnostic-report' ]), { stdout: '' })
	]);
}

function loadUserRuntime() {
	return Promise.all([
		fs.exec(helper, [ 'users-show' ]),
		L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' })
	]);
}

function diagnosticReportNode(stdout) {
	var rows = (stdout || '').replace(/\r/g, '').split('\n').filter(Boolean).map(function(line) {
		var fields = line.split('\t');
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, [ fields[0] || _('Unknown') ]),
			E('td', { 'class': 'td' }, [ E('code', {}, [ fields[1] || 'IKE' ]) ]),
			E('td', { 'class': 'td' }, [ fields[2] || _('Unknown failure') ])
		]);
	});
	if (!rows.length)
		return E('div', { 'class': 'ikev2-empty' }, [ _('No failed attempts captured.') ]);
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, [ _('Identity') ]),
			E('th', { 'class': 'th' }, [ _('Phase') ]),
			E('th', { 'class': 'th' }, [ _('Reason') ])
		])
	].concat(rows));
}

function saveBlob(blob, filename) {
	var url = URL.createObjectURL(blob);
	var link = E('a', { 'href': url, 'download': filename });
	document.body.appendChild(link);
	link.click();
	link.remove();
	window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

function downloadWindowsInstaller(button, result) {
	return common.runAction({
		button: button,
		result: result,
		busy: _('Downloading...'),
		run: function() {
			return fetch(L.resource('ikev2-manager/Nikitid-IKEv2-Setup.exe'), {
				cache: 'no-store'
			}).then(function(response) {
				if (!response.ok)
					throw new Error(_('Could not download the Windows installer'));
				return response.blob();
			}).then(function(blob) {
				saveBlob(blob, 'Nikitid-IKEv2-Setup.exe');
				result.ok(_('Windows application downloaded.'));
			});
		}
	});
}

function downloadProfile(platform, user, button, result) {
	var suffix = platform === 'apple' ? '.mobileconfig' :
		(platform === 'windows' ? '.vpnv2.xml' : '-android.txt');
	var mime = platform === 'apple' ? 'application/x-apple-aspen-config' :
		(platform === 'windows' ? 'application/xml' : 'text/plain');
	var safeUser = user.replace(/[^A-Za-z0-9._-]+/g, '_');
	return common.runAction({
		button: button,
		result: result,
		busy: _('Generating...'),
		run: function() {
			return common.execChecked(helper, [ 'profile-export', platform, user ],
				_('Could not generate client profile')).then(function(response) {
				var blob = new Blob([ response.stdout || '' ], { type: mime + ';charset=utf-8' });
				var url = URL.createObjectURL(blob);
				var link = E('a', { 'href': url, 'download': safeUser + suffix });
				document.body.appendChild(link);
				link.click();
				link.remove();
				window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
				result.ok(_('Profile generated.'));
			});
		}
	});
}

function profileDialog(user, result) {
	function platformButton(platform, label) {
		var button = E('button', {
			'class': 'cbi-button cbi-button-action', 'type': 'button'
		}, [ label ]);
		button.addEventListener('click', function() {
			return downloadProfile(platform, user, button, result);
		});
		return button;
	}
	ui.showModal(_('Client profile for %s').format(user), [
		E('div', { 'class': 'ikev2-note warn' }, [
			_('Apple and Android downloads contain the VPN password. Store them securely and delete them after installation.')
		]),
		E('div', { 'class': 'ikev2-form-grid', 'style': 'margin-top:1rem' }, [
			common.fieldLabel(_('Apple'),
				_('Install the mobileconfig in Settings on iPhone, iPad or macOS.')),
			platformButton('apple', _('Download mobileconfig')),
			common.fieldLabel(_('Windows'),
				_('Download this XML, then select it in Nikitid IKEv2 Setup. The same application works with profiles from any server.')),
			platformButton('windows', _('Download VPNv2 XML')),
			common.fieldLabel(_('Android'),
				_('Use these values in the built-in IKEv2 EAP client.')),
			platformButton('android', _('Download setup details'))
		]),
		E('div', { 'class': 'right', 'style': 'margin-top:1rem' }, [
			E('button', {
				'class': 'btn', 'type': 'button', 'click': ui.hideModal
			}, [ _('Close') ])
		])
	]);
}

function runUserAction(button, args, result, success, opts) {
	opts = opts || {};
	return common.runAction({
		button: button,
		result: result,
		busy: opts.busy || _('Saving...'),
		success: success,
		run: function() {
			return common.execChecked(helper, args, _('Operation failed'));
		},
		onSuccess: opts.onSuccess
	});
}

function runUserInputAction(button, action, user, password, policy, result, success, onSuccess) {
	var fields = [ action, user, password || '' ];
	if (policy) {
		fields.push(policy.routerAccess, policy.internetAccess, policy.lanAccess,
			policy.pbrMode, policy.lanTargets || '', policy.publicPorts || '');
	}
	var payload = fields.join('\n') + '\n';
	var token = common.inputToken();
	return fs.write('/var/run/ikev2-manager-user-' + token + '.in', payload, 384 /* 0600 */).then(function() {
		return runUserAction(button, [ 'user-secret-set', token ], result, success, {
			onSuccess: onSuccess
		});
	}, function(error) {
		result.err(_('Unable to save the VPN user: %s').format(error.message || error));
	});
}

function policySelect(value, choices) {
	return E('select', {
		'class': 'cbi-input-select',
		'value': value
	}, choices.map(function(choice) {
		return E('option', {
			'value': choice.value,
			'selected': choice.value === value ? '' : null
		}, [ choice.label ]);
	}));
}

function normalizePortList(value) {
	return String(value || '').trim().split(/[\s,]+/).filter(Boolean).join(' ');
}

function validPortList(value) {
	var items = normalizePortList(value).split(/\s+/).filter(Boolean);
	if (items.length > 64)
		return false;
	return items.every(function(item) {
		var match = item.match(/^([0-9]+)(?:-([0-9]+))?$/);
		if (!match)
			return false;
		var start = Number(match[1]);
		var end = match[2] ? Number(match[2]) : start;
		return start >= 1 && start <= 65535 && end >= start && end <= 65535;
	});
}

function policyEditor(entry) {
	entry = entry || {};
	var routerAccess = policySelect(entry.routerAccess || 'inherit', [
		{ value: 'inherit', label: _('Use global setting') },
		{ value: 'allow', label: _('Allow') },
		{ value: 'deny', label: _('Deny') }
	]);
	var internetAccess = policySelect(entry.internetAccess || 'inherit', [
		{ value: 'inherit', label: _('Use global setting') },
		{ value: 'allow', label: _('Allow') },
		{ value: 'deny', label: _('Deny') }
	]);
	var lanAccess = policySelect(entry.lanAccess || 'inherit', [
		{ value: 'inherit', label: _('Use global setting') },
		{ value: 'all', label: _('All local networks') },
		{ value: 'limited', label: _('Only selected addresses') },
		{ value: 'deny', label: _('Deny') }
	]);
	var lanTargets = E('textarea', {
		'class': 'cbi-input-textarea',
		'rows': '3',
		'placeholder': '192.168.1.10 192.168.20.0/24'
	}, [ (entry.lanTargets || '').replace(/\s+/g, '\n') ]);
	var lanTargetsLabel = common.fieldLabel(_('Allowed local addresses'));
	var pbrMode = policySelect(entry.pbrMode || 'inherit', [
		{ value: 'inherit', label: _('Use project routing') },
		{ value: 'exclude', label: _('Direct WAN — exclude from project routing') }
	]);
	var publicPorts = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': entry.publicPorts || '',
		'placeholder': '1443 8443-8445'
	});

	function sync() {
		lanTargets.disabled = lanAccess.value !== 'limited';
		lanTargets.style.display = lanAccess.value === 'limited' ? '' : 'none';
		lanTargetsLabel.style.display = lanAccess.value === 'limited' ? '' : 'none';
		publicPorts.disabled = routerAccess.value === 'allow';
	}
	routerAccess.addEventListener('change', sync);
	lanAccess.addEventListener('change', sync);
	sync();

	return {
		fields: [
			common.fieldLabel(_('Router access'),
				_('DNS remains available even when router access is denied.')),
			routerAccess,
			common.fieldLabel(_('Public router ports'),
				_('Additional TCP/UDP ports remain available when router access is denied. Use spaces or commas between ports and ranges.')),
			publicPorts,
			common.fieldLabel(_('Internet access'),
				_('Allows normal WAN traffic and selected destinations through the outbound tunnel.')),
			internetAccess,
			common.fieldLabel(_('Local network access'),
				_('Limit access to individual IPv4 addresses or CIDR networks when needed.')),
			lanAccess,
			lanTargetsLabel,
			lanTargets,
			common.fieldLabel(_('Project routing'),
				_('Direct WAN bypasses the project domain policy for this VPN user.')),
			pbrMode
		],
		value: function() {
			return {
				routerAccess: routerAccess.value,
				internetAccess: internetAccess.value,
				lanAccess: lanAccess.value,
				pbrMode: pbrMode.value,
				publicPorts: routerAccess.value === 'allow' ? '' :
					normalizePortList(publicPorts.value),
				lanTargets: lanAccess.value === 'limited' ?
					lanTargets.value.trim().split(/[\s,]+/).filter(Boolean).join(' ') : ''
			};
		}
	};
}

function passwordDialog(title, username, action, includeUsername, pageResult, refresh) {
	var name = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': username || '',
		'placeholder': 'new-user',
		'autocomplete': 'off'
	});
	var password = E('input', {
		'type': 'password',
		'class': 'cbi-input-text',
		'placeholder': _('Password'),
		'autocomplete': 'new-password'
	});
	var fields = [];
	var dialogResult = common.inlineResult();

	if (includeUsername) {
		fields.push(common.fieldLabel(_('Username'), _('Letters, digits, dot, dash and underscore.')));
		fields.push(name);
	}
	fields.push(common.fieldLabel(_('Password')));
	fields.push(password);
	if (action === 'user-password')
		fields.push(E('div', { 'class': 'ikev2-note' }, [
			_('Sessions this user has open are disconnected; its devices connect again with the new password.')
		]));

	var dialogGrid = E('div', { 'class': 'ikev2-form-grid' }, fields);
	var dialogSave = null;
	var dialogNode = E('div', { 'class': 'ikev2-page' }, [
			common.styles(),
			dialogGrid,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1.2rem;' }, [
				dialogResult.node,
				E('button', {
					'class': 'cbi-button',
					'type': 'button',
					'click': ui.hideModal
				}, [ _('Cancel') ]),
				(dialogSave = E('button', {
					'class': 'cbi-button cbi-button-positive',
					'type': 'button',
					'click': function(ev) {
						var button = ev.currentTarget;
						var user = includeUsername ? name.value.trim() : username;
						if (!/^[A-Za-z0-9_.@-]{1,64}$/.test(user)) {
							dialogResult.err(_('Invalid username.'));
							return;
						}
						if (!password.value) {
							dialogResult.err(_('Password is required.'));
							return;
						}
						return runUserInputAction(button,
							action === 'user-add' ? 'add' : 'password', user, password.value,
							null,
							dialogResult,
							includeUsername ? _('VPN user added.') : _('Password changed.'),
							function() {
								return refresh().then(function() {
									ui.hideModal();
									pageResult.ok(includeUsername ?
										_('VPN user added.') : _('Password changed.'));
								});
							});
					}
				}, [ _('Save') ]))
			])
		]);
	ui.showModal(title, [ dialogNode ]);
	// Save stays grey until the dialog holds something to save: a password, a
	// new user, or a policy that differs from the one it opened with.
	common.trackChanges(dialogSave, [ dialogGrid ]);
	(includeUsername ? name : password).focus();
}

function userDialog(title, entry, includeIdentity, pageResult, refresh) {
	entry = entry || {};
	var name = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': entry.name || '',
		'placeholder': 'new-user',
		'autocomplete': 'off'
	});
	var password = E('input', {
		'type': 'password',
		'class': 'cbi-input-text',
		'placeholder': _('Password'),
		'autocomplete': 'new-password'
	});
	var editor = policyEditor(entry);
	var dialogResult = common.inlineResult();
	var fields = [];
	if (includeIdentity) {
		fields.push(common.fieldLabel(_('Username'), _('Letters, digits, dot, dash and underscore.')));
		fields.push(name);
		fields.push(common.fieldLabel(_('Password')));
		fields.push(password);
	}
	fields.push(common.fieldLabel(_('Individual access policy'),
		_('Global values remain defaults; choose an override only where this user differs.')));
	fields.push(E('div', { 'class': 'ikev2-note' }, [
		_('A newly connected client is blocked until its authenticated identity is matched to its virtual address.')
	]));
	fields = fields.concat(editor.fields);

	var dialogGrid = E('div', { 'class': 'ikev2-form-grid' }, fields);
	var dialogSave = null;
	var dialogNode = E('div', { 'class': 'ikev2-page' }, [
			common.styles(),
			dialogGrid,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1.2rem;' }, [
				dialogResult.node,
				E('button', {
					'class': 'cbi-button',
					'type': 'button',
					'click': ui.hideModal
				}, [ _('Cancel') ]),
				(dialogSave = E('button', {
					'class': 'cbi-button cbi-button-positive',
					'type': 'button',
					'click': function(ev) {
						var button = ev.currentTarget;
						var user = includeIdentity ? name.value.trim() : entry.name;
						var policy = editor.value();
						if (!/^[A-Za-z0-9_.@-]{1,64}$/.test(user)) {
							dialogResult.err(_('Invalid username.'));
							return;
						}
						if (includeIdentity && !password.value) {
							dialogResult.err(_('Password is required.'));
							return;
						}
						if (policy.lanAccess === 'limited' && !policy.lanTargets) {
							dialogResult.err(_('Enter at least one allowed local address.'));
							return;
						}
						if (!validPortList(policy.publicPorts)) {
							dialogResult.err(_('Enter valid public router ports or ranges.'));
							return;
						}
						return runUserInputAction(button, includeIdentity ? 'add' : 'policy',
							user, includeIdentity ? password.value : '', policy, dialogResult,
							includeIdentity ? _('VPN user added.') : _('Access policy saved.'),
							function() {
								return refresh().then(function() {
									ui.hideModal();
									pageResult.ok(includeIdentity ?
										_('VPN user added.') : _('Access policy saved.'));
								});
							});
					}
				}, [ _('Save') ]))
			])
		]);
	ui.showModal(title, [ dialogNode ]);
	// Save stays grey until the dialog holds something to save: a password, a
	// new user, or a policy that differs from the one it opened with.
	common.trackChanges(dialogSave, [ dialogGrid ]);
	if (includeIdentity)
		name.focus();
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return loadUsers().then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('VPN Users'),
				_('Manage inbound IKEv2 credentials and current sessions. Traffic counters reset when a session reconnects.')) ]);
		var users = [];
		var sessions = {};
		var online = 0;
		var list = E('div', {});
		var userCount = common.pill('', 'info');
		var onlineCount = common.pill('', 'neutral');
		var actionResult = common.inlineResult();
		var disconnectAll;
		var customMode = false;
		var diagnosticReport = E('div', {});
		var diagnosticResult = common.inlineResult();
		var installerResult = common.inlineResult();
		var installerButton = E('button', {
			'class': 'cbi-button cbi-button-action ikev2-icon-button',
			'type': 'button'
		}, [ common.icon('download'), E('span', {}, [ _('Download application') ]) ]);
		installerButton.addEventListener('click', function() {
			return downloadWindowsInstaller(installerButton, installerResult);
		});
		var diagnosticButton = E('button', {
			'class': 'cbi-button cbi-button-action', 'type': 'button'
		}, [ _('Capture for 60 seconds') ]);
		diagnosticButton.addEventListener('click', function() {
			return common.runJob({
				button: diagnosticButton,
				result: diagnosticResult,
				busy: _('Capturing inbound IKE attempts...'),
				success: _('Capture completed.'),
				failure: _('Capture failed.'),
				startPath: helper,
				startArgs: [ 'diagnostic-start', '60' ],
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 90000,
				onSuccess: function() {
					return common.execChecked(helper, [ 'diagnostic-report' ],
						_('Could not read diagnostic report')).then(function(response) {
						diagnosticReport.replaceChildren(diagnosticReportNode(response.stdout || ''));
					});
				}
			});
		});

		function actionButton(icon, label, className, handler) {
			return E('button', {
				'class': 'cbi-button ikev2-icon-button ' + className,
				'type': 'button',
				'title': label,
				'aria-label': label,
				'click': handler
			}, [ common.icon(icon), E('span', {}, [ label ]) ]);
		}

		function squareAction(icon, label, className, handler) {
			return E('button', {
				'class': 'cbi-button ikev2-platform-action ' + className,
				'type': 'button',
				'title': label,
				'aria-label': label,
				'click': handler
			}, [ common.icon(icon) ]);
		}

		function refresh(runtimeOnly) {
			return (runtimeOnly ? loadUserRuntime() : loadUsers()).then(function(next) {
				setData(next, runtimeOnly);
			});
		}

		function renderList() {
			var userCards = [];
			users.forEach(function(entry) {
				var active = sessions[entry.name] || [];
				var sessionNode = active.length ? E('div', { 'class': 'ikev2-session-list' },
				active.map(function(session) {
					var disconnectLabel = _('Disconnect');
					return E('div', { 'class': 'ikev2-session' }, [
						E('div', { 'class': 'ikev2-session-main' }, [
							E('span', { 'class': 'ikev2-session-address' }, [
								(session.vips || []).join(', ') || session.host || '-'
							]),
							E('div', { 'class': 'ikev2-session-meta' }, [
								E('span', {}, [
									_('Online for %s').format(common.formatDuration(session.established))
								]),
								E('span', {
									'class': 'ikev2-traffic received',
									'title': _('Received'),
									'aria-label': _('Received %s').format(common.formatBytes(session.bytesReceived))
								}, [
									common.icon('down'),
									E('span', {}, [ common.formatBytes(session.bytesReceived) ])
								]),
								E('span', {
									'class': 'ikev2-traffic sent',
									'title': _('Sent'),
									'aria-label': _('Sent %s').format(common.formatBytes(session.bytesSent))
								}, [
									common.icon('up'),
									E('span', {}, [ common.formatBytes(session.bytesSent) ])
								])
							])
						]),
						actionButton('disconnect', disconnectLabel, 'cbi-button-neutral', function(ev) {
							return runUserAction(ev.currentTarget,
								[ 'disconnect', String(session.id) ],
								actionResult,
								_('Session disconnected.'),
								{ busy: _('Disconnecting...'),
								  onSuccess: refresh });
						})
					]);
				})) : E('div', { 'class': 'ikev2-session-meta' }, [ _('No active sessions') ]);

				var changeLabel = _('Change password');
				var deleteLabel = _('Delete');
				userCards.push(E('div', { 'class': 'ikev2-user-card' }, [
					E('div', { 'class': 'ikev2-user-identity' }, [
						E('span', { 'class': 'ikev2-user-avatar' }, [ entry.name.slice(0, 1) || '?' ]),
						E('div', { 'style': 'min-width:0' }, [
							E('strong', { 'class': 'ikev2-user-name' }, [ entry.name ]),
							active.length ?
								common.pill(active.length > 1 ?
									_('%d active sessions').format(active.length) : _('Online'), 'good') :
								common.pill(_('Offline'), 'neutral')
						])
					]),
					E('div', { 'style': 'display:grid;gap:.45rem;min-width:0' }, [ sessionNode ]),
					E('div', { 'class': 'ikev2-user-actions' }, [
						E('div', { 'class': 'ikev2-profile-actions' }, [
							squareAction('phone', _('Download iOS profile'), 'cbi-button-action', function(ev) {
								return downloadProfile('apple', entry.name, ev.currentTarget, actionResult);
							}),
							squareAction('windows', _('Download Windows profile'), 'cbi-button-action', function(ev) {
								return downloadProfile('windows', entry.name, ev.currentTarget, actionResult);
							}),
							squareAction('android', _('Download Android profile'), 'cbi-button-action', function(ev) {
								return downloadProfile('android', entry.name, ev.currentTarget, actionResult);
							})
						]),
						squareAction('settings', _('Access policy'), 'cbi-button-edit', function() {
							userDialog(_('VPN user access'), entry, false, actionResult, refresh);
						}),
						squareAction('key', changeLabel, 'cbi-button-edit', function() {
							passwordDialog(_('Change password'), entry.name,
								'user-password', false, actionResult, refresh);
						}),
						squareAction('trash', deleteLabel, 'cbi-button-remove', function(ev) {
							if (!window.confirm(active.length ?
								_('Delete user %s? Its active sessions (%d) are disconnected.').format(entry.name, active.length) :
								_('Delete user %s?').format(entry.name)))
								return;
							return runUserAction(ev.currentTarget,
								[ 'user-delete', entry.name ],
								actionResult,
								_('VPN user deleted.'),
								{ busy: _('Deleting...'),
								  onSuccess: refresh });
						})
					])
				]));
			});
			list.replaceChildren(users.length ?
				E('div', { 'class': 'ikev2-user-list' }, userCards) :
				E('div', { 'class': 'ikev2-empty' }, [ _('No VPN users configured.') ]));
		}

		function setData(next, runtimeOnly) {
			users = ((next[0] && next[0].stdout) || '').replace(/\r/g, '').split('\n')
				.filter(Boolean).map(function(line) {
					var fields = line.split('\t');
					return {
						name: fields[0],
						routerAccess: fields[1] || 'inherit',
						internetAccess: fields[2] || 'inherit',
						lanAccess: fields[3] || 'inherit',
						pbrMode: fields[4] || 'inherit',
						lanTargets: fields[5] || '',
						publicPorts: fields[6] || ''
					};
				});
			sessions = sessionsByUser(common.parseSwanmon(next[1] || { stdout: '' }));
			if (!runtimeOnly) {
				customMode = common.parseKeyValues((next[2] && next[2].stdout) || '').custom_config === '1';
				diagnosticReport.replaceChildren(diagnosticReportNode(
					(next[3] && next[3].stdout) || ''));
			}
			online = Object.keys(sessions).reduce(function(total, user) {
				return total + sessions[user].length;
			}, 0);
			common.setPill(userCount, _('%d users').format(users.length), 'info');
			common.setPill(onlineCount, _('%d online').format(online), online ? 'good' : 'neutral');
			if (disconnectAll) {
				if (disconnectAll.dataset.busy === '1')
					disconnectAll.dataset.idleDisabled = online ? '0' : '1';
				else
					disconnectAll.disabled = !online;
			}
			renderList();
		}

		var add = actionButton('addUser', _('Add user'), 'cbi-button-add', function() {
				userDialog(_('Add VPN user'), {}, true, actionResult, refresh);
			});
		disconnectAll = actionButton('disconnectAll', _('Disconnect all'),
			'cbi-button-negative', function(ev) {
				if (!window.confirm(_('Disconnect all active VPN sessions?')))
					return;
				return runUserAction(ev.currentTarget, [ 'disconnect-all' ], actionResult,
					_('All sessions disconnected.'),
					{ busy: _('Disconnecting...'),
					  onSuccess: refresh });
			});
		setData(data);
		poll.add(function() { return refresh(true); }, 5);

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('VPN Users'),
					_('Manage inbound IKEv2 credentials and current sessions. Traffic counters reset when a session reconnects.')),
				E('div', { 'class': 'ikev2-windows-app' }, [
					E('div', { 'class': 'ikev2-windows-app-mark' }, [ common.icon('windows') ]),
					E('div', { 'class': 'ikev2-windows-app-copy' }, [
						E('strong', {}, [ _('VPN setup for Windows') ]),
						E('span', {}, [ _('Download the application once, then open any downloaded VPNv2 XML profile in it.') ])
					]),
					installerResult.node,
					installerButton
				]),
				common.section(_('Access list'),
					_('Passwords are write-only. Set a new password if one is lost. Router backups and downloaded iOS and Android profiles contain secrets; keep them like a password.'),
					E('div', {}, [
						customMode ? E('div', {
							'class': 'ikev2-note warn',
							'style': 'margin-bottom:1rem'
						}, [ _('Individual access policies are stored but are not enforced while a custom inbound profile is active.') ]) : '',
						list,
						E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
							actionResult.node,
							disconnectAll,
							add
						])
					]),
					E('div', { 'class': 'ikev2-actions' }, [
						userCount,
						onlineCount
					])),
				common.section(_('Inbound connection diagnostics'),
					_('Capture a short, separate strongSwan trace while the affected client tries to connect. The capture stops automatically and does not increase system-log verbosity.'),
					E('div', {}, [
						diagnosticReport,
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
							diagnosticResult.node,
							diagnosticButton
						])
					]))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
