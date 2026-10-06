// Local watcher only; no arguments originate in a device request.
'use strict';
import { read_client_state } from './client-access-store.uc';
import { protected_file } from './client-access-path-evidence.uc';
import { stamp_client_device_evidence } from './client-access-device-evidence.uc';
try {
 if (length(ARGV) != 4) die('invalid device stamp arguments');
 stamp_client_device_evidence(ARGV[0], read_client_state(ARGV[1]), json(protected_file(ARGV[2], 33554432)), ARGV[3], time());
} catch (error) { warn('client-access-device-stamp: device evidence unavailable\n'); exit(1); }
