// Dedicated managed-service proxy: no ordinary traffic or direct fallback.
'use strict';
import { allocate_client_catalog, compile_client_policy, client_names_plan } from './client-access.uc';

// The file a service's current devices are listed in. The controller rewrites
// it as devices come and go; the proxy rereads it without restarting.
export function client_sources_file(directory, service) {
	return `${directory}/src-${service}.json`;
};

// Loopback ports of the names-over-HTTPS path: where the proxy answers the
// front, and where the front listens with the server's certificate.
export const CLIENT_NAMES_LOCAL_PORT = 17897;
export const CLIENT_NAMES_HTTPS_PORT = 17898;

// The names handed out to devices, kept on flash beside the client state: a
// device holds an address for as long as its own cache says, and after a
// reboot of the router that address must still mean the same name. In memory
// the table was gone with every reboot and such an address reached nothing.
export const CLIENT_NAMES_DB = '/etc/ikev2-manager/clients/names.db';

// Where each published service leaves: the tunnel Policy Routing gives it,
// and the exit chosen for remote clients for a service Policy Routing does not
// send through a tunnel. EXITS is { links: { token: link or null },
// services: { id: token } }; a token whose link is null has no tunnel that may
// carry it now - one bound to a tunnel that is down - and its services are
// refused rather than sent another way.
function client_path_exits(exits, publication, exit_link) {
	let links = {}, services = {};
	links[publication.exit] = exit_link;
	if (exits == null) return { links: links, services: services };
	if (type(exits) != 'object' || type(exits.links) != 'object' || type(exits.services) != 'object' ||
		length(keys(exits)) != 2) die('invalid client path exits');
	for (let token, link in exits.links) {
		if (!match(token, /^[1-7]s?$/)) die('invalid client path exit');
		if (link != null && (type(link) != 'string' || !match(link, /^ipsec-out([2-9]|[1-9][0-9])?$/)))
			die('invalid client path exit link');
		if (token != publication.exit) links[token] = link;
	}
	for (let id, token in exits.services) {
		if (!(length(id) <= 48 ? match(id, /^[a-z0-9][a-z0-9_-]*$/) : null) || type(token) != 'string' || !(token in links))
			die('invalid client path service exit');
		services[id] = token;
	}
	return { links: links, services: services };
}

function exit_tag(token, publication) {
	return token == publication.exit ? 'managed-exit' : `exit-${token}`;
}

export function compile_client_path(input) {
	let names = [ 'version', 'state', 'exit_link', 'dns_address', 'dns_port', 'listen_port', 'runtime_dir' ];
	if (type(input) == 'object' && 'exits' in input) push(names, 'exits');
	if (type(input) != 'object' || length(keys(input)) != length(names))
		die('invalid client path input');
	for (let name in names)
		if (!(name in input)) die('missing client path input');
	if (input.version !== 1 || type(input.exit_link) != 'string' ||
		!match(input.exit_link, /^ipsec-out([2-9]|[1-9][0-9])?$/))
		die('invalid managed exit interface');
	let parts = split(input.dns_address ?? '', '.');
	if (length(parts) != 4) die('invalid tunnel resolver');
	for (let part in parts)
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || +part > 255)
			die('invalid tunnel resolver');
	if (+parts[0] == 0 || +parts[0] == 127 || +parts[0] >= 224)
		die('invalid tunnel resolver');
	for (let port in [ input.dns_port, input.listen_port ])
		if (type(port) != 'int' || port < 1 || port > 65535)
			die('invalid client path port');
	if (type(input.runtime_dir) != 'string' || !(length(input.runtime_dir) <= 201 ? match(input.runtime_dir, /^\/[A-Za-z0-9._\/-]+$/) : null) || index(input.runtime_dir, '..') >= 0)
		die('invalid runtime directory');
	// A snapshot the publisher committed: its services are checked below once
	// more as they are compiled; its devices are not compiled again every two seconds.
	let state = input.state, publication = state?.publication;
	if (type(publication) != 'object' || type(state.generation) != 'int') die('invalid client path state');
	let selected = map(filter(publication.services, service => service.client_access), service => service.id);
	let catalog = allocate_client_catalog({ version: 1, virtual_subnet: publication.virtual_subnet,
		services: publication.services, allocations: publication.allocations, selected_services: selected });
	let exits = client_path_exits(input.exits, publication, input.exit_link);
	// The exit of each name: that of the first service, by identifier, that
	// holds it. A name two services share leaves the way the first one does.
	let name_exit = {};
	for (let service in sort(filter(publication.services, s => s.client_access), (a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
		for (let name in service.domains)
			if (!(name in name_exit)) name_exit[name] = exits.services[service.id] ?? publication.exit;
	// A rule towards a service whose exit cannot carry it now is a refusal.
	function leave(rule, token) {
		if (exits.links[token] == null) { delete rule.outbound; delete rule.override_address; rule.action = 'reject'; rule.method = 'drop'; }
		else rule.outbound = exit_tag(token, publication);
		return rule;
	}
	let rules = [ { inbound: [ 'tproxy-client-access-in' ], action: 'reject', method: 'drop' } ];
	if (length(catalog.resources)) {
		let policy = { version: 1, id: 'router', revision: state.generation,
			server: publication.server, virtual_subnet: publication.virtual_subnet,
			exit: publication.exit, resources: catalog.resources };
		rules = compile_client_policy(policy).router_rules;
		for (let rule in rules)
			if (rule.action == 'route') leave(rule, name_exit[rule.override_address] ?? publication.exit);
	}
	let subnet = publication.virtual_subnet, layout = client_names_plan(subnet);
	// Names. A device asks the resolver address through its tunnel; a name
	// under a domain of a service the device was assigned gets an address from
	// the upper half, and the proxy remembers which name it stands for. Any
	// other name, and any other device, is refused. The connection that then
	// arrives at that address is let through only for the same device, on the
	// service's ports, and leaves by name through the required exit.
	let published = filter(publication.services, service => service.client_access && length(service.domains));
	let sets = [], dns_rules = [], named = [];
	for (let service in published) {
		let tag = `src-${service.id}`, suffixes = map(service.domains, name => '.' + name);
		push(sets, { type: 'local', tag: tag, format: 'source', path: client_sources_file(input.runtime_dir, service.id) });
		push(dns_rules, { inbound: [ 'tproxy-client-access-in' ], rule_set: [ tag ], rule_set_ip_cidr_match_source: true,
			domain: service.domains, domain_suffix: suffixes, query_type: [ 'A' ], action: 'route', server: 'managed-names' });
		// Every other record type of such a name exists and is empty, so
		// nothing looks elsewhere for an IPv6 address or a service binding.
		push(dns_rules, { inbound: [ 'tproxy-client-access-in' ], rule_set: [ tag ], rule_set_ip_cidr_match_source: true,
			domain: service.domains, domain_suffix: suffixes, action: 'predefined', rcode: 'NOERROR' });
		for (let transport in service.transports)
			push(named, leave({ inbound: [ 'tproxy-client-access-in' ], rule_set: [ tag ], rule_set_ip_cidr_match_source: true,
				domain: service.domains, domain_suffix: suffixes,
				network: [ transport.protocol ], port: transport.ports, action: 'route', outbound: 'managed-exit' },
				exits.services[service.id] ?? publication.exit));
	}
	push(dns_rules, { inbound: [ 'tproxy-client-access-in' ], action: 'predefined', rcode: 'REFUSED' });
	// Networks. Admission marks only a device's own networks on their ports,
	// and only those reach the proxy; each leaves by its service's exit.
	let networked = filter(publication.services, service => service.client_access && length(service.networks ?? []));
	let reached = [];
	for (let service in networked)
		for (let transport in service.transports)
			push(reached, leave({ inbound: [ 'tproxy-client-access-in' ], ip_cidr: service.networks,
				network: [ transport.protocol ], port: transport.ports, action: 'route', outbound: 'managed-exit' },
				exits.services[service.id] ?? publication.exit));
	// Names over HTTPS. A device may ask the same resolver address on port 443
	// instead: another VPN on the device that blocks every plain DNS query but
	// its own lets this through. The connection is handed to the front that
	// holds the server's certificate, and the front asks here. Who asked is no
	// longer known at that point, so a published name is answered to any
	// admitted device; whether that device may then reach it is decided, as
	// before, when its connection arrives.
	for (let service in published) {
		let suffixes = map(service.domains, name => '.' + name);
		push(dns_rules, { inbound: [ 'names-local-in' ], domain: service.domains, domain_suffix: suffixes, query_type: [ 'A' ], action: 'route', server: 'managed-names' });
		push(dns_rules, { inbound: [ 'names-local-in' ], domain: service.domains, domain_suffix: suffixes, action: 'predefined', rcode: 'NOERROR' });
	}
	push(dns_rules, { inbound: [ 'names-local-in' ], action: 'predefined', rcode: 'REFUSED' });
	let closing = pop(rules);
	rules = [ { inbound: [ 'tproxy-client-access-in' ], ip_cidr: [ layout.resolver + '/32' ], port: [ 53 ], action: 'hijack-dns' },
		{ inbound: [ 'names-local-in' ], action: 'hijack-dns' },
		{ inbound: [ 'tproxy-client-access-in' ], ip_cidr: [ layout.resolver + '/32' ], network: [ 'tcp' ], port: [ 443 ], action: 'route',
			outbound: 'names-front', override_address: '127.0.0.1', override_port: CLIENT_NAMES_HTTPS_PORT },
		...rules, ...named, ...reached, closing ];
	// Admission (-165) precedes interception (-154). A missing local route or
	// listener cannot forward virtual destinations through an unrelated route.
	let nft = `table inet ikev2_client_path {
  chain ikev2_manager_owned { }
  chain prerouting {
    type filter hook prerouting priority -154; policy accept;
    iifname "ipsec-in" ip daddr ${subnet} meta mark == 0x00800000 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${input.listen_port} counter accept
${length(reached) ? `    iifname "ipsec-in" ip daddr != ${subnet} meta mark == 0x00800000 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${input.listen_port} counter accept\n` : ''}    ip daddr ${subnet} counter drop
  }
  chain forward {
    type filter hook forward priority -165; policy accept;
    ip daddr ${subnet} counter drop
  }
  chain output {
    type filter hook output priority -154; policy accept;
    ip saddr ${subnet} meta mark != 0x00800000 counter drop
  }
  chain input {
    type filter hook input priority -165; policy accept;
    ip daddr ${subnet} meta mark != 0x00800000 counter drop
  }
}
`;
	// Every other exit a service leaves by has its own way out and resolves the
	// names it carries through its own tunnel.
	let extra_servers = [], extra_outbounds = [];
	for (let token in sort(keys(exits.links))) {
		if (token == publication.exit || exits.links[token] == null) continue;
		push(extra_servers, { type: 'tcp', tag: `dns-${token}`, server: input.dns_address,
			server_port: input.dns_port, bind_interface: exits.links[token] });
		push(extra_outbounds, { type: 'direct', tag: exit_tag(token, publication), bind_interface: exits.links[token],
			domain_resolver: { server: `dns-${token}`, strategy: 'ipv4_only' } });
	}
	return { version: 1, generation: state.generation, virtual_subnet: subnet,
		exit: publication.exit, exit_link: input.exit_link, mark: '0x00800000',
		exits: exits,
		route: { priority: 10998, table: 1506, ingress: 'ipsec-in', destination: subnet },
		// Networks reach the proxy by the admission mark: a rule of its own
		// before the subnet's, into a table that is local for everything.
		networks_route: length(reached) ? { priority: 10997, table: 1507, ingress: 'ipsec-in', mark: '0x00800000' } : null,
		nft: nft,
		config: {
			log: { level: 'warn' },
			dns: { servers: [ { type: 'tcp', tag: 'managed-dns', server: input.dns_address,
				server_port: input.dns_port, bind_interface: input.exit_link },
				{ type: 'fakeip', tag: 'managed-names', inet4_range: layout.range }, ...extra_servers ],
				rules: dns_rules, final: 'managed-dns', strategy: 'ipv4_only' },
			inbounds: [ { type: 'tproxy', tag: 'tproxy-client-access-in',
				listen: '127.0.0.1', listen_port: input.listen_port },
				{ type: 'direct', tag: 'names-local-in', listen: '127.0.0.1', listen_port: CLIENT_NAMES_LOCAL_PORT } ],
			outbounds: [ { type: 'direct', tag: 'managed-exit', bind_interface: input.exit_link,
				domain_resolver: { server: 'managed-dns', strategy: 'ipv4_only' } },
				// It is only ever given a literal loopback address; the proxy asks
				// every outbound to name its resolver all the same.
				{ type: 'direct', tag: 'names-front', domain_resolver: { server: 'managed-dns', strategy: 'ipv4_only' } },
				...extra_outbounds ],
			route: { rule_set: sets, rules: rules, final: 'managed-exit' },
			// The names handed out survive a restart of the proxy, so an
			// address a device still holds keeps meaning the same name.
			experimental: { cache_file: { enabled: true, path: CLIENT_NAMES_DB, store_fakeip: true } }
		},
		services: map(published, service => service.id)
	};
};
