// Dedicated managed-service proxy: no ordinary traffic or direct fallback.
'use strict';
import { validate_client_state } from './client-access-state.uc';
import { allocate_client_catalog, compile_client_policy } from './client-access.uc';

export function compile_client_path(input) {
	let names = [ 'version', 'state', 'exit_link', 'dns_address', 'dns_port', 'listen_port' ];
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
	let state = validate_client_state(input.state), publication = state.publication;
	let selected = map(filter(publication.services, service => service.client_access), service => service.id);
	let catalog = allocate_client_catalog({ version: 1, virtual_subnet: publication.virtual_subnet,
		services: publication.services, allocations: publication.allocations, selected_services: selected });
	let rules = [ { inbound: [ 'tproxy-client-access-in' ], action: 'reject', method: 'drop' } ];
	if (length(catalog.resources)) {
		let policy = { version: 1, id: 'router', revision: state.generation,
			server: publication.server, virtual_subnet: publication.virtual_subnet,
			exit: publication.exit, resources: catalog.resources };
		rules = compile_client_policy(policy).router_rules;
		for (let rule in rules)
			if (rule.action == 'route') rule.outbound = 'managed-exit';
	}
	let subnet = publication.virtual_subnet;
	// Admission (-165) precedes interception (-154). A missing local route or
	// listener cannot forward virtual destinations through an unrelated route.
	let nft = `table inet ikev2_client_path {
  chain ikev2_manager_owned { }
  chain prerouting {
    type filter hook prerouting priority -154; policy accept;
    iifname "ipsec-in" ip daddr ${subnet} meta mark == 0x00800000 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${input.listen_port} counter accept
    ip daddr ${subnet} counter drop
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
	return { version: 1, generation: state.generation, virtual_subnet: subnet,
		exit: publication.exit, exit_link: input.exit_link, mark: '0x00800000',
		route: { priority: 10998, table: 1506, ingress: 'ipsec-in', destination: subnet },
		nft: nft,
		config: {
			log: { level: 'warn' },
			dns: { servers: [ { type: 'tcp', tag: 'managed-dns', server: input.dns_address,
				server_port: input.dns_port, bind_interface: input.exit_link } ],
				final: 'managed-dns', strategy: 'ipv4_only' },
			inbounds: [ { type: 'tproxy', tag: 'tproxy-client-access-in',
				listen: '127.0.0.1', listen_port: input.listen_port } ],
			outbounds: [ { type: 'direct', tag: 'managed-exit', bind_interface: input.exit_link,
				domain_resolver: { server: 'managed-dns', strategy: 'ipv4_only' } } ],
			route: { rules: rules, final: 'managed-exit' }
		}
	};
};
