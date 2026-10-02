#!/bin/sh
# The one-time profile link a phone opens from the QR on the VPN Users page.
# Everything is decided by the manager helper; this only hands it the request.
token="$(printf '%s\n' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^t=//p' | head -n 1)"
exec /usr/libexec/ikev2-manager profile-link-serve "$token" "${REMOTE_ADDR:-}"
