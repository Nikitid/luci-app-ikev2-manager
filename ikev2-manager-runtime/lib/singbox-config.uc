// The sing-box configuration of the FakeIP engine.
//
//   singbox-config.uc render <INPUT       prints the configuration
//   singbox-config.uc probe <INPUT        prints a tunnel DNS probe worker's
//   singbox-config.uc equal FILE FILE     whether two configurations match
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
// ruleset_path, and optionally https_all 1. Repeated: covered CIDR,
// https_suffix SUFFIX, and segment TAG PORT SUFFIX... in routing order.

'use strict';

import { stdin, readfile } from 'fs';

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
	let input = { covered: [], https_suffix: [], segment: [] };
	for (let line in split(stdin.read('all') ?? '', '\n')) {
		if (line == '')
			continue;
		let fields = split(line, '\t');
		let key = fields[0];
		if (key == 'covered' || key == 'https_suffix')
			push(input[key], fields[1]);
		else if (key == 'segment')
			push(input.segment, { tag: fields[1], port: fields[2], suffixes: slice(fields, 3) });
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

function render(input) {
	let domains = [ 'ikev2-domains' ];
	let servers = [
		{
			type: 'udp',
			tag: 'upstream',
			server: required(input, 'upstream_host'),
			server_port: port(input.upstream_port, 'upstream port')
		},
		// The tunnel bootstrap uses TCP. sing-box keeps one shared UDP socket
		// per server and replaces it only on a read or write error, never on
		// a timeout; one opened while ipsec-out had no address kept the WAN
		// source and failed silently until a restart. TCP picks the current
		// source on every query.
		{
			type: 'tcp',
			tag: 'ikev2-bootstrap',
			server: required(input, 'bootstrap_host'),
			server_port: port(input.bootstrap_port, 'bootstrap port'),
			bind_interface: 'ipsec-out'
		},
		{
			type: 'https',
			tag: 'ikev2-upstream',
			server: required(input, 'doh_host'),
			server_port: port(input.doh_port, 'tunnel DNS port'),
			path: required(input, 'doh_path'),
			tls: {
				enabled: true,
				server_name: input.doh_host
			},
			bind_interface: 'ipsec-out',
			domain_resolver: {
				server: 'ikev2-bootstrap',
				strategy: 'ipv4_only'
			},
			connect_timeout: '5s'
		}
	];
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

	let dns_rules = [
		{
			rule_set: domains,
			query_type: [ 'HTTPS' ],
			action: 'predefined',
			rcode: 'NOERROR'
		}
	];
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
			final: required(input, 'final_server'),
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
			}
		],
		outbounds: [
			{
				type: 'direct',
				tag: 'direct-out',
				domain_resolver: 'upstream'
			},
			{
				type: 'direct',
				tag: 'ikev2-out',
				bind_interface: 'ipsec-out',
				domain_resolver: {
					server: 'ikev2-upstream',
					strategy: 'ipv4_only'
				}
			}
		],
		route: {
			rules: [
				{
					inbound: [ 'dns-in' ],
					action: 'hijack-dns'
				},
				{
					inbound: [ 'tproxy-in', 'tproxy-direct-in', 'tproxy-router-in' ],
					action: 'sniff',
					timeout: '300ms'
				},
				{
					inbound: [ 'tproxy-direct-in' ],
					action: 'route',
					outbound: 'direct-out'
				},
				{
					inbound: [ 'tproxy-router-in' ],
					action: 'route',
					outbound: 'ikev2-out'
				},
				{
					inbound: [ 'tproxy-in' ],
					source_ip_cidr: input.covered,
					rule_set: domains,
					action: 'route',
					outbound: 'ikev2-out'
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
				}
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
				store_fakeip: true
			}
		}
	};
}

// A throwaway resolver that answers only through one DoH endpoint over the
// tunnel, to test that endpoint before the running engine is switched to it.
// Keys: bootstrap_host bootstrap_port doh_host doh_port doh_path dns_address.
function render_probe(input) {
	return {
		log: { disabled: true },
		dns: {
			servers: [
				{
					type: 'tcp',
					tag: 'bootstrap',
					server: required(input, 'bootstrap_host'),
					server_port: port(input.bootstrap_port, 'bootstrap port'),
					bind_interface: 'ipsec-out'
				},
				{
					type: 'https',
					tag: 'probe',
					server: required(input, 'doh_host'),
					server_port: port(input.doh_port, 'tunnel DNS port'),
					path: required(input, 'doh_path'),
					tls: { enabled: true, server_name: input.doh_host },
					bind_interface: 'ipsec-out',
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
warn('usage: singbox-config.uc {render|probe|equal FILE FILE}\n');
exit(2);
