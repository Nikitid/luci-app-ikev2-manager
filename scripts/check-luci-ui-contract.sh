#!/bin/sh

set -eu

files="luci-ikev2-manager luci-ikev2-domains"

if grep -R -n --include='*.js' 'ui\.addNotification' $files; then
	printf '%s\n' 'LuCI actions must report through an inline result, not global notifications' >&2
	exit 1
fi

if grep -R -n --include='*.js' "dispatchEvent(new Event('ikev2-.*-updated" $files; then
	printf '%s\n' 'LuCI actions must refresh their concrete state instead of emitting unhandled update events' >&2
	exit 1
fi

if grep -R -n --include='*.js' -E 'please reload the page|Reload the Overview|reload in a moment' $files; then
	printf '%s\n' 'LuCI actions must not require a manual page reload to expose their result' >&2
	exit 1
fi

# window._ belongs to LuCI. Replacing it from one of our resources would change
# the strings of every other application on the page, including the router-wide
# Status Overview that loads our widget.
if grep -R -n --include='*.js' -E '(^|[^.\w])window\._[[:space:]]*=' $files; then
	printf '%s\n' 'the project translator must not replace the global window._' >&2
	exit 1
fi
# Translations come from LuCI's catalog (po/ru, compiled into an .lmo). A local
# dictionary or translator shadow would bypass the language LuCI is using.
if grep -R -n --include='*.js' -E '^var (_|ru) = |nativeTranslate|localStorage[^;]*language' $files; then
	printf '%s\n' 'pages must use LuCI translations, not a project dictionary' >&2
	exit 1
fi

# runDepsJob calls its last argument after success. Passing `true` there made a
# successful pause report "refresh is not a function" and left the button on
# its old label.
if ! node - <<'JS'
const src = require('fs').readFileSync('luci-ikev2-manager/setup.js', 'utf8');
// Collect the argument list of every call, skipping string contents.
const calls = [];
let from = 0;
while ((from = src.indexOf('runDepsJob(', from)) >= 0) {
	let i = from + 'runDepsJob('.length, depth = 1, quote = null, args = [], cur = '';
	for (; i < src.length && depth; i++) {
		const c = src[i];
		if (quote) { cur += c; if (c === '\\') cur += src[++i]; else if (c === quote) quote = null; continue; }
		if (c === "'" || c === '"') { quote = c; cur += c; continue; }
		if (c === '(' || c === '[' || c === '{') depth++;
		if (c === ')' || c === ']' || c === '}') depth--;
		if (depth === 1 && c === ',') { args.push(cur.trim()); cur = ''; continue; }
		if (depth) cur += c;
	}
	args.push(cur.trim());
	calls.push(args);
	from = i;
}
const bad = calls.filter(a => a.length === 5 && /^(true|false|null|undefined|\d+)$/.test(a[4]));
// System actions report through action-status; runDepsJob polls only the
// dependency installer's status file and never sees them finish.
calls.forEach(a => { if (/-async'$/.test(a[1] || '')) bad.push(a); });
process.exit(calls.length && !bad.length ? 0 : 1);
JS
then
	printf '%s\n' 'runDepsJob is for dependency jobs and needs a refresh function' >&2
	exit 1
fi

# Save and Apply buttons are grey until their form changes. Each one must be
# handed to trackChanges, or it silently goes back to being always enabled.
for pair in \
	'luci-ikev2-manager/setup.js:trackChanges(save,' \
	'luci-ikev2-manager/settings.js:trackChanges(save,' \
	'luci-ikev2-manager/settings.js:trackChanges(acmeSave,' \
	'luci-ikev2-manager/settings.js:trackChanges(rawSave,' \
	'luci-ikev2-manager/client.js:trackChanges([ save, saveOnly ],' \
	'luci-ikev2-manager/client.js:trackChanges(tunnelDnsApply,' \
	'luci-ikev2-manager/client.js:trackChanges(dnsSave,' \
	'luci-ikev2-manager/client.js:trackChanges(rawSave,' \
	'luci-ikev2-manager/client.js:trackChanges(save, [ name,' \
	'luci-ikev2-domains/editor.js:trackChanges(saveBtn,' \
	'luci-ikev2-domains/editor.js:trackChanges(serviceSave,' \
	'luci-ikev2-manager/users.js:trackChanges(dialogSave,'; do
	grep -Fq "${pair#*:}" "${pair%%:*}" || {
		printf 'save button is not tied to its form changes: %s\n' "$pair" >&2
		exit 1
	}
done

acl='luci-ikev2-manager/acl.json'
for broad_rule in \
	'"/usr/libexec/ikev2-manager *"' \
	'"/usr/libexec/ikev2-manager-system *"' \
	'"/usr/libexec/ikev2-domains-community *"' \
	'"/usr/libexec/ikev2-domain-router *"' \
	'"/usr/libexec/ikev2-devices *"'; do
	if grep -Fq "$broad_rule" "$acl"; then
		printf 'broad LuCI exec ACL is forbidden: %s\n' "$broad_rule" >&2
		exit 1
	fi
done

if grep -R -n --include='*.js' 'advanced-start.*encodeBase64' $files; then
	printf '%s\n' 'custom strongSwan profiles must use one-shot input files, not argv' >&2
	exit 1
fi
grep -Fq '"/var/run/ikev2-manager-profile-*.in": [ "write" ]' "$acl"
if grep -Fq 'Blocked — strongSwan upgrade required' \
	'luci-ikev2-manager/settings.js'; then
	printf '%s\n' 'inbound strongSwan advisory must not be rendered as a runtime block' >&2
	exit 1
fi
grep -Fq "notice ? 'info'" 'luci-ikev2-manager/setup.js'
grep -Fq "Reset app and remove dependencies" 'luci-ikev2-manager/setup.js'
dns_toggle_line="$(grep -n "common.toggleRow(blockDot" 'luci-ikev2-manager/setup.js' | cut -d: -f1)"
apply_bar_line="$(grep -n "applyResult.node" 'luci-ikev2-manager/setup.js' | tail -n1 | cut -d: -f1)"
[ -n "$dns_toggle_line" ] && [ -n "$apply_bar_line" ] &&
	[ "$apply_bar_line" -gt "$dns_toggle_line" ] || {
	printf '%s\n' 'Overview Apply must follow the managed, network and DNS controls' >&2
	exit 1
}
grep -Fq "Network and DNS changes are applied together by the button at the bottom." \
	'luci-ikev2-manager/setup.js'
grep -Fq "diagnostic_status=unavailable\\ndependencies_ok=unknown" \
	'luci-ikev2-manager/setup.js'
grep -Fq "installDeps.style.display = known && !ready ? '' : 'none'" \
	'luci-ikev2-manager/setup.js'
for noisy_copy in \
	'Clients must use router DNS.' \
	'Online shows only IKEv2 sessions' \
	'Current upstream:' \
	'This is a router-wide resolver setting.' \
	'Applying DNS restarts the managed resolver.'; do
	if grep -R -Fq --include='*.js' "$noisy_copy" \
		luci-ikev2-manager luci-ikev2-domains; then
		printf 'retired explanatory plaque returned: %s\n' "$noisy_copy" >&2
		exit 1
	fi
done
grep -Fq "Allow all router ports" 'luci-ikev2-manager/settings.js'
grep -Fq "routerPorts.disabled = !allowRouter.checked || allowAllRouterPorts.checked" \
	'luci-ikev2-manager/settings.js'
grep -Fq "Keep LuCI and SSH ports in this list" 'luci-ikev2-manager/settings.js'
grep -Fq '"/usr/libexec/ikev2-devices zones": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-devices clients": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async set-exclusions *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async set-included *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async clear-policy *": [ "exec" ]' "$acl"
grep -Fq 'set-included | clear-policy)' \
	'ikev2-manager-runtime/ikev2-manager-system.sh'
grep -Fq 'set-exclusions)' 'ikev2-manager-runtime/ikev2-manager-system.sh'
grep -Fq 'set-exclusions)   cmd_set_exclusions' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq 'set-included)     cmd_set_included' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq 'clear-policy)     cmd_clear_policy' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq "common.choiceWithCustom(choices.length" 'luci-ikev2-manager/setup.js'
grep -Fq "common.multiChoiceWithCustom(access.lan_zones" \
	'luci-ikev2-manager/settings.js'
grep -Fq "addressPlanPicker" 'luci-ikev2-manager/settings.js'
grep -Fq "choiceWithCustom" 'luci-ikev2-manager/client.js'
grep -Fq "choiceWithCustom(value.wan_interface" 'luci-ikev2-manager/setup.js'
grep -Fq "renderDevicePolicies(data[3].stdout, data[4].stdout, data[5].stdout)" \
	'luci-ikev2-manager/setup.js'
grep -Fq "[ 'set-exclusions', entry.addr" 'luci-ikev2-manager/setup.js'
if grep -Fq "self.renderFlagExemptions(" 'luci-ikev2-manager/setup.js' ||
   grep -Fq "self.renderExceptions(" 'luci-ikev2-manager/setup.js'; then
	printf '%s\n' 'setup still renders separate device exception lists' >&2
	exit 1
fi
grep -Fq "E('option', { 'value': customValue }" 'luci-ikev2-manager/shared.js'
grep -Fq "Date.now() + 120000" 'luci-ikev2-domains/editor.js'
grep -Fq "common.showProgress(result, st.message);" 'luci-ikev2-domains/editor.js'
for phase in \
	'Preparing selected domain lists...' \
	'Downloading selected service lists...' \
	'Building the combined policy list...' \
	'Restarting policy routing...'; do
	grep -Fq "$phase" 'luci-ikev2-domains/community-domains.sh'
done

# Prepared and custom services use narrow ACL entries and independent files;
# they must not fall back to the common free-form domain list.
grep -Fq '"/usr/libexec/ikev2-domains-community services": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-domains-community service-read *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-domains-community service-schedule *": [ "exec" ]' "$acl"
grep -Fq '"/tmp/ikev2-service-input-*.meta": [ "write" ]' "$acl"
grep -Fq "common.execChecked(communityHelper, [ 'service-read', record.id ]" \
	'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('save')" 'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('reset')" 'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('delete')" 'luci-ikev2-domains/editor.js'
grep -Fq "_('Manage services')" 'luci-ikev2-domains/editor.js'
grep -Fq "'selected=' + (operation === 'delete' ? '0' : 'keep')" \
	'luci-ikev2-domains/editor.js'
grep -Fq 'function runPageAction(options)' 'luci-ikev2-domains/editor.js'
grep -Fq "_('Discard unsaved service changes?')" 'luci-ikev2-domains/editor.js'
if grep -Fq "common.fieldLabel(_('Enabled in policy'))" \
	'luci-ikev2-domains/editor.js'; then
	printf '%s\n' 'service editor must not bypass the page-level policy save' >&2
	exit 1
fi
if grep -Eq 'ikev2-chip-(edit|wrap)' \
	'luci-ikev2-domains/editor.js' 'luci-ikev2-manager/shared.js'; then
	printf '%s\n' 'per-service edit controls must not be rendered inside service chips' >&2
	exit 1
fi
grep -Fq 'user_services_dir="${IKEV2_USER_SERVICES_DIR:-/etc/ikev2-manager/services.d}"' \
	'luci-ikev2-domains/community-domains.sh'

# LuCI requests a view resource with its own version in the query string, and
# that version does not move when this package is upgraded. A view whose file
# name never changes is therefore served from the browser cache after an
# upgrade - which is how three reworked pages reached a router and kept showing
# the previous layout. Every view resource must carry a -vN suffix, and the
# menu must point at the same name the package installs.
menu="luci-ikev2-manager/menu.json"
for path in $(sed -n 's/.*"path": "\(ikev2-[^"]*\)".*/\1/p' "$menu"); do
	case "$path" in
		*-v[0-9]*) ;;
		*)
			printf 'menu view %s has no cache-busting suffix\n' "$path" >&2
			exit 1
			;;
	esac
	grep -Fq "/www/luci-static/resources/view/$path.js" Makefile || {
		printf 'menu view %s is not installed by the Makefile\n' "$path" >&2
		exit 1
	}
done
# The same applies to the shared module, and it is the one that got missed: the
# views were renamed while every page still required the static "shared", so a
# router served new page code against cached stylesheet rules and laid the
# controls out with selectors that no longer existed.
required="$(sed -n "s/^'require \(ikev2-manager\.shared[^ ]*\) as common';$/\1/p" \
	luci-ikev2-manager/*.js luci-ikev2-domains/*.js | sort -u)"
[ -n "$required" ] || {
	printf 'no page requires the shared module any more\n' >&2
	exit 1
}
[ "$(printf '%s\n' "$required" | wc -l | tr -d ' ')" = 1 ] || {
	printf 'pages require different builds of the shared module:\n%s\n' "$required" >&2
	exit 1
}
case "$required" in
	*-v[0-9]*) ;;
	*)
		printf 'the shared module %s has no cache-busting suffix\n' "$required" >&2
		exit 1
		;;
esac
shared_file="$(printf '%s' "$required" | tr '.' '/')"
grep -Fq "/www/luci-static/resources/$shared_file.js" Makefile || {
	printf 'the required shared module %s is not installed by the Makefile\n' "$required" >&2
	exit 1
}
printf 'LuCI resource naming OK\n'

printf '%s\n' 'luci UI contract OK'
