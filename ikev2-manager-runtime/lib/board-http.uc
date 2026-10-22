{%
'use strict';
import { readfile, writefile, rename, mkdir, lsdir, stat, unlink, open } from 'fs';

// The office board, served by its own uhttpd instance on the LAN address.
// Nothing an HTTP caller sends chooses a path: requests are named by the
// router, and pictures by the request and their number.
const board_dir = '/etc/ikev2-manager/board';
const requests_dir = board_dir + '/requests';
const services_file = '/var/run/ikev2-board/services.json';
const limit_dir = '/var/run/ikev2-board/limits';
const max_body = 8 * 1024 * 1024, max_pictures = 3, max_picture = 2 * 1024 * 1024, max_kept = 200;

function translation(env) {
	let language = substr(env.HTTP_ACCEPT_LANGUAGE ?? '', 0, 2);
	// LuCI's own catalogue, where LuCI is installed; English without it.
	let luci = null;
	try { luci = require('luci.core'); } catch (error) { luci = null; }
	if (luci && language == 'ru' && luci.load_catalog('ru', '/usr/lib/lua/luci/i18n') && luci.change_catalog('ru'))
		return (text) => luci.translate(text) ?? text;
	return (text) => text;
}

function send(status, type, body, extra) {
	uhttpd.send(sprintf('Status: %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n', status, type));
	uhttpd.send('X-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n');
	if (extra) uhttpd.send(extra);
	uhttpd.send(sprintf('Connection: close\r\nContent-Length: %d\r\n\r\n%s', length(body), body));
}

function send_json(status, value) {
	send(status, 'application/json', sprintf('%J\n', value));
}

function clean(value, size) {
	if (type(value) != 'string') return '';
	// Line breaks stay; every other control character goes.
	value = trim(join("\n", map(split(value, "\n"), (line) => replace(line, /[[:cntrl:]]/g, ""))));
	return substr(value, 0, size);
}

function requests() {
	let list = [];
	for (let name in (lsdir(requests_dir) ?? [])) {
		if (!match(name, /^[0-9a-f-]+\.json$/)) continue;
		let request = null;
		try { request = json(readfile(requests_dir + '/' + name)); } catch (error) { continue; }
		push(list, request);
	}
	return sort(list, (a, b) => b.created - a.created);
}

// What anyone on the network sees of a request: what does not open and where
// it stands, not who asked.
function public_view(request) {
	return { id: request.id, created: request.created, resource: request.resource, status: request.status, note: request.note ?? '' };
}

// Ten requests in ten minutes from one address; the rest wait.
function allowed(address) {
	mkdir('/var/run/ikev2-board');
	mkdir(limit_dir);
	let name = limit_dir + '/' + replace(address ?? 'unknown', /[^0-9a-fA-F.:]/g, '_');
	let now = time(), stamps = filter(split(trim(readfile(name) ?? ''), '\n'), (s) => s != '' && now - +s < 600);
	if (length(stamps) >= 10) return false;
	push(stamps, `${now}`);
	writefile(name, join('\n', stamps) + '\n');
	return true;
}

function prune() {
	let list = requests();
	for (let i = max_kept; i < length(list); i++) {
		let id = list[i].id;
		unlink(requests_dir + '/' + id + '.json');
		for (let n = 1; n <= max_pictures; n++) {
			unlink(sprintf('%s/%s.%d.png', requests_dir, id, n));
			unlink(sprintf('%s/%s.%d.jpg', requests_dir, id, n));
		}
	}
}

function new_id() {
	let random = open('/dev/urandom', 'r');
	let bytes = random ? random.read(6) : `${time()}`;
	if (random) random.close();
	let hex = '';
	for (let i = 0; i < length(bytes); i++) hex += sprintf('%02x', ord(bytes, i));
	return sprintf('%d-%s', time(), hex);
}

function submit(env) {
	let size = +(env.CONTENT_LENGTH ?? 0);
	if (size <= 0 || size > max_body) return send_json('413 Payload Too Large', { error: 'too_large' });
	if (!allowed(env.REMOTE_ADDR)) return send_json('429 Too Many Requests', { error: 'too_many' });
	let body = '', chunk;
	while (length(body) < size && (chunk = uhttpd.recv(min(65536, size - length(body)))) != null && length(chunk))
		body += chunk;
	let input = null;
	try { input = json(body); } catch (error) { input = null; }
	if (type(input) != 'object') return send_json('400 Bad Request', { error: 'invalid' });
	let request = {
		id: new_id(), created: time(), status: 'new', note: '',
		name: clean(input.name, 100), email: clean(input.email, 200),
		resource: clean(input.resource, 200), link: clean(input.link, 500), problem: clean(input.problem, 4000),
		address: env.REMOTE_ADDR ?? '', pictures: 0
	};
	if (request.name == '' || request.resource == '' || request.problem == '')
		return send_json('400 Bad Request', { error: 'missing' });
	mkdir('/etc/ikev2-manager');
	mkdir(board_dir);
	mkdir(requests_dir);
	let pictures = type(input.pictures) == 'array' ? slice(input.pictures, 0, max_pictures) : [];
	for (let picture in pictures) {
		let data = type(picture) == 'string' ? b64dec(picture) : null;
		if (data == null || length(data) > max_picture) continue;
		// By byte value: older ucode reads "\x89" in a literal as a character, not a byte.
		let kind = ord(data, 0) == 0x89 && substr(data, 1, 3) == 'PNG' ? 'png' : ord(data, 0) == 0xff && ord(data, 1) == 0xd8 && ord(data, 2) == 0xff ? 'jpg' : null;
		if (!kind) continue;
		request.pictures++;
		writefile(sprintf('%s/%s.%d.%s', requests_dir, request.id, request.pictures, kind), data);
	}
	let path = requests_dir + '/' + request.id + '.json';
	if (!writefile(path + '.new', sprintf('%J\n', request)) || !rename(path + '.new', path))
		return send_json('503 Service Unavailable', { error: 'store' });
	prune();
	system(['start-stop-daemon', '-b', '-q', '-S', '-x', '/usr/libexec/ikev2-board', '--', 'notify', request.id]);
	send_json('200 OK', public_view(request));
}

function page(env) {
	let _ = translation(env);
	let text = {
		title: _('Office services'), lead: _('These services go through the tunnel. Open one to see its domains.'),
		own: _('Other domains'), request: _('Something does not open'), name: _('Your name'), email: _('Work e-mail (optional)'),
		resource: _('Service or site'), link: _('Link'), problem: _('What does not work'), pictures: _('Screenshots: paste with Ctrl+V or drop here, up to 3'),
		send: _('Send request'), sent: _('Request sent. Its status is shown below.'), failed: _('The request was not sent.'),
		missing: _('Fill in your name, the service and what does not work.'), requests: _('Requests'), none: _('No requests yet.'),
		new: _('New'), working: _('In progress'), done: _('Done'), rejected: _('Not ours'), loading: _('Loading...'), empty: _('No services.'),
		domains: _('domains')
	};
	let nonce = new_id();
	let html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${text.title}</title><style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--line:#d9dde3;--muted:#667;--accent:#0067c0}
@media (prefers-color-scheme:dark){:root{--bg:#16181c;--card:#1f2228;--line:#343943;--muted:#9aa3ad;--accent:#4ea1ff}}
body{margin:0;background:var(--bg);font:15px/1.5 system-ui,sans-serif}main{max-width:820px;margin:0 auto;padding:16px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:0 0 16px}
h1{font-size:22px;margin:8px 0}h2{font-size:17px;margin:0 0 10px}p{color:var(--muted);margin:0 0 12px}
details{border-top:1px solid var(--line);padding:8px 0}summary{cursor:pointer}details ul{columns:2;margin:6px 0;padding-left:18px;color:var(--muted);font-size:13px}
label{display:block;margin:10px 0 4px;color:var(--muted);font-size:13px}input,textarea{box-sizing:border-box;width:100%;font:inherit;padding:8px;border:1px solid var(--line);border-radius:6px;background:transparent;color:inherit}
textarea{min-height:100px}button{margin-top:12px;font:inherit;padding:8px 16px;border:0;border-radius:6px;background:var(--accent);color:#fff;cursor:pointer}
.shots{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}.shots img{height:64px;border:1px solid var(--line);border-radius:4px;cursor:pointer}
.drop{border:1px dashed var(--line);border-radius:6px;padding:10px;color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:6px 4px;border-top:1px solid var(--line)}.pill{font-size:12px;padding:2px 8px;border-radius:10px;border:1px solid var(--line);white-space:nowrap}
.msg{margin-top:8px;font-size:14px}</style></head><body><main>
<h1>${text.title}</h1><section><p>${text.lead}</p><div id="services">${text.loading}</div></section>
<section><h2>${text.request}</h2><form id="form">
<label>${text.name}</label><input name="name" maxlength="100" autocomplete="name">
<label>${text.email}</label><input name="email" type="email" maxlength="200" autocomplete="email">
<label>${text.resource}</label><input name="resource" maxlength="200">
<label>${text.link}</label><input name="link" maxlength="500" placeholder="https://">
<label>${text.problem}</label><textarea name="problem" maxlength="4000"></textarea>
<div class="drop" id="drop" tabindex="0">${text.pictures}<div class="shots" id="shots"></div></div>
<button type="submit">${text.send}</button><div class="msg" id="msg"></div></form></section>
<section><h2>${text.requests}</h2><div id="requests">${text.loading}</div></section></main>
<script nonce="${nonce}">
const T=${sprintf('%J', text)};const shots=[];
const el=(t,a,...c)=>{const e=document.createElement(t);Object.assign(e,a||{});c.forEach(x=>e.append(x));return e};
async function load(){
 const s=await fetch('/board/services').then(r=>r.json()).catch(()=>null),box=document.getElementById('services');box.textContent='';
 const list=s?s.services.slice():[];if(s&&s.own.length)list.push({label:T.own,domains:s.own});
 if(!list.length)box.textContent=T.empty;
 list.forEach(x=>box.append(el('details',{},el('summary',{},x.label+' · '+x.domains.length+' '+T.domains),el('ul',{},...x.domains.map(d=>el('li',{textContent:d}))))));
 const q=await fetch('/board/requests').then(r=>r.json()).catch(()=>[]),rb=document.getElementById('requests');rb.textContent='';
 if(!q.length){rb.textContent=T.none;return}
 rb.append(el('table',{},...q.map(r=>el('tr',{},el('td',{textContent:new Date(r.created*1000).toLocaleString()}),el('td',{textContent:r.resource+(r.note?' — '+r.note:'')}),el('td',{},el('span',{className:'pill',textContent:T[r.status]||r.status}))))));
}
function add(file){if(!file||!/^image\\/(png|jpeg)$/.test(file.type)||file.size>2097152||shots.length>=3)return;
 const rd=new FileReader();rd.onload=()=>{const data=rd.result.split(',')[1];shots.push(data);const img=el('img',{src:rd.result,title:'x'});
 img.onclick=()=>{shots.splice(shots.indexOf(data),1);img.remove()};document.getElementById('shots').append(img)};rd.readAsDataURL(file)}
document.addEventListener('paste',e=>[...e.clipboardData.files].forEach(add));
const drop=document.getElementById('drop');drop.ondragover=e=>e.preventDefault();drop.ondrop=e=>{e.preventDefault();[...e.dataTransfer.files].forEach(add)};
document.getElementById('form').onsubmit=async e=>{e.preventDefault();const f=e.target,msg=document.getElementById('msg'),b=f.querySelector('button');
 const body={name:f.name.value,email:f.email.value,resource:f.resource.value,link:f.link.value,problem:f.problem.value,pictures:shots};
 if(!body.name.trim()||!body.resource.trim()||!body.problem.trim()){msg.textContent=T.missing;return}
 b.disabled=true;const r=await fetch('/board/requests',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}).catch(()=>null);b.disabled=false;
 if(r&&r.ok){msg.textContent=T.sent;f.reset();shots.length=0;document.getElementById('shots').textContent='';load()}else msg.textContent=T.failed};
load();
</script></body></html>`;
	send('200 OK', 'text/html; charset=utf-8', html,
		`Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; img-src data:; script-src 'nonce-${nonce}'\r\n`);
}

global.handle_request = function(env) {
	let path = replace(env.REQUEST_URI ?? '', /\?.*$/, '');
	if (env.REQUEST_METHOD == 'GET' && (path == '/board' || path == '/board/')) return page(env);
	if (env.REQUEST_METHOD == 'GET' && path == '/board/services') {
		let services = readfile(services_file);
		return services ? send('200 OK', 'application/json', services) : send_json('200 OK', { services: [], own: [] });
	}
	if (env.REQUEST_METHOD == 'GET' && path == '/board/requests')
		return send_json('200 OK', map(slice(requests(), 0, 30), public_view));
	if (env.REQUEST_METHOD == 'POST' && path == '/board/requests') return submit(env);
	send_json('404 Not Found', { error: 'not_found' });
};
%}
