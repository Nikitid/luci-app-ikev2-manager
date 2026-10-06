// CLI wrapper used by the admission watcher.
'use strict';
import { readfile } from 'fs';
import { require_current_client_path } from './client-access-path-evidence.uc';
try {
 if (length(ARGV) != 3) die('invalid readiness arguments');
 require_current_client_path(ARGV[0], json(readfile(ARGV[1])), ARGV[2]);
 exit(0);
} catch (error) {
 warn('client-access-ready: required path is not current\n'); exit(1);
}
