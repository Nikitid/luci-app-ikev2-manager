'use strict';
'require view';
'require ikev2-manager.shared-v24 as common';
'require ikev2-manager.outbound-panel-v7 as outbound';

// DNS on a page of its own: the resolver behind the tunnel, the router's
// public upstream and the resolver groups for chosen suffixes. The panel that
// owns these settings builds them; this page shows that part alone.
return view.extend(common.shell(_('DNS'),
	_('How names are resolved: through the tunnel for what is routed there, the public upstream for everything else, and resolver groups of their own for chosen suffixes.'), {
	loadData: function() {
		return outbound.load();
	},

	renderData: function(data) {
		var title = _('DNS');
		var about = _('How names are resolved: through the tunnel for what is routed there, the public upstream for everything else, and resolver groups of their own for chosen suffixes.');
		var parts = outbound.parts(data);
		if (parts.unavailable)
			return E([ common.styles(), common.gate(title, about) ]);
		// The global settings, then one tab per destination segment, and a "+"
		// at the end of the row that opens a new one.
		var ids = [ 'tunnel', 'upstream' ];
		var titles = [ _('Tunnel DNS'), _('Router DNS upstream') ];
		var panels = common.tabs(parts.dns.map(function(node, index) {
			return { id: ids[index], title: titles[index] || '', content: node };
		}).concat(parts.segments.panels()), {
			key: 'dns',
			split: ids.length,
			add: { label: _('Add DNS segment'), click: parts.segments.add }
		});
		parts.segments.watch(function(list, select) {
			panels.setTabs(ids.length, list, select);
		});
		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [ common.header(title, about), parts.dnsNote || '', panels ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
}));
