'use strict';
'require baseclass';
'require fs';
'require ikev2-manager.shared-v13 as common';

var helper = '/usr/libexec/ikev2-manager';
var swanmon = '/usr/sbin/swanmon';

function failed(response) {
	return !response || (response.code != null && Number(response.code) !== 0);
}

function findOutbound(sas) {
	for (var i = 0; i < sas.length; i++) {
		if (sas[i]['proxy-out'])
			return sas[i]['proxy-out'];
	}
	return null;
}

function installedChild(sa, name) {
	return Object.values((sa && sa['child-sas']) || {}).find(function(child) {
		return child.state === 'INSTALLED' && (!name || child.name === name);
	}) || null;
}

function activeInboundSessions(sas) {
	var sessions = [];

	sas.forEach(function(item) {
		var sa = item['ikev2-in'];
		if (!sa || sa.state !== 'ESTABLISHED')
			return;

		var children = Object.values(sa['child-sas'] || {}).filter(function(child) {
			return child.state === 'INSTALLED';
		});
		if (!children.length)
			return;

		var bytesIn = 0;
		var bytesOut = 0;
		children.forEach(function(child) {
			bytesIn += Number(child['bytes-in'] || 0);
			bytesOut += Number(child['bytes-out'] || 0);
		});

		sessions.push({
			user: sa['remote-eap-id'] || sa['remote-id'] || _('Unknown'),
			vips: sa['remote-vips'] || [],
			established: Number(sa.established || 0),
			// Counters are relative to the router: bytes-out are downloaded by
			// the remote client and bytes-in are uploaded by it.
			bytesReceived: bytesOut,
			bytesSent: bytesIn
		});
	});

	return sessions.sort(function(left, right) {
		return left.user.localeCompare(right.user) ||
			String(left.vips[0] || '').localeCompare(String(right.vips[0] || ''));
	});
}

function traffic(direction, bytes, label) {
	return E('span', {
		'class': 'ikev2-traffic ' + direction,
		'title': label
	}, [
		common.icon(direction === 'received' ? 'down' : 'up'),
		common.formatBytes(bytes)
	]);
}

function sessionCard(session) {
	var address = session.vips.length ? session.vips.join(', ') : _('Address unavailable');

	return E('div', { 'class': 'ikev2-widget-client' }, [
		E('div', { 'class': 'ikev2-user-identity' }, [
			E('span', { 'class': 'ikev2-user-avatar' }, [
				session.user.charAt(0) || '?'
			]),
			E('span', { 'class': 'ikev2-widget-client-name' }, [
				E('strong', { 'class': 'ikev2-user-name' }, [ session.user ]),
				E('span', { 'class': 'ikev2-widget-address' }, [ address ])
			])
		]),
		E('span', { 'class': 'ikev2-widget-duration' }, [
			_('Online for %s').format(common.formatDuration(session.established))
		]),
		E('span', { 'class': 'ikev2-widget-traffic' }, [
			traffic('received', session.bytesReceived, _('Received')),
			traffic('sent', session.bytesSent, _('Sent'))
		])
	]);
}

function componentCard(label, state, detail, meta) {
	return E('div', { 'class': 'ikev2-widget-component' }, [
		E('div', { 'class': 'ikev2-widget-component-label' }, [ label ]),
		E('div', { 'class': 'ikev2-widget-component-head' }, [
			common.pill(state.label, state.tone)
		]),
		detail ? E('div', { 'class': 'ikev2-widget-component-detail' }, detail) : '',
		meta ? E('div', { 'class': 'ikev2-widget-component-meta' }, meta) : ''
	]);
}

function outboundComponent(statusAvailable, status, sasAvailable, sas) {
	if (!statusAvailable) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Connection state is unavailable.') ])
		};
	}
	if (status.client_enabled !== '1') {
		return {
			issue: false,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Disabled'), tone: 'neutral' },
				[ _('Outbound client is disabled.') ])
		};
	}
	if (!sasAvailable) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Connection state is unavailable.') ])
		};
	}

	var outbound = findOutbound(sas);
	var child = outbound && outbound.state === 'ESTABLISHED' ?
		installedChild(outbound, 'proxy4') : null;
	if (!child) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Disconnected'), tone: 'bad' },
				[ _('No installed outbound CHILD_SA.') ])
		};
	}

	var interfacePresent = status.interface_present === '1';
	var down = Number(status.interface_bytes_in || 0);
	var up = Number(status.interface_bytes_out || 0);
	var counterAge = _('Since ipsec-out was created');
	return {
		issue: false,
		node: componentCard(_('Outbound tunnel'),
			{ label: _('Connected'), tone: 'good' },
			[ _('Online for %s').format(common.formatDuration(outbound.established)) ],
			interfacePresent ? [
				traffic('received', down, _('Downloaded') + ' · ' + counterAge),
				traffic('sent', up, _('Uploaded') + ' · ' + counterAge)
			] : [
				E('span', {}, [ _('ipsec-out is unavailable') ])
			])
	};
}

function policyComponent(statusAvailable, status) {
	if (!statusAvailable) {
		return {
			issue: true,
			node: componentCard(_('Policy routing'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Routing state is unavailable.') ])
		};
	}
	if (status.configured !== '1') {
		return {
			issue: false,
			node: componentCard(_('Policy routing'),
				{ label: _('Disabled'), tone: 'neutral' },
				[ _('Managed routing is disabled.') ])
		};
	}

	var pbrReady = (status.routing || status.pbr) === 'running';
	var failClosed = status.killswitch === 'active';
	var fakeIp = status.domain_engine === 'fakeip';
	var reliable = fakeIp && status.domain_service === 'running' &&
		status.domain_healthy === 'yes' && status.domain_data_plane !== 'degraded';
	var state;

	if (!pbrReady)
		state = { label: _('Routing stopped'), tone: 'bad' };
	else if (!failClosed)
		state = { label: _('Fail-closed missing'), tone: 'bad' };
	else if (fakeIp && !reliable)
		state = { label: _('Reliable mode degraded'), tone: 'bad' };
	else if (fakeIp)
		state = { label: _('Reliable mode active'), tone: 'good' };
	else
		state = { label: _('Matching by address'), tone: 'info' };

	var counts = _('%d domains').format(Number(status.pbr_domains || 0)) +
		' · ' + _('%d service groups').format(Number(status.community_services || 0));
	var addressCount = Number(status.manual_addresses || 0);
	if (addressCount)
		counts += ' · ' + _('%d address rules').format(addressCount);
	var excludedDevices = Number(status.device_excluded || 0);
	if (excludedDevices)
		counts += ' · ' + _('%d excluded devices').format(excludedDevices);
	var bypasses = Number(status.device_dns_passthrough || 0) +
		Number(status.device_dpi_passthrough || 0);
	if (bypasses)
		counts += ' · ' + _('%d bypass settings').format(bypasses);
	var excludedTraffic = Number(status.device_excluded_bytes || 0);

	return {
		issue: !pbrReady || !failClosed || (fakeIp && !reliable),
		node: componentCard(_('Policy routing'), state, [ counts ], [
			E('span', {}, [
				pbrReady ? _('Routing running') : _('Routing stopped')
			]),
			E('span', {}, [
				failClosed ? _('Fail-closed active') : _('Fail-closed missing')
			]),
			excludedDevices ? E('span', {}, [
				_('Excluded traffic: %s').format(common.formatBytes(excludedTraffic))
			]) : ''
		])
	};
}

function inboundComponent(statusAvailable, status, sessionsAvailable, sessions) {
	if (!statusAvailable) {
		return {
			issue: true,
			node: componentCard(_('Inbound server'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Server state is unavailable.') ])
		};
	}
	if (status.server_enabled !== '1') {
		return {
			issue: false,
			node: componentCard(_('Inbound server'),
				{ label: _('Disabled'), tone: 'neutral' },
				[ _('Inbound server is disabled.') ])
		};
	}

	var loaded = status.inbound_conn_loaded === '1' &&
		status.inbound_pool_loaded === '1';
	var issue = !loaded || !sessionsAvailable;
	var state = issue ?
		{ label: _('Server degraded'), tone: 'bad' } :
		{ label: _('Server ready'), tone: 'good' };
	var detail = sessionsAvailable ?
		_('%d active sessions').format(sessions.length) :
		_('Inbound session data is unavailable.');

	return {
		issue: issue,
		node: componentCard(_('Inbound server'), state, [ detail ])
	};
}

return baseclass.extend({
	title: 'IKEv2 Manager',

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'widget-status' ]), {
				code: 1,
				stdout: ''
			}),
			L.resolveDefault(fs.exec(swanmon, [ 'list-sas' ]), {
				code: 1,
				stdout: ''
			})
		]);
	},

	render: function(data) {
		var statusAvailable = data && !failed(data[0]);
		var sasAvailable = data && !failed(data[1]);
		var status = statusAvailable ? common.parseKeyValues(data[0].stdout) : {};
		var sas = sasAvailable ? common.parseSwanmon(data[1]) : [];
		var sessions = sasAvailable ? activeInboundSessions(sas) : [];
		var outbound = outboundComponent(statusAvailable, status, sasAvailable, sas);
		var policy = policyComponent(statusAvailable, status);
		var inbound = inboundComponent(statusAvailable, status, sasAvailable, sessions);
		var projectState;

		if (!statusAvailable) {
			projectState = {
				label: _('Project status is unavailable.'),
				tone: 'bad'
			};
		}
		else if (status.configured !== '1') {
			projectState = {
				label: _('Not configured'),
				tone: 'neutral'
			};
		}
		else if (outbound.issue || policy.issue || inbound.issue ||
				(status.client_enabled === '1' && status.health !== 'up')) {
			projectState = {
				label: _('Action required'),
				tone: 'bad'
			};
		}
		else {
			projectState = {
				label: _('Operational'),
				tone: 'good'
			};
		}

		var clients = sessions.length ? E('div', {
			'class': 'ikev2-widget-clients'
		}, [
			E('div', { 'class': 'ikev2-widget-clients-head' }, [
				E('strong', {}, [ _('Active inbound clients') ]),
				common.pill(_('%d active sessions').format(sessions.length), 'good')
			]),
			E('div', { 'class': 'ikev2-widget-client-list' },
				sessions.map(sessionCard))
		]) : '';

		return E('div', {}, [
			common.styles(),
			E('div', { 'class': 'ikev2-page ikev2-status-widget' }, [
				E('div', { 'class': 'ikev2-widget-summary' }, [
					E('span', { 'class': 'ikev2-widget-summary-label' }, [
						_('Project status')
					]),
					common.pill(projectState.label, projectState.tone)
				]),
				E('div', { 'class': 'ikev2-widget-overview' }, [
					outbound.node,
					policy.node,
					inbound.node
				]),
				clients,
				E('div', { 'class': 'ikev2-widget-footer' }, [
					E('a', {
						'class': 'ikev2-quick-link',
						'href': L.url('admin', 'services', 'ikev2-manager', 'setup')
					}, [ _('Open IKEv2 Manager') ])
				])
			])
		]);
	}
});
