'use strict';
'require view';
'require ikev2-manager.shared-v20 as common';
'require ikev2-manager.outbound-panel-v4 as outbound';

// DNS on a page of its own: the resolver behind the tunnel, the router's
// public upstream and the resolver groups for chosen suffixes. The panel that
// owns these settings builds them; this page shows that part alone.
return view.extend({
	load: function() {
		return outbound.load();
	},

	render: function(data) {
		var title = _('DNS');
		var about = _('How names are resolved: through the tunnel for what is routed there, the public upstream for everything else, and resolver groups of their own for chosen suffixes.');
		var parts = outbound.parts(data);
		if (parts.unavailable)
			return E([ common.styles(), common.gate(title, about) ]);
		// Three subjects of their own, one shown at a time.
		var ids = [ 'tunnel', 'upstream', 'segments' ];
		var titles = [ _('Tunnel DNS'), _('Router DNS upstream'), _('Destination DNS segments') ];
		var panels = common.tabs(parts.dns.map(function(node, index) {
			return { id: ids[index], title: titles[index] || '', content: node };
		}), { key: 'dns' });
		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [ common.header(title, about), panels ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
