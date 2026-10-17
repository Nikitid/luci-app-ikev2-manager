'use strict';
'require view';
'require ikev2-manager.shared-v20 as common';
'require ikev2-manager.outbound-panel-v4 as outbound';
'require ikev2-manager.inbound-panel-v4 as inbound';

// The tunnels the router opens and the server it runs, on one page under two
// tabs. Each is a panel of its own; this page only puts them side by side and
// remembers which one was open.
return view.extend({
	load: function() {
		return Promise.all([ outbound.load(), inbound.load() ]);
	},

	render: function(data) {
		var title = _('Tunnels');
		var about = _('The tunnels this router opens to VPN servers, and the server it runs for the devices that connect to it.');
		var out = outbound.parts(data[0]), server = inbound.parts(data[1]);
		if (out.unavailable || server.unavailable)
			return E([ common.styles(), common.gate(title, about) ]);

		// The main tunnel, one tab for each extra one and a "+" to add one, then
		// the inbound server set apart. The server is reached by its own address
		// as well, and a reload returns to the tab that was open.
		var where = (typeof window !== 'undefined' && window.location) || {};
		var serverOpen = /\/server\/?$/.test(where.pathname || '') || where.hash === '#inbound';
		var tunnelHash = /^#tunnel-[2-7]$/.test(where.hash || '') ? where.hash.slice(1) : null;
		// The state in the header is the main tunnel's: shown on its tab only.
		function shown(index, item) {
			var server = !!item && item.id === 'inbound';
			out.pill.style.display = item && item.id === 'tunnel-1' ? '' : 'none';
			if (typeof window !== 'undefined' && window.history && window.history.replaceState && item)
				window.history.replaceState(null, '', server ? '#inbound' : '#' + item.id);
		}
		var panels = common.tabs([
			{ id: 'tunnel-1', title: _('Main tunnel'), content: E('div', {}, out.tunnel) }
		].concat(out.tunnels.panels()), {
			bare: true,
			openId: serverOpen ? 'inbound' : (tunnelHash || 'tunnel-1'),
			trailing: [ { id: 'inbound', title: _('Inbound server'), content: E('div', {}, server.server) } ],
			add: { label: _('Add tunnel'), click: out.tunnels.add },
			onShow: shown
		});
		panels.setAddDisabled(out.tunnels.full());
		out.tunnels.watch(function(list, select, full) {
			panels.setTabs(1, list, select);
			panels.setAddDisabled(full);
		});
		out.pill.style.display = serverOpen || tunnelHash ? 'none' : '';

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [ common.header(title, about, out.pill), panels ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
