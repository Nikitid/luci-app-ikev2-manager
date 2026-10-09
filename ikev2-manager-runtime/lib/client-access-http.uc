{%
'use strict';
import { client_policy_response } from './client-access-api.uc';
import { client_enrollment_response } from './client-access-enrollment-api.uc';
import { client_download_page } from './client-access-download.uc';

// Loaded by a separate uhttpd instance, with an empty document root and no ubus
// handler. The state path is fixed and cannot be supplied by an HTTP caller.
global.handle_request = function(env) {
	// A person opening their link in a browser gets the download page; the
	// programs never ask for this address with GET.
	if (env.REQUEST_METHOD == 'GET' && env.REQUEST_URI == '/client/v1/enroll' && env.HTTPS == 'on') {
		let page = null;
		try { page = client_download_page(env); } catch (error) { page = null; }
		if (page != null) {
			uhttpd.send('Status: 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n');
			// The one script is the page's own, named by a value made for this answer.
			uhttpd.send(`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'nonce-${page.nonce}'\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n`);
			uhttpd.send(sprintf('X-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s', length(page.html), page.html));
			return;
		}
	}
	let result = env.REQUEST_URI == '/client/v1/enroll' || env.REQUEST_URI == '/client/v1/enrollment' ?
		client_enrollment_response(env, '/etc/ikev2-manager/clients') : client_policy_response(env, '/etc/ikev2-manager/clients', '/var/run/ikev2-client-seen', count => uhttpd.recv(count));
	let phrases = { '200': 'OK', '202': 'Accepted', '400': 'Bad Request', '401': 'Unauthorized',
		'403': 'Forbidden', '404': 'Not Found', '405': 'Method Not Allowed', '409': 'Conflict', '503': 'Service Unavailable' };
	let body = sprintf('%J\n', result.body);
	uhttpd.send(sprintf('Status: %d %s\r\n', result.status, phrases[`${result.status}`]));
	uhttpd.send('Content-Type: application/json\r\nCache-Control: no-store\r\n');
	uhttpd.send('X-Content-Type-Options: nosniff\r\nConnection: close\r\n');
	if (result.status == 405)
		uhttpd.send(sprintf('Allow: %s\r\n', result.allow ?? 'GET'));
	uhttpd.send(sprintf('Content-Length: %d\r\n\r\n%s', length(body), body));
};
%}
