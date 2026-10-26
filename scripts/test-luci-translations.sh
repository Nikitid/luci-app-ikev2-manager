#!/bin/sh

# Every string the pages pass through the translator must have a Russian
# entry in po/ru/ikev2-manager.po, and no entry may be defined twice. A missing
# one shows an English label in the middle of a Russian page - which is how
# "Device policy runtime" and "FakeIP allocator" reached a screenshot - and a
# duplicate means one of the two translations is dead and nobody can tell which.
#
# LuCI looks a string up after collapsing its whitespace, so an entry whose id
# keeps leading, trailing or doubled spaces can never be found. The catalog is
# compiled by scripts/po2lmo.py, which must match LuCI's po2lmo byte for byte.

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
catalog="$root/po/ru/ikev2-manager.po"

node - "$root" "$catalog" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const [ root, catalog ] = process.argv.slice(2);

function unquote(line) {
	return JSON.parse(line.slice(line.indexOf('"')));
}

// Collect msgid -> msgstr, joining continuation lines.
const entries = new Map();
const duplicates = [];
let id = null, str = null, field = null;
function flush() {
	if (id) {
		if (entries.has(id))
			duplicates.push(id);
		entries.set(id, str);
	}
	id = str = field = null;
}
fs.readFileSync(catalog, 'utf8').split('\n').forEach(function(line) {
	if (line.startsWith('msgid ')) { flush(); id = unquote(line); field = 'id'; }
	else if (line.startsWith('msgstr ')) { str = unquote(line); field = 'str'; }
	else if (line.startsWith('"') && field === 'id') id += unquote(line);
	else if (line.startsWith('"') && field === 'str') str += unquote(line);
	else if (line.startsWith('msgctxt') || line.startsWith('msgid_plural'))
		throw new Error('unsupported catalog construct: ' + line);
});
flush();

const problems = [];
if (duplicates.length)
	problems.push('duplicate entries:\n  ' + duplicates.join('\n  '));

const trimws = (s) => String(s).trim().replace(/[ \t\n]+/g, ' ');
const unmatchable = [ ...entries.keys() ].filter((k) => trimws(k) !== k);
if (unmatchable.length)
	problems.push('entries LuCI can never match (whitespace):\n  ' + unmatchable.join('\n  '));
const empty = [ ...entries.entries() ].filter(([ , v ]) => !v).map(([ k ]) => k);
if (empty.length)
	problems.push('entries without a translation:\n  ' + empty.join('\n  '));

const sources = [
	'luci-ikev2-manager/shared.js', 'luci-ikev2-manager/client.js',
	'luci-ikev2-manager/setup.js', 'luci-ikev2-manager/settings.js',
	'luci-ikev2-manager/users.js', 'luci-ikev2-manager/status-widget.js',
	'luci-ikev2-manager/remote-clients.js', 'luci-ikev2-manager/tunnels.js', 'luci-ikev2-manager/dns.js',
	'luci-ikev2-domains/editor.js', 'ikev2-manager-runtime/lib/board-http.uc'
];
const missing = [];
let total = 0;
sources.forEach(function(name) {
	const src = fs.readFileSync(path.join(root, name), 'utf8');
	const seen = new Set();
	const call = /\b_\('((?:[^'\\]|\\.)*)'\)/g;
	let hit;
	while ((hit = call.exec(src)) !== null)
		seen.add(hit[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\'));
	total += seen.size;
	seen.forEach(function(text) {
		if (!entries.has(trimws(text)))
			missing.push(name + ': ' + text);
	});
});

// Menu titles are translated by LuCI from the same catalog.
const menu = JSON.parse(fs.readFileSync(path.join(root, 'luci-ikev2-manager/menu.json'), 'utf8'));
Object.values(menu).forEach(function(node) {
	if (node.title && !entries.has(node.title))
		missing.push('menu.json: ' + node.title);
});

if (missing.length)
	problems.push('untranslated strings:\n  ' + missing.join('\n  '));
if (problems.length) {
	process.stderr.write(problems.join('\n') + '\n');
	process.exit(1);
}
process.stdout.write('translation coverage OK: ' + total + ' strings, ' + entries.size + ' entries\n');
JS

# Status messages written by the runtime reach the page through _() too: an
# action result, a domain-router state or a dependency step. A literal one
# without a catalog entry shows up in English on a Russian page.
python3 - "$root" "$catalog" <<'PY'
import glob, json, re, sys
root, catalog = sys.argv[1:]
ids = set(json.loads(line[6:]) for line in open(catalog, encoding='utf-8')
          if line.startswith('msgid "'))
writers = re.compile(
    r'''\b(?:action_status\s+"\$[A-Za-z_]+"|deps_status|write_status|'''
    r'''write_simple_status\s+"\$[A-Za-z_]+")\s+'''
    r'''(?:running|ok|error|active|disabled|paused|warn)\s+'''
    r'''(?:\\\s*\n\s*)?(?:'([^']+)'|"([^"$`\\]+)")''')
missing = set()
for pattern in ('ikev2-manager-runtime/*.sh', 'ikev2-manager-runtime/lib/*.sh',
                'luci-ikev2-manager/*.sh', 'luci-ikev2-domains/*.sh'):
    for path in glob.glob(root + '/' + pattern):
        for match in writers.finditer(open(path, encoding='utf-8').read()):
            text = match.group(1) or match.group(2)
            if text not in ids:
                missing.add(path.split('/')[-1] + ': ' + text)
if missing:
    sys.exit('untranslated runtime status messages:\n  ' + '\n  '.join(sorted(missing)))
PY

# The compiler must reproduce LuCI's hash. These values come from sfh_hash in
# LuCI's lmo.c, run on the same input.
python3 - "$root" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from po2lmo import sfh_hash
expected = {
    'Overview': 0xadbaae97,
    'Надёжный режим': 0xaed5b217,
    'abc': 0xd2be198a,
    'Inherited from the global groups: %s': 0x965998a3,
}
for text, value in expected.items():
    data = text.encode()
    got = sfh_hash(data, len(data))
    if got != value:
        sys.exit('po2lmo hash differs from LuCI for %r: %#010x' % (text, got))
PY

# When the reference tool is installed, compare whole catalogs.
if command -v po2lmo >/dev/null 2>&1; then
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	po2lmo "$catalog" "$tmp/reference.lmo"
	python3 "$root/scripts/po2lmo.py" "$catalog" "$tmp/ours.lmo"
	cmp -s "$tmp/reference.lmo" "$tmp/ours.lmo" || {
		printf '%s\n' 'po2lmo.py output differs from LuCI po2lmo' >&2
		exit 1
	}
fi
