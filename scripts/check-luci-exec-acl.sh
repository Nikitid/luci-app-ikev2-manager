#!/bin/sh
#
# Every helper subcommand a page names must be granted in acl.json, and every
# grant must be named by a page.
#
# rpcd matches the executable and its argument string as one ACL key, and it
# snapshots a session's grants when the session is created. A subcommand added
# without its grant fails at runtime with a bare "Permission denied" on the one
# page that reaches it, which is invisible to every other check here. A grant
# nobody names is standing privilege left behind by a removed feature.
#
# Commands are matched by name rather than by call site on purpose: they are
# passed as literal arrays, through wrappers, and out of ternaries, and a
# checker that tried to parse each shape would miss the next one silently.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

node - "$root" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

const problems = [];
const acl = JSON.parse(fs.readFileSync(
	path.join(root, 'luci-ikev2-manager', 'acl.json'), 'utf8'));

const execGrants = [];
const readExecGrants = [];
const writeGlobs = [];
Object.keys(acl).forEach(function(group) {
	[ 'read', 'write' ].forEach(function(section) {
		const files = (acl[group][section] || {}).file || {};
		Object.keys(files).forEach(function(key) {
			const perms = files[key] || [];
			if (perms.indexOf('exec') >= 0) { execGrants.push(key); if (section === 'read') readExecGrants.push(key); }
			if (perms.indexOf('write') >= 0) writeGlobs.push(key);
		});
	});
});

// Invitation creation and consumption expose a one-use secret. Match actual
// ACL glob semantics, including broader grants, rather than JSON formatting.
for (const command of ['client-admin-invite', 'client-admin-take-invitation']) {
 const target = '/usr/libexec/ikev2-client-admin ' + command + ' 123-456';
 for (const grant of readExecGrants) {
  const expression = '^' + grant.split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$';
  if (new RegExp(expression).test(target)) problems.push('read-only ACL exposes administrative invitation command: ' + command);
 }
}

const sources = [];
[ 'luci-ikev2-manager', 'luci-ikev2-domains' ].forEach(function(dir) {
	const full = path.join(root, dir);
	fs.readdirSync(full).filter(function(name) {
		return name.endsWith('.js');
	}).forEach(function(name) {
		sources.push({ name: dir + '/' + name,
			text: fs.readFileSync(path.join(full, name), 'utf8') });
	});
});
const allText = sources.map(function(entry) { return entry.text; }).join('\n');

// Words that look like subcommands but are not: they name a mode, a state or a
// UI value that never reaches a helper.
const notCommands = new Set([
	'load-balance', 'fastest-addr', 'new-password', 'dns-query'
]);

// A subcommand named by a page: the first element of an argument array, or one
// arm of a ternary that picks between two of them. The array has to be an
// argument or an assignment - `value['child-sas']` is a property read, not a
// command - and a kebab name owned by the stylesheet is never one either.
const named = new Map();
function isCommandName(word) {
	return word.indexOf('cbi-') !== 0 && word.indexOf('ikev2-') !== 0;
}
sources.forEach(function(source) {
	let match;
	const inArray = /(?:^|[(,:=?]|\breturn)\s*\[\s*'([a-z][a-z0-9]*(?:-[a-z0-9]+)+)'/gm;
	while ((match = inArray.exec(source.text)))
		if (isCommandName(match[1]) && !named.has(match[1]))
			named.set(match[1], source.name);
	const ternary = /\?\s*'([a-z][a-z0-9]*(?:-[a-z0-9]+)+)'\s*:\s*'([a-z][a-z0-9]*(?:-[a-z0-9]+)+)'/g;
	while ((match = ternary.exec(source.text)))
		[ match[1], match[2] ].forEach(function(word) {
			if (isCommandName(word) && !named.has(word))
				named.set(word, source.name);
		});
});

function grantWords(key) {
	return key.split(' ').slice(1).filter(function(word) { return word !== '*'; });
}
const grantedWords = new Set();
execGrants.forEach(function(key) {
	grantWords(key).forEach(function(word) { grantedWords.add(word); });
});

named.forEach(function(where, command) {
	if (notCommands.has(command) || grantedWords.has(command))
		return;
	// Only flag a name that looks like it is meant for a helper: it has to
	// appear next to one of them in the same file.
	const source = sources.filter(function(entry) { return entry.name === where; })[0];
	if (!/\/usr\/libexec\/ikev2-/.test(source.text))
		return;
	problems.push(where + ': names "' + command +
		'" with no ACL grant, so it fails with Permission denied');
});

execGrants.forEach(function(key) {
	const missing = grantWords(key).filter(function(word) {
		return allText.indexOf("'" + word + "'") < 0;
	});
	if (missing.length)
		problems.push('acl.json grants "' + key + '" that no page names');
});

// rpcd resolves a path before it checks the ACL, and OpenWrt symlinks /var to
// /tmp. A grant written against /var/... therefore never matches the path rpcd
// actually tests, and every write through it is refused - while session.access
// on the same string answers true, because that one compares literally. Grant
// the canonical form alongside it.
const symlinked = { '/var/': '/tmp/' };
writeGlobs.forEach(function(glob) {
	Object.keys(symlinked).forEach(function(prefix) {
		if (glob.indexOf(prefix) !== 0)
			return;
		const canonical = symlinked[prefix] + glob.slice(prefix.length);
		if (writeGlobs.indexOf(canonical) < 0)
			problems.push('acl.json grants "' + glob + '" but not "' + canonical +
				'", which is the path rpcd resolves it to and actually checks');
	});
});

// fs.write targets must be covered by a write grant.
function globMatches(glob, value) {
	return new RegExp('^' + glob.split('*').map(function(part) {
		return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	}).join('.*') + '$').test(value);
}
sources.forEach(function(source) {
	let match;
	const write = /fs\.write\(\s*'([^']+)'/g;
	while ((match = write.exec(source.text))) {
		const prefix = match[1];
		if (writeGlobs.some(function(glob) {
			return globMatches(glob, prefix + 'TOKEN.in') || globMatches(glob, prefix);
		})) continue;
		problems.push(source.name + ': writes ' + prefix +
			'... with no write grant covering it');
	}
});

if (problems.length) {
	problems.forEach(function(line) { process.stderr.write(line + '\n'); });
	process.exit(1);
}
process.stdout.write('LuCI exec ACL checks OK: ' + execGrants.length +
	' grants, ' + named.size + ' named commands\n');
JS
