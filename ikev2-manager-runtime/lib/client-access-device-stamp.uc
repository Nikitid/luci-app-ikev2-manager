// CLI wrapper used by the admission watcher after its plan was installed.
'use strict';
import { read_client_state } from './client-access-store.uc';
import { client_views_generation, read_client_view_by_id } from './client-access-view.uc';
import { protected_file } from './client-access-path-evidence.uc';
import { stamp_client_device_evidence } from './client-access-device-evidence.uc';
try {
 if (length(ARGV) != 4) die('invalid stamp arguments');
 let plan = json(protected_file(ARGV[2], 33554432));
 // The views of the connected devices, when they are of the plan's own
 // generation; the whole state otherwise.
 let source = client_views_generation(ARGV[1]) === plan.generation ? (id => read_client_view_by_id(ARGV[1], id)) : read_client_state(ARGV[1]);
 stamp_client_device_evidence(ARGV[0], source, plan, ARGV[3], time());
 exit(0);
} catch (error) {
 warn('client-access-device-stamp: device readiness unavailable\n'); exit(1);
}
