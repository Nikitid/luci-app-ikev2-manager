#!/usr/bin/ucode
import * as ubus from 'ubus';
import * as uloop from 'uloop';
uloop.init();
let conn = ubus.connect('/var/run/ubus/ubus.sock');
conn.publish('system', {
	board: { args: {}, call: () => ({ kernel: '6.12.0', hostname: 'stand-router', system: 'ARMv8', model: 'Stand Router', board_name: 'stand', rootfs_type: 'squashfs', release: { distribution: 'OpenWrt', version: '25.12.6', revision: 'r33311', target: 'armsr/armv8', description: 'OpenWrt 25.12.6' } }) },
	info: { args: {}, call: () => ({ uptime: 86400, localtime: time(), load: [ 4096, 4096, 4096 ], memory: { total: 536870912, free: 268435456, shared: 0, buffered: 0, available: 268435456, cached: 1048576 }, swap: { total: 0, free: 0 } }) },
});
conn.publish('service', { list: { args: { name: '' }, call: () => ({}) } });
function iface(name, device, address, gateway) {
	return { interface: name, up: true, pending: false, available: true, autostart: true, uptime: 86400, l3_device: device, proto: 'static', device: device, metric: 0,
		'ipv4-address': [ { address: address, mask: 24 } ], 'ipv6-address': [], 'ipv6-prefix': [], 'ipv6-prefix-assignment': [],
		route: gateway ? [ { target: '0.0.0.0', mask: 0, nexthop: gateway, source: address + '/32' } ] : [], 'dns-server': [], 'dns-search': [], inactive: { 'ipv4-address': [], 'ipv6-address': [], route: [], 'dns-server': [], 'dns-search': [] }, data: {} };
}
let networks = { lan: iface('lan', 'br-lan', '10.99.0.1'), wan: iface('wan', 'eth0', '203.0.113.2', '203.0.113.1') };
conn.publish('network.interface', { dump: { args: {}, call: () => ({ interface: values(networks) }) } });
function status(value) { return { status: { args: {}, call: () => value } }; }
for (let name in keys(networks))
	conn.publish('network.interface.' + name, status(networks[name]));
conn.publish('network.device', { status: { args: { name: '' }, call: () => ({}) } });
uloop.run();
