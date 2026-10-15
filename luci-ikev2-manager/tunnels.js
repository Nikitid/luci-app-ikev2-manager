'use strict';
'require view';
'require ikev2-manager.shared-v18 as common';
'require ikev2-manager.outbound-panel-v3 as outbound';
'require ikev2-manager.inbound-panel-v3 as inbound';

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

		// The inbound server is reached by its own address as well, and a
		// reload returns to the tab that was open.
		var where = (typeof window !== 'undefined' && window.location) || {};
		var open = /\/server\/?$/.test(where.pathname || '') || where.hash === '#inbound' ? 1 : 0;
		function shown(index) {
			out.pill.style.display = index === 0 ? '' : 'none';
			if (typeof window !== 'undefined' && window.history && window.history.replaceState)
				window.history.replaceState(null, '', index === 1 ? '#inbound' : '#outbound');
		}
		var panels = common.tabs([
			{ title: _('Outbound tunnels'), content: E('div', {}, out.tunnel) },
			{ title: _('Inbound server'), content: E('div', {}, server.server) }
		], { bare: true, open: open, onShow: shown });
		out.pill.style.display = open === 0 ? '' : 'none';

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [ common.header(title, about, out.pill), panels ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
