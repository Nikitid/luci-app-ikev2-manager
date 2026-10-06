// The sing-box configuration of the FakeIP engine.
//
//   singbox-config.uc render <INPUT       prints the configuration
//   singbox-config.uc probe <INPUT        prints a tunnel DNS probe worker's
//   singbox-config.uc equal FILE FILE     whether two configurations match
//   singbox-config.uc stale FILE <SETS    prints the connections to close
//
// The shell side validates every value and passes them as "key<TAB>value"
// lines; this builds the document. It used to be one heredoc with the values
// spliced in as text, so an unexpected character in any of them produced a
// file sing-box could not parse, or one that parsed into something else.
//
// Keys: log_level ttl cache_capacity cache_path upstream_host upstream_port
// bootstrap_host bootstrap_port doh_host doh_port doh_path fakeip_range
// final_server dns_address dns_port tproxy_address tproxy_port
// direct_tproxy_port router_tproxy_port controller_address controller_secret
// ruleset_path, and optionally https_all 1 and bypass_ruleset_path, the
// domains never to go through the tunnel. Repeated: covered CIDR,
// https_suffix SUFFIX, and segment TAG PORT SUFFIX... in routing order;
// tunnel INDEX LINK for each enabled outbound tunnel; exit INDEX TUNNEL...
// with the tunnels each exit may use, preferred first; exit_rules INDEX PATH,
// the rule set of the names an exit after the first carries; exit_port INDEX
// PORT, the TProxy port of the devices sent whole through that exit.
//
// With one tunnel the configuration is the one there always was, bound to
// that tunnel's link. With more, every tunnel has its own outbound and its
// own resolvers bound to its link, so a name is resolved through the tunnel
// that carries the connection, and each exit is a selector over its tunnels.
// A selector starts on its first tunnel; the watcher moves it through the
// controller, so a failover does not change this document.

'use strict';

import { stdin, readfile } from 'fs';
import { compile_client_policy } from './client-access.uc';

function die(message) {
	warn(`singbox-config: ${message}\n`);
	exit(1);
}

function port(value, name) {
	if (!match(value ?? '', /^[0-9]+$/) || +value < 1 || +value > 65535)
		die(`invalid ${name}: ${value}`);
	return +value;
}

function count(value, name) {
	if (!match(value ?? '', /^[0-9]+$/))
		die(`invalid ${name}: ${value}`);
	return +value;
}

function read_input() {
	let input = { covered: [], https_suffix: [], segment: [], tunnel: [], exit: [], exit_rules: [], exit_port: [] };
	for (let line in split(stdin.read('all') ?? '', '\n')) {
		if (line == '')
			continue;
		let fields = split(line, '\t');
		let key = fields[0];
		if (key == 'covered' || key == 'https_suffix')
			push(input[key], fields[1]);
		else if (key == 'segment')
			push(input.segment, { tag: fields[1], port: fields[2], suffixes: slice(fields, 3) });
		else if (key == 'tunnel')
			push(input.tunnel, { index: fields[1], link: fields[2] });
		else if (key == 'exit')
			push(input.exit, { index: fields[1], tunnels: slice(fields, 2) });
		else if (key == 'exit_rules')
			push(input.exit_rules, { index: fields[1], path: fields[2] });
		else if (key == 'exit_port')
			push(input.exit_port, { index: fields[1], port: fields[2] });
		else
			input[key] = fields[1];
	}
	return input;
}

function required(input, key) {
	let value = input[key];
	if (type(value) != 'string' || value == '')
		die(`missing ${key}`);
	return value;
}

function tunnel_index(value) {
	if (!match(value ?? '', /^[1-7]$/))
		die(`invalid tunnel: ${value}`);
	return value;
}

// An exit is a tunnel index, with "s" for the one that never moves to
// another tunnel: its selector holds that tunnel alone.
function exit_index(value) {
	if (!match(value ?? '', /^[1-7]s?$/))
		die(`invalid exit: ${value}`);
	return value;
}

function link_name(value) {
	if (!match(value ?? '', /^ipsec-out[2-7]?$/))
		die(`invalid tunnel link: ${value}`);
	return value;
}

// Tags of one tunnel's outbound and resolvers. The first keeps the names it
// always had.
function tunnel_tag(base, index) {
	return index == '1' ? base : `${base}-${index}`;
}

function tunnel_resolvers(input, index, link) {
	let bootstrap = tunnel_tag('ikev2-bootstrap', index);
	return [
		// The tunnel bootstrap uses TCP. sing-box keeps one shared UDP socket
		// per server and replaces it only on a read or write error, never on
		// a timeout; one opened while the link had no address kept the WAN
		// source and failed silently until a restart. TCP picks the current
		// source on every query.
		{
			type: 'tcp',
			tag: bootstrap,
			server: required(input, 'bootstrap_host'),
			server_port: port(input.bootstrap_port, 'bootstrap port'),
			bind_interface: link
		},
		{
			type: 'https',
			tag: tunnel_tag('ikev2-upstream', index),
			server: required(input, 'doh_host'),
			server_port: port(input.doh_port, 'tunnel DNS port'),
			path: required(input, 'doh_path'),
			tls: {
				enabled: true,
				server_name: input.doh_host
			},
			bind_interface: link,
			domain_resolver: {
				server: bootstrap,
				strategy: 'ipv4_only'
			},
			connect_timeout: '5s'
		}
	];
}

function tunnel_outbound(index, link) {
	return {
		type: 'direct',
		tag: tunnel_tag('ikev2-out', index),
		bind_interface: link,
		domain_resolver: {
			server: tunnel_tag('ikev2-upstream', index),
			strategy: 'ipv4_only'
		}
	};
}

function flatten(lists) {
	let out = [];
	for (let list in lists)
		push(out, ...list);
	return out;
}

function render(input) {
	let domains = [ 'ikev2-domains' ];
	let tunnels = map(input.tunnel, (t) => ({ index: tunnel_index(t.index), link: link_name(t.link) }));
	let several = length(tunnels) > 1;
	// One tunnel, or none enabled: the layout there always was, on that
	// tunnel's link.
	if (!several)
		tunnels = [ { index: '1', link: length(tunnels) ? tunnels[0].link : 'ipsec-out' } ];
	let servers = [
		{
			type: 'udp',
			tag: 'upstream',
			server: required(input, 'upstream_host'),
			server_port: port(input.upstream_port, 'upstream port')
		}
	];
	let outbounds = [
		{
			type: 'direct',
			tag: 'direct-out',
			domain_resolver: 'upstream'
		}
	];
	for (let t in tunnels) {
		push(servers, ...tunnel_resolvers(input, t.index, t.link));
		push(outbounds, tunnel_outbound(t.index, t.link));
	}
	// Where an exit's traffic leaves: with one tunnel that tunnel, when it
	// serves the exit; with more the selector that stands another in for it;
	// with none, nowhere - the connection is refused, it never goes direct.
	let chains = {};
	for (let e in input.exit)
		chains[exit_index(e.index)] = e.tunnels;
	let exit_out = (exit) => {
		if (several)
			return length(filter(outbounds, (o) => o.tag == `exit-${exit}`)) ? `exit-${exit}` : null;
		// Input without exits is the layout there always was.
		if (!length(input.exit))
			return 'ikev2-out';
		return index(chains[exit] ?? [], tunnels[0].index) >= 0 ? 'ikev2-out' : null;
	};
	let to = (outbound) => outbound ? { action: 'route', outbound: outbound } : { action: 'reject' };
	let final_server = required(input, 'final_server');
	if (several) {
		let enabled = {};
		for (let t in tunnels)
			enabled[t.index] = true;
		for (let e in input.exit) {
			let members = [];
			for (let index in e.tunnels) {
				if (!enabled[tunnel_index(index)])
					die(`exit ${e.index} names a tunnel that is not enabled: ${index}`);
				push(members, tunnel_tag('ikev2-out', index));
			}
			if (length(members) == 0)
				continue;
			push(outbounds, {
				type: 'selector',
				tag: `exit-${exit_index(e.index)}`,
				outbounds: members,
				default: members[0],
				interrupt_exist_connections: true
			});
		}
		// Names resolved through the tunnel resolve through whichever tunnel
		// the first exit uses now, and over WAN while it has none, as they
		// do with the client disabled.
		if (final_server == 'ikev2-upstream' && !exit_out('1'))
			final_server = 'upstream';
		if (final_server == 'ikev2-upstream') {
			push(servers,
				{
					type: 'tcp',
					tag: 'exit-1-bootstrap',
					server: required(input, 'bootstrap_host'),
					server_port: port(input.bootstrap_port, 'bootstrap port'),
					detour: 'exit-1'
				},
				{
					type: 'https',
					tag: 'exit-1-dns',
					server: required(input, 'doh_host'),
					server_port: port(input.doh_port, 'tunnel DNS port'),
					path: required(input, 'doh_path'),
					tls: {
						enabled: true,
						server_name: input.doh_host
					},
					detour: 'exit-1',
					domain_resolver: {
						server: 'exit-1-bootstrap',
						strategy: 'ipv4_only'
					},
					connect_timeout: '5s'
				});
			final_server = 'exit-1-dns';
		}
	}
	let tunnel_out = exit_out('1');
	// Every exit's names get FakeIP addresses; each exit's own rule set routes
	// them, ahead of the first exit's.
	let exit_rule_sets = map(input.exit_rules, (e) => ({ index: exit_index(e.index), path: e.path }));
	for (let e in exit_rule_sets) {
		if (e.index == '1' || type(e.path) != 'string' || e.path == '')
			die(`invalid exit rule set: ${e.index}`);
		push(domains, `ikev2-domains-${e.index}`);
	}
	let exit_inbounds = map(input.exit_port, (e) => ({ index: exit_index(e.index), port: port(e.port, 'exit tproxy port') }));
	let access = null, access_port = null;
	if (input.client_access_policy) {
		let raw = readfile(input.client_access_policy);
		if (raw == null || length(raw) > 1048576)
			die('cannot read client access policy');
		access = compile_client_policy(json(raw));
		access_port = port(input.client_access_port, 'client access port');
		let reserved_ports = [ +input.dns_port, +input.tproxy_port,
			+input.direct_tproxy_port, +input.router_tproxy_port,
			...map(exit_inbounds, e => e.port) ];
		if (index(reserved_ports, access_port) >= 0)
			die('client access port conflicts with an existing listener');
		let outbound = !length(input.exit) && access.policy.exit != '1' && access.policy.exit != '1s'
			? null : exit_out(access.policy.exit);
		access.router_rules = map(access.router_rules, rule => {
			if (rule.action != 'route')
				return rule;
			if (outbound) {
				rule.outbound = outbound;
				return rule;
			}
			return { inbound: rule.inbound, action: 'reject', method: 'drop' };
		});
	}
	for (let segment in input.segment)
		push(servers, {
			type: 'udp',
			tag: segment.tag,
			server: '127.0.0.1',
			server_port: port(segment.port, 'DNS segment port')
		});
	push(servers, {
		type: 'fakeip',
		tag: 'fakeip',
		inet4_range: required(input, 'fakeip_range')
	});

	// Never through the tunnel: resolved for real over WAN, ahead of every
	// FakeIP rule, whatever selects the name.
	let bypass = input.bypass_ruleset_path ? [ 'ikev2-bypass' ] : null;
	let dns_rules = bypass ? [
		{
			rule_set: bypass,
			action: 'route',
			server: 'upstream'
		}
	] : [];
	push(dns_rules,
		{
			rule_set: domains,
			query_type: [ 'HTTPS' ],
			action: 'predefined',
			rcode: 'NOERROR'
		}
	);
	if (length(input.https_suffix) > 0)
		push(dns_rules, {
			domain_suffix: input.https_suffix,
			query_type: [ 'HTTPS' ],
			action: 'predefined',
			rcode: 'NOERROR'
		});
	push(dns_rules,
		{
			domain: [ 'use-application-dns.net' ],
			action: 'reject'
		},
		// iCloud Private Relay is off on a network that answers these names
		// as missing, which is how Apple has a network say so. dnsmasq
		// answers them first; this holds for a query that reaches here.
		{
			domain_suffix: [ 'mask.icloud.com', 'mask-h2.icloud.com' ],
			action: 'predefined',
			rcode: 'NXDOMAIN'
		},
		{
			rule_set: domains,
			query_type: [ 'AAAA' ],
			action: 'predefined',
			rcode: 'NOERROR'
		},
		{
			rule_set: domains,
			query_type: [ 'A' ],
			action: 'route',
			server: 'fakeip',
			rewrite_ttl: count(input.ttl, 'FakeIP TTL')
		}
	);
	for (let segment in input.segment) {
		if (length(segment.suffixes) == 0)
			die(`DNS segment has no suffixes: ${segment.tag}`);
		push(dns_rules, {
			domain_suffix: segment.suffixes,
			action: 'route',
			server: segment.tag
		});
	}
	// Browser compatibility for the ordinary names that pass through here.
	// Placed after the segments, which keep their own setting.
	if (input.https_all == '1')
		push(dns_rules, {
			query_type: [ 'HTTPS' ],
			action: 'predefined',
			rcode: 'NOERROR'
		});

	if (length(input.covered) == 0)
		die('no source networks');
	let tproxy = required(input, 'tproxy_address');

	return {
		log: {
			level: required(input, 'log_level'),
			timestamp: true
		},
		dns: {
			servers: servers,
			rules: dns_rules,
			final: final_server,
			independent_cache: true,
			cache_capacity: count(input.cache_capacity, 'cache capacity')
		},
		inbounds: [
			{
				type: 'direct',
				tag: 'dns-in',
				listen: required(input, 'dns_address'),
				listen_port: port(input.dns_port, 'DNS port')
			},
			{
				type: 'tproxy',
				tag: 'tproxy-in',
				listen: tproxy,
				listen_port: port(input.tproxy_port, 'tproxy port')
			},
			{
				type: 'tproxy',
				tag: 'tproxy-direct-in',
				listen: tproxy,
				listen_port: port(input.direct_tproxy_port, 'direct tproxy port')
			},
			{
				type: 'tproxy',
				tag: 'tproxy-router-in',
				listen: tproxy,
				listen_port: port(input.router_tproxy_port, 'router tproxy port')
			},
			...map(exit_inbounds, (e) => ({
				type: 'tproxy',
				tag: `tproxy-exit-${e.index}-in`,
				listen: tproxy,
				listen_port: e.port
			})),
			...(access ? [{
				type: 'tproxy', tag: 'tproxy-client-access-in',
				listen: tproxy, listen_port: access_port
			}] : [])
		],
		outbounds: outbounds,
		route: {
			rules: [
				...(access ? access.router_rules : []),
				{
					inbound: [ 'dns-in' ],
					action: 'hijack-dns'
				},
				{
					inbound: [ 'tproxy-in', 'tproxy-direct-in', 'tproxy-router-in',
						...map(exit_inbounds, (e) => `tproxy-exit-${e.index}-in`) ],
					action: 'sniff',
					timeout: '300ms'
				},
				{
					inbound: [ 'tproxy-direct-in' ],
					action: 'route',
					outbound: 'direct-out'
				},
				...(bypass ? [ {
					rule_set: bypass,
					action: 'route',
					outbound: 'direct-out'
				} ] : []),
				...map(exit_inbounds, (e) => ({
					inbound: [ `tproxy-exit-${e.index}-in` ],
					...to(exit_out(e.index))
				})),
				...flatten(map(exit_rule_sets, (e) => [
					{
						inbound: [ 'tproxy-router-in' ],
						rule_set: [ `ikev2-domains-${e.index}` ],
						...to(exit_out(e.index))
					},
					{
						inbound: [ 'tproxy-in' ],
						source_ip_cidr: input.covered,
						rule_set: [ `ikev2-domains-${e.index}` ],
						...to(exit_out(e.index))
					}
				])),
				{
					inbound: [ 'tproxy-router-in' ],
					...to(tunnel_out)
				},
				{
					inbound: [ 'tproxy-in' ],
					source_ip_cidr: input.covered,
					rule_set: [ 'ikev2-domains' ],
					...to(tunnel_out)
				},
				{
					inbound: [ 'tproxy-in' ],
					action: 'route',
					outbound: 'direct-out'
				}
			],
			rule_set: [
				{
					type: 'local',
					tag: 'ikev2-domains',
					format: 'source',
					path: required(input, 'ruleset_path')
				},
				...(bypass ? [ {
					type: 'local',
					tag: 'ikev2-bypass',
					format: 'source',
					path: input.bypass_ruleset_path
				} ] : []),
				...map(exit_rule_sets, (e) => ({
					type: 'local',
					tag: `ikev2-domains-${e.index}`,
					format: 'source',
					path: e.path
				}))
			],
			final: 'direct-out',
			default_domain_resolver: 'upstream'
		},
		experimental: {
			clash_api: {
				external_controller: required(input, 'controller_address'),
				secret: required(input, 'controller_secret')
			},
			cache_file: {
				enabled: true,
				path: required(input, 'cache_path'),
				// With the cache enabled sing-box keeps each selector's choice
				// in it by itself, so a restart, procd's included, comes back
				// on the tunnel each exit was moved to rather than on its
				// first. There is no key to ask for it: sing-box refuses a
				// field it does not know, and the whole configuration with it.
				store_fakeip: true
			}
		}
	};
}

// A throwaway resolver that answers only through one DoH endpoint over the
// tunnel, to test that endpoint before the running engine is switched to it.
// Keys: bootstrap_host bootstrap_port doh_host doh_port doh_path dns_address,
// and optionally link.
function render_probe(input) {
	// Through the link of the tunnel the first exit uses now, ipsec-out unless
	// named.
	let link = link_name(input.link ?? 'ipsec-out');
	return {
		log: { disabled: true },
		dns: {
			servers: [
				{
					type: 'tcp',
					tag: 'bootstrap',
					server: required(input, 'bootstrap_host'),
					server_port: port(input.bootstrap_port, 'bootstrap port'),
					bind_interface: link
				},
				{
					type: 'https',
					tag: 'probe',
					server: required(input, 'doh_host'),
					server_port: port(input.doh_port, 'tunnel DNS port'),
					path: required(input, 'doh_path'),
					tls: { enabled: true, server_name: input.doh_host },
					bind_interface: link,
					connect_timeout: '2s',
					domain_resolver: { server: 'bootstrap', strategy: 'ipv4_only' }
				}
			],
			final: 'probe',
			disable_cache: true
		},
		inbounds: [
			{ type: 'direct', tag: 'dns', listen: required(input, 'dns_address'), listen_port: 53 }
		],
		route: {
			default_domain_resolver: 'probe',
			rules: [ { inbound: [ 'dns' ], action: 'hijack-dns' } ]
		}
	};
}

// Key order and layout do not matter to sing-box, so they do not decide
// whether a running configuration is current either.
function same(a, b) {
	if (type(a) != type(b))
		return false;
	if (type(a) == 'array') {
		if (length(a) != length(b))
			return false;
		for (let i = 0; i < length(a); i++)
			if (!same(a[i], b[i]))
				return false;
		return true;
	}
	if (type(a) == 'object') {
		if (length(keys(a)) != length(keys(b)))
			return false;
		for (let k in keys(a))
			if (!exists(b, k) || !same(a[k], b[k]))
				return false;
		return true;
	}
	return a == b;
}

function load(path) {
	let text = readfile(path);
	if (text == null)
		return null;
	try {
		return json(text);
	}
	catch (e) {
		return null;
	}
}

// The connections a change of the rule sets left on the wrong path. sing-box
// reloads a rule set by itself and routes what is opened afterwards; what was
// open keeps the outbound it was given, so a service moved to another tunnel
// went on leaving through the old one until its connections closed.
//
// FILE is the controller's list of connections. Stdin names the rule sets as
// they are now, "tag<TAB>path" in the order the route rules read them. A
// connection is stale when the rule set that routed it is one of these and no
// longer the first that holds its name. One routed by something else - a
// device sent whole through a tunnel, an address - is not judged by name.
function stale(path) {
	let listed = load(path);
	if (type(listed?.connections) != 'array')
		die('the list of connections cannot be read');
	let sets = [];
	for (let line in split(stdin.read('all') ?? '', '\n')) {
		let fields = split(line, '\t');
		if (length(fields) != 2 || fields[0] == '')
			continue;
		let names = {};
		for (let rule in (load(fields[1])?.rules ?? []))
			for (let name in (rule?.domain_suffix ?? []))
				if (type(name) == 'string')
					names[lc(name)] = true;
		push(sets, { tag: fields[0], names: names });
	}
	// A suffix holds the name itself and every name under it.
	let holds = (names, host) => {
		for (let name = host; name != ''; ) {
			if (names[name])
				return true;
			let dot = index(name, '.');
			if (dot < 0)
				break;
			name = substr(name, dot + 1);
		}
		return false;
	};
	let ids = [];
	for (let connection in listed.connections) {
		let routed = match(connection?.rule ?? '', /(^| )rule_set=([A-Za-z0-9-]+)( |$)/);
		let host = lc(connection?.metadata?.host ?? '');
		if (!routed || host == '' || !length(filter(sets, (set) => set.tag == routed[2])))
			continue;
		let owner = null;
		for (let set in sets)
			if (holds(set.names, host)) {
				owner = set.tag;
				break;
			}
		// The controller is not trusted with what is put on a command line.
		if (owner != routed[2] && match(connection?.id ?? '', /^[0-9a-fA-F-]{36}$/))
			push(ids, connection.id);
	}
	return ids;
}

let command = ARGV[0];
if (command == 'render') {
	printf('%.2J\n', render(read_input()));
	exit(0);
}
else if (command == 'probe') {
	printf('%.2J\n', render_probe(read_input()));
	exit(0);
}
else if (command == 'equal') {
	let a = load(ARGV[1]), b = load(ARGV[2]);
	exit(a != null && b != null && same(a, b) ? 0 : 1);
}
else if (command == 'stale') {
	for (let id in stale(ARGV[1]))
		print(id, '\n');
	exit(0);
}
warn('usage: singbox-config.uc {render|probe|equal FILE FILE|stale FILE}\n');
exit(2);
