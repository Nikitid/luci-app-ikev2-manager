// Shared validation for client and router policy compilation.
'use strict';

function refuse(message) {
	die(`client-access-policy: ${message}`);
}

function fields(value, expected, context) {
	if (type(value) != 'object')
		refuse(`${context}: object required`);
	for (let key in keys(value))
		if (index(expected, key) < 0)
			refuse(`${context}: unknown field ${key}`);
	for (let key in expected)
		if (value[key] == null)
			refuse(`${context}: missing field ${key}`);
}

function integer(value, minimum, maximum, context) {
	if (type(value) != 'int' || value < minimum || value > maximum)
		refuse(`${context}: invalid integer`);
	return value;
}

function identifier(value, context) {
	if (type(value) != 'string' || !match(value, /^[a-z][a-z0-9-]{0,47}$/))
		refuse(`${context}: invalid identifier`);
	return value;
}

function domain(value) {
	if (type(value) != 'string' || length(value) > 253 || length(split(value, '.')) < 2)
		refuse('invalid domain');
	for (let label in split(value, '.'))
		if (!match(label, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/))
			refuse('invalid domain label');
	if (match(value, /^[0-9.]+$/))
		refuse('domain must not be an IP address');
	return value;
}

function service_identifier(value) {
 if (type(value) != 'string' || !match(value, /^[a-z0-9][a-z0-9_-]{0,47}$/))
  refuse('invalid service identifier');
 return value;
}

function ipv4(value) {
	if (type(value) != 'string')
		refuse('IPv4 address required');
	let octets = split(value, '.');
	if (length(octets) != 4)
		refuse('invalid IPv4 address');
	for (let octet in octets)
		if (!match(octet, /^(0|[1-9][0-9]{0,2})$/) || +octet > 255)
			refuse('invalid IPv4 octet');
	return map(octets, octet => +octet);
}

function address_number(octets) {
	return octets[0] * 16777216 + octets[1] * 65536 + octets[2] * 256 + octets[3];
}

function subnet_range(value) {
	if (type(value) != 'string')
		refuse('virtual subnet required');
	let parts = split(value, '/');
	if (length(parts) != 2 || !match(parts[1], /^(1[6-9]|2[0-8])$/))
		refuse('virtual subnet prefix must be /16 through /28');
	let octets = ipv4(parts[0]);
	if (!(octets[0] == 10 || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
		(octets[0] == 192 && octets[1] == 168)))
		refuse('virtual subnet must be RFC1918');
	let first = address_number(octets), size = 1;
	for (let bit = +parts[1]; bit < 32; bit++)
		size *= 2;
	if (first % size != 0)
		refuse('virtual subnet is not a network address');
	return { first: first, last: first + size - 1 };
}

function address_text(number) {
	let octets = [];
	for (let place = 0; place < 4; place++) {
		unshift(octets, number % 256);
		number = (number - number % 256) / 256;
	}
	return join('.', octets);
}

function transports(values) {
	if (type(values) != 'array' || length(values) < 1 || length(values) > 2)
		refuse('one or two transports required');
	let protocols = {};
	for (let value in values) {
		fields(value, [ 'protocol', 'ports' ], 'transport');
		if ((value.protocol != 'tcp' && value.protocol != 'udp') || protocols[value.protocol])
			refuse('invalid or duplicate protocol');
		protocols[value.protocol] = true;
		if (type(value.ports) != 'array' || length(value.ports) < 1 || length(value.ports) > 64)
			refuse('one to 64 ports required');
		let seen = {};
		for (let port in value.ports) {
			integer(port, 1, 65535, 'resource port');
			if (seen[`${port}`])
				refuse('duplicate port');
			seen[`${port}`] = true;
		}
	}
}

export function validate_client_subnet(virtual_subnet) {
	return subnet_range(virtual_subnet);
};

// How the virtual subnet is laid out. Its lower half holds the fixed address
// of every published domain; the last address of that half answers names; the
// upper half is handed out, one address per name asked for, to any host under
// a published domain. Clients derive the same layout from the subnet alone.
export function client_names_plan(virtual_subnet) {
	let subnet = subnet_range(virtual_subnet), half = (subnet.last - subnet.first + 1) / 2;
	let middle = subnet.first + half;
	return { resolver: address_text(middle - 1), resolver_number: middle - 1,
		range: `${address_text(middle)}/${+split(virtual_subnet, '/')[1] + 1}`,
		range_first: middle, range_last: subnet.last };
};

export function validate_client_base(server, virtual_subnet, exit) {
	fields(server, [ 'address', 'remote_id' ], 'server');
	domain(server.address);
	domain(server.remote_id);
	if (type(exit) != 'string' || !match(exit, /^[1-7]s?$/))
		refuse('invalid exit');

	return subnet_range(virtual_subnet);

};

export function compile_client_policy(policy) {
	fields(policy, [ 'version', 'id', 'revision', 'server', 'virtual_subnet', 'exit', 'resources' ], 'policy');
	integer(policy.version, 1, 1, 'version');
	identifier(policy.id, 'policy id');
	integer(policy.revision, 1, 2147483647, 'revision');
	let subnet = validate_client_base(policy.server, policy.virtual_subnet, policy.exit);

	if (type(policy.resources) != 'array' || length(policy.resources) < 1 || length(policy.resources) > 4096)
		refuse('one to 4096 resources required');
	let seen_ids = {}, seen_domains = {}, seen_addresses = {};
	let hosts = [], routes = [], rules = [];
	for (let resource in policy.resources) {
		fields(resource, [ 'id', 'domain', 'address', 'transports' ], 'resource');
		identifier(resource.id, 'resource id');
		domain(resource.domain);
		let address = address_number(ipv4(resource.address));
		if (address <= subnet.first || address >= subnet.last)
			refuse('resource address outside usable virtual subnet');
		if (seen_ids[resource.id] || seen_domains[resource.domain] || seen_addresses[resource.address])
			refuse('duplicate resource id, domain or address');
		if (resource.domain == policy.server.address || resource.domain == policy.server.remote_id)
			refuse('VPN bootstrap name cannot be a protected resource');
		seen_ids[resource.id] = true;
		seen_domains[resource.domain] = true;
		seen_addresses[resource.address] = true;
		transports(resource.transports);
		push(hosts, `${resource.address} ${resource.domain}`);
		push(routes, `${resource.address}/32`);
		for (let transport in resource.transports)
			push(rules, {
				inbound: [ 'tproxy-client-access-in' ],
				ip_cidr: [ `${resource.address}/32` ],
				network: [ transport.protocol ],
				port: transport.ports,
				action: 'route',
				override_address: resource.domain,
				outbound: `exit-${policy.exit}`
			});
	}
	// No direct fallback, sniffing, or dynamic FakeIP lookup belongs on this path.
	push(rules, { inbound: [ 'tproxy-client-access-in' ], action: 'reject', method: 'drop' });
	return {
		version: 1,
		policy: policy,
		hosts: join('\n', hosts) + '\n',
		routes: routes,
		router_rules: rules,
		requirements: {
			guard_before_hosts: true,
			guard_survives_disconnect: true,
			reject_unknown_destinations: true,
			check_subnet_conflicts: true,
			credentials_separate: true
		}
	};
};

// Allocation history is append-only, including removed domains. A stale
// client must never reach a different service through a recycled address.
export function allocate_client_catalog(catalog) {
	fields(catalog, [ 'version', 'virtual_subnet', 'services', 'allocations', 'selected_services' ], 'catalog');
	integer(catalog.version, 1, 1, 'catalog version');
	let subnet = subnet_range(catalog.virtual_subnet), names = client_names_plan(catalog.virtual_subnet);
	if (type(catalog.services) != 'array' || type(catalog.allocations) != 'array' ||
		type(catalog.selected_services) != 'array')
		refuse('catalog arrays required');
	let allocated = {}, used = {}, service_ids = {}, selected = {}, wanted = {};
	for (let item in catalog.allocations) {
		fields(item, [ 'domain', 'address' ], 'allocation');
		domain(item.domain);
		let number = address_number(ipv4(item.address));
		if (number <= subnet.first || number >= names.resolver_number || allocated[item.domain] || used[item.address])
			refuse('invalid or duplicate allocation');
		allocated[item.domain] = item.address;
		used[item.address] = true;
	}
	for (let id in catalog.selected_services) {
		service_identifier(id);
		if (selected[id])
			refuse('duplicate selected service');
		selected[id] = true;
	}
	let next = subnet.first + 1;
	for (let service in catalog.services) {
		fields(service, [ 'id', 'client_access', 'domains', 'transports' ], 'service');
		service_identifier(service.id);
		transports(service.transports);
		if (service_ids[service.id] || type(service.client_access) != 'bool' || type(service.domains) != 'array')
			refuse('invalid or duplicate service');
		service_ids[service.id] = true;
		if (selected[service.id] && !service.client_access)
			refuse('selected service is not published to clients');
		for (let name in service.domains) {
			domain(name);
			if (!service.client_access)
				continue;
			if (!allocated[name]) {
				while (next < names.resolver_number && used[address_text(next)])
					next++;
				if (next >= names.resolver_number)
					refuse('virtual subnet exhausted');
				let address = address_text(next++);
				allocated[name] = address;
				used[address] = true;
				push(catalog.allocations, { domain: name, address: address });
			}
			if (selected[service.id]) {
				if (!wanted[name])
					wanted[name] = {};
				for (let transport in service.transports) {
					if (!wanted[name][transport.protocol])
						wanted[name][transport.protocol] = [];
					for (let port in transport.ports)
						if (index(wanted[name][transport.protocol], port) < 0)
							push(wanted[name][transport.protocol], port);
				}
			}
		}
	}
	for (let id in keys(selected))
		if (!service_ids[id])
			refuse('unknown selected service');
	let resources = map(sort(keys(wanted)), name => ({
		id: `host-${address_number(ipv4(allocated[name])) - subnet.first}`,
		domain: name, address: allocated[name],
		transports: map(sort(keys(wanted[name])), protocol => ({
			protocol: protocol, ports: sort(wanted[name][protocol])
		}))
	}));
	if (length(resources) > 4096)
		refuse('too many selected resources');
	return { allocations: catalog.allocations, resources: resources };
};
