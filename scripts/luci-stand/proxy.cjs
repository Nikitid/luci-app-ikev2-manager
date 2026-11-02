#!/usr/bin/env node
// Signs in to the stand's LuCI once and forwards every request with that
// session, so a probe can open a page directly. Test stand only: the password
// belongs to a throwaway container.
//
//   node proxy.cjs LISTEN_PORT TARGET_PORT

const http = require('http');
const [listen, target] = process.argv.slice(2).map(Number);
const user = 'root';
const password = 'stand-test';
let cookie = '';

function login() {
	return new Promise((resolve, reject) => {
		const body = `luci_username=${user}&luci_password=${password}`;
		const req = http.request({ host: '127.0.0.1', port: target, path: '/cgi-bin/luci/', method: 'POST',
			headers: { 'content-type': 'application/x-www-form-urlencoded', 'content-length': body.length } }, (res) => {
			const set = (res.headers['set-cookie'] || []).find((c) => c.startsWith('sysauth'));
			res.resume();
			if (!set) return reject(new Error('stand login refused'));
			cookie = set.split(';')[0];
			resolve();
		});
		req.on('error', reject);
		req.end(body);
	});
}

function forward(req, res, retried) {
	const headers = { ...req.headers, host: `127.0.0.1:${target}`, cookie };
	const out = http.request({ host: '127.0.0.1', port: target, path: req.url, method: req.method, headers }, (back) => {
		if (back.statusCode === 403 && !retried && req.method === 'GET') {
			back.resume();
			return login().then(() => forward(req, res, true), () => { res.writeHead(502); res.end(); });
		}
		res.writeHead(back.statusCode, back.headers);
		back.pipe(res);
	});
	out.on('error', () => { res.writeHead(502); res.end(); });
	req.pipe(out);
}

login().then(() => {
	http.createServer((req, res) => forward(req, res, false)).listen(listen, '127.0.0.1');
}).catch((e) => { console.error(e.message); process.exit(1); });
