// Move a one-shot LuCI request into a private worker inbox before detaching.
'use strict';
import { lstat, open, unlink } from 'fs';
try {
 if (length(ARGV) != 2 || !match(ARGV[0], /^[a-z0-9][a-z0-9-]{0,63}$/)) die('invalid request token');
 let directory = ARGV[1], info = lstat(directory);
 if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe inbox');
 let source = '/var/run/ikev2-client-admin-' + ARGV[0] + '.in';
 info = lstat(source);
 if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1 || info.size < 1 || info.size > 1048576)
  die('unsafe request');
 let file = open(source, 're');
 if (!file) die('missing request');
 let raw = file.read(1048577); file.close();
 if (type(raw) != 'string' || length(raw) > 1048576 || type(json(raw)) != 'object') die('invalid request');
 let target = directory + '/' + ARGV[0] + '.in';
 file = open(target, 'wxe', 0600);
 if (!file || file.write(raw) != length(raw) || !file.close()) die('unable to stage request');
 if (!unlink(source)) { unlink(target); die('unable to consume request'); }
} catch (error) {
 warn('client-access-input: request unavailable or refused\n'); exit(1);
}
