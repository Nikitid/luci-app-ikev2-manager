// What happened to remote clients and when: links issued, devices
// registered, opened, changed or removed, mail sent. For the administrator;
// it holds no secret and decides nothing.
'use strict';
import { open, lstat, readfile } from 'fs';

const PATH = '/etc/ikev2-manager/clients/journal.log';

// One word or name per field: nothing that could start a line of its own.
function clean(value) {
	let text = replace(sprintf('%s', value ?? ''), /[^A-Za-z0-9 ._@:,+-]/g, '');
	return length(text) > 120 ? substr(text, 0, 120) : text;
}

// Never fails the action it describes.
export function record_client_event(event, detail) {
	try {
		let lines = [];
		let info = lstat(PATH);
		if (info != null) {
			if (info.type != 'file' || info.uid != 0 || info.size > 262144) return;
			lines = filter(split(readfile(PATH) ?? '', '\n'), line => length(line));
		}
		push(lines, time() + ' ' + clean(event) + ' ' + clean(detail));
		if (length(lines) > 500) lines = slice(lines, length(lines) - 500);
		let file = open(PATH, 'w', 0600);
		if (file == null) return;
		file.write(join('\n', lines) + '\n');
		file.close();
	} catch (error) { }
};

export function read_client_events(limit) {
	let info = lstat(PATH);
	if (info == null || info.type != 'file' || info.uid != 0 || info.size > 262144) return [];
	let lines = filter(split(readfile(PATH) ?? '', '\n'), line => length(line)), result = [];
	for (let line in slice(lines, max(0, length(lines) - limit))) {
		let parts = match(line, /^([0-9]+) ([a-z-]+) (.*)$/);
		if (parts != null) push(result, { at: +parts[1], event: parts[2], detail: parts[3] });
	}
	return reverse(result);
};
