{%
'use strict';
import { client_policy_response } from './client-access-api.uc';
import { client_enrollment_response } from './client-access-enrollment-api.uc';

// Loaded by a separate uhttpd instance, with an empty document root and no ubus
// handler. The state path is fixed and cannot be supplied by an HTTP caller.
global.handle_request = function(env) {
	let result = env.REQUEST_URI == '/client/v1/enroll' || env.REQUEST_URI == '/client/v1/enrollment' ?
		client_enrollment_response(env, '/etc/ikev2-manager/clients') : client_policy_response(env, '/etc/ikev2-manager/clients');
	let phrases = { '200': 'OK', '202': 'Accepted', '400': 'Bad Request', '401': 'Unauthorized',
		'403': 'Forbidden', '404': 'Not Found', '405': 'Method Not Allowed', '503': 'Service Unavailable' };
	let body = sprintf('%J\n', result.body);
	uhttpd.send(sprintf('Status: %d %s\r\n', result.status, phrases[`${result.status}`]));
	uhttpd.send('Content-Type: application/json\r\nCache-Control: no-store\r\n');
	uhttpd.send('X-Content-Type-Options: nosniff\r\nConnection: close\r\n');
	if (result.status == 405)
		uhttpd.send(sprintf('Allow: %s\r\n', result.allow ?? 'GET'));
	uhttpd.send(sprintf('Content-Length: %d\r\n\r\n%s', length(body), body));
};
%}
