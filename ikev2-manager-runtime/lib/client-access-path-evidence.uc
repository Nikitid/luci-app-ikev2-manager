// Require the active local proxy, kernel program and publication to agree.
'use strict';
import { open, lstat, readfile, readlink } from 'fs';
import { sha256 } from 'digest';

export function protected_file(path, limit) {
	let info = lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1 || info.size > limit)
		die('unsafe path evidence');
	let file = open(path, 're');
	if (!file) die('missing path evidence');
	let body = file.read(limit + 1);
	file.close();
	if (type(body) != 'string' || length(body) > limit) die('oversized path evidence');
	return body;
};

export function require_current_client_path(directory, plan, fingerprint) {
	let info = lstat(directory);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700)
		die('unsafe runtime directory');
	let proof = json(protected_file(directory + '/path-ready.json', 4096));
	let expected = [ 'version', 'generation', 'exit', 'config_sha256', 'nft_sha256', 'proxy_pid', 'proxy_start' ];
	if (type(proof) != 'object' || length(keys(proof)) != length(expected)) die('invalid readiness proof');
	for (let key in expected) if (!(key in proof)) die('incomplete readiness proof');
	if (proof.version !== 1 || type(proof.generation) != 'int' || proof.generation < 1 ||
		proof.generation !== plan.generation || proof.exit !== plan.exit ||
		type(proof.proxy_pid) != 'int' || proof.proxy_pid < 2 || proof.proxy_pid > 2147483647 ||
		type(proof.proxy_start) != 'string' || !match(proof.proxy_start, /^[0-9]+$/) ||
		type(proof.config_sha256) != 'string' || !(length(proof.config_sha256) == 64 ? match(proof.config_sha256, /^[a-f0-9]+$/) : null) ||
		type(proof.nft_sha256) != 'string' || !(length(proof.nft_sha256) == 64 ? match(proof.nft_sha256, /^[a-f0-9]+$/) : null) ||
		proof.nft_sha256 != fingerprint) die('stale readiness proof');
	let config_path = directory + '/proxy.json';
	if (sha256(protected_file(config_path, 16777216)) != proof.config_sha256)
		die('changed proxy configuration');
	let process = '/proc/' + proof.proxy_pid;
	if (lstat(process)?.uid != 0 || readlink(process + '/exe') != '/usr/bin/sing-box')
		die('unowned proxy process');
	let command = split(readfile(process + '/cmdline') ?? '', chr(0));
	if (length(command) != 5 || command[1] != 'run' || command[2] != '-c' || command[3] != config_path || command[4] != '')
		die('different proxy process');
	let stats = split(readfile(process + '/stat') ?? '', ' ');
	if (stats[1] != '(sing-box)' || stats[21] != proof.proxy_start || stats[2] == 'Z')
		die('dead or replaced proxy process');
	return true;
};
