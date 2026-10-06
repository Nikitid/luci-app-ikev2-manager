// Fixed local configuration; no HTTP caller can select a certificate or port.
'use strict';
import { lstat, popen } from 'fs';
import { read_client_state } from './client-access-store.uc';
function option(section, name) {
 let child = popen('/sbin/uci -q get ikev2-manager.' + section + '.' + name, 'r');
 if (child == null) die('configuration unavailable');
 let value = child.read(4097), status = child.close();
 if (status != 0) return '';
 if (type(value) != 'string' || length(value) > 4096) die('invalid configuration size');
 return replace(value, /\n$/, '');
}
function certificate_path(path, private_key) {
 if (type(path) != 'string' || length(path) > 1024 || !match(path, /^\/[A-Za-z0-9_.\/-]+$/)) die('invalid certificate path');
 let parts = split(path, '/'), current = '';
 for (let i = 1; i < length(parts); i++) {
  if (!length(parts[i]) || parts[i] == '.' || parts[i] == '..') die('invalid certificate path');
  current += '/' + parts[i];
  let info = lstat(current);
  if (info == null || info.uid != 0 || (info.mode & 0022) != 0 ||
   (i < length(parts) - 1 ? info.type != 'directory' : info.type != 'file' || info.nlink != 1 ||
    (private_key && (info.mode & 0077) != 0) || info.size < 1 || info.size > 1048576)) die('unsafe certificate path');
 }
 return path;
}
try {
 if (length(ARGV)) die('invalid settings command');
 if (option('client_access', 'enabled') != '1' || option('server', 'enabled') != '1') die('client API disabled');
 let state = read_client_state('/etc/ikev2-manager/clients'), identity = option('server', 'identity');
 if (identity != state.publication.server.address) die('client API identity mismatch');
 let port = option('client_access', 'port');
 if (!match(port, /^[1-9][0-9]{3,4}$/) || int(port) < 1024 || int(port) > 65535) die('invalid client API port');
 let source = option('server', 'cert_source') || '/etc/ssl/acme';
 let cert = certificate_path(option('server', 'cert_file') || source + '/' + identity + '.fullchain.crt', false);
 let key = certificate_path(option('server', 'key_file') || source + '/' + identity + '.key', true);
 print(sprintf('%J\n', { identity: identity, port: int(port), certificate: cert, private_key: key }));
} catch (error) { warn('client-api-settings: configuration refused or unavailable\n'); exit(1); }
