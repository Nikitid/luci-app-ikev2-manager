{%
'use strict';
import { readfile, writefile, rename, mkdir, lsdir, stat, unlink, open } from 'fs';

// The services board, served by its own uhttpd instance on the LAN address.
// Nothing an HTTP caller sends chooses a path: requests are named by the
// router, and pictures by the request and their number.
const board_dir = '/etc/ikev2-manager/board';
const requests_dir = board_dir + '/requests';
const services_file = '/var/run/ikev2-board/services.json';
const limit_dir = '/var/run/ikev2-board/limits';
const refresh_stamp = '/var/run/ikev2-board/refresh';
const icons_dir = '/var/run/ikev2-board/icons';
const icon_types = { png: 'image/png', ico: 'image/x-icon', jpg: 'image/jpeg', gif: 'image/gif' };
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
	// Nothing is kept by the browser unless the answer says how long.
	let cache = index(extra ?? '', 'Cache-Control:') >= 0 ? '' : 'Cache-Control: no-store\r\n';
	uhttpd.send(sprintf('Status: %s\r\nContent-Type: %s\r\n%sX-Content-Type-Options: nosniff\r\n', status, type, cache));
	uhttpd.send('X-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n');
	if (extra) uhttpd.send(extra);
	// The body goes on its own: a format's %s ends a picture or a font at
	// its first zero byte.
	uhttpd.send(sprintf('Connection: close\r\nContent-Length: %d\r\n\r\n', length(body)));
	uhttpd.send(body);
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

// The look of the page: light and dark from the system; on a wide screen the
// services on the left and asking for help on the right, one column on a
// phone. Warm paper and soft graphite, one quiet cool accent, thin headings,
// cards with quiet borders. No gradients and no capitals for emphasis.
const style = `
:root{color-scheme:light dark;--bg:#f7f6f2;--surface:#fffefa;--raised:#fafaf7;--line:#dfe2da;--text:#30382f;--muted:#697266;--faint:#8a9187;--accent:#5d6d94;--accent-soft:#e3e7ef;--ok:#5d7356;--ok-soft:#e5ebe1;--bad:#a2524c;--bad-soft:#f3e3e0;--warn:#8f6b2e;--warn-soft:#f2eadb;--shadow:0 1px 2px #2934290d,0 8px 24px #2934290a}
@media (prefers-color-scheme:dark){:root{--bg:#232524;--surface:#2e302f;--raised:#353836;--line:#404341;--text:#e5e6e5;--muted:#adb0ad;--faint:#8f938f;--accent:#a9b4c9;--accent-soft:#363c46;--ok:#a9b4a3;--ok-soft:#323832;--bad:#d9a19b;--bad-soft:#40302e;--warn:#d6bb86;--warn-soft:#3d3628;--shadow:0 1px 2px #0000002e,0 8px 24px #0000001f}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI Variable Text","Segoe UI",Roboto,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1120px;margin:0 auto;padding:36px 20px 56px}
header{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:14px 28px;margin-bottom:26px}
h1{font-size:30px;line-height:1.2;font-weight:300;letter-spacing:-.01em;margin:0}h2{font-size:17px;font-weight:500;margin:0 0 4px}
.sub{color:var(--muted);margin:6px 0 0;max-width:46ch}
.state{display:inline-flex;align-items:center;gap:9px;padding:7px 14px;border-radius:999px;border:1px solid var(--line);background:var(--surface);font-size:14px;color:var(--muted)}
.state b{font-weight:500;color:var(--text)}.state.ok .dot{color:var(--ok)}.state.bad .dot{color:var(--bad)}.state.warn .dot{color:var(--warn)}
.dot{width:8px;height:8px;border-radius:50%;background:currentColor;flex:none;display:inline-block}
.layout{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:28px;align-items:start}
aside{position:sticky;top:20px;display:flex;flex-direction:column;gap:18px}
@media (max-width:900px){.layout{grid-template-columns:1fr}aside{position:static}}
.search{position:relative;margin:0 0 12px}.search input{width:100%;padding:12px 14px 12px 42px;font:inherit;border:1px solid var(--line);border-radius:12px;background:var(--surface);color:inherit}
.search input:focus,.field input:focus,.field textarea:focus{outline:2px solid var(--accent);outline-offset:-1px;border-color:transparent}
.search svg{position:absolute;left:14px;top:50%;transform:translateY(-50%);color:var(--faint)}
.hint{min-height:22px;margin:0 0 12px;color:var(--muted);font-size:14px;display:flex;flex-wrap:wrap;align-items:center;gap:6px}.hint b{color:var(--text);font-weight:500}
.group{margin:0 0 8px;color:var(--faint);font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:10px}
.svc{background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);min-width:0;transition:border-color .15s}
.svc:hover{border-color:color-mix(in srgb,var(--accent) 35%,var(--line))}
.svc.open{grid-column:1/-1}
.top{display:flex;align-items:center;gap:12px;width:100%;padding:12px 14px;cursor:pointer;background:none;border:0;color:inherit;font:inherit;text-align:left;border-radius:14px}
.top:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.mark{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;flex:none;background:var(--raised);border:1px solid var(--line);overflow:hidden;font-weight:500;font-size:14px;color:var(--muted)}
.mark img{width:26px;height:26px;object-fit:contain}
.name{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meta{color:var(--muted);font-size:13px;display:flex;align-items:center;gap:6px}.meta .dot{width:7px;height:7px}
.up{color:var(--ok)}.down{color:var(--bad)}
.more{padding:0 14px 14px;display:flex;flex-direction:column;gap:12px}
.chips{display:flex;flex-wrap:wrap;gap:6px;max-height:220px;overflow:auto}
.chip{font-size:13px;padding:2px 9px;border-radius:999px;border:1px solid var(--line);color:var(--muted)}.chip.hit{border-color:var(--accent);color:var(--accent)}
.outline{font:inherit;font-size:14px;padding:7px 13px;border-radius:10px;border:1px solid var(--line);background:transparent;color:var(--accent);cursor:pointer}
.outline:hover{border-color:var(--accent)}.outline:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.empty{color:var(--muted);padding:28px;text-align:center;grid-column:1/-1;border:1px dashed var(--line);border-radius:14px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:18px;box-shadow:var(--shadow)}
.lead{color:var(--muted);margin:0 0 14px;font-size:14px}
.form{display:grid;gap:12px}
.field{position:relative}
.field input,.field textarea{width:100%;font:inherit;padding:18px 12px 7px;border:1px solid var(--line);border-radius:10px;background:var(--raised);color:inherit}
.field textarea{min-height:104px;resize:vertical;padding-top:22px}
.field label{position:absolute;left:12px;top:13px;color:var(--faint);font-size:14px;pointer-events:none;transition:all .15s}
.field input:focus+label,.field input:not(:placeholder-shown)+label,.field textarea:focus+label,.field textarea:not(:placeholder-shown)+label{top:5px;font-size:11.5px;color:var(--muted)}
.drop{border:1px dashed var(--line);border-radius:10px;padding:12px;color:var(--muted);font-size:13px;text-align:center;cursor:pointer}
.drop.over{border-color:var(--accent);color:var(--accent)}
.shots{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}.shots:not(:empty){margin-top:10px}.shots img{height:60px;border-radius:8px;border:1px solid var(--line);cursor:pointer}
.actions{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
button.send{font:inherit;font-weight:500;padding:9px 16px;border-radius:10px;border:1px solid var(--accent);background:transparent;color:var(--accent);cursor:pointer}
button.send:hover{background:var(--accent-soft)}button:disabled{opacity:.55;cursor:default}
.msg{font-size:14px}.msg.ok{color:var(--ok)}.msg.bad{color:var(--bad)}
.reqs{display:flex;flex-direction:column}.req{display:flex;gap:10px;align-items:flex-start;justify-content:space-between;padding:10px 0;border-top:1px solid var(--line)}.req:first-child{border-top:0;padding-top:0}
.req .what{font-weight:500}.req .note{color:var(--muted);font-size:14px}.req time{color:var(--faint);font-size:12.5px;display:block}
.pill{font-size:12px;padding:2px 9px;border-radius:999px;white-space:nowrap;border:1px solid var(--line);color:var(--muted)}
.pill.new{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 40%,var(--line))}.pill.working{color:var(--accent);border-color:color-mix(in srgb,var(--accent) 40%,var(--line))}.pill.done{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 40%,var(--line))}
.none{color:var(--muted);font-size:14px}
footer{color:var(--faint);font-size:12.5px;margin-top:30px;text-align:center}
@media (prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}
`;

// What the page does: the services as cards with their state, a search that
// also tells whether a site goes through the tunnel, and the request form.
const script = `
const shots=[];let data=null,openId=null;
const $=id=>document.getElementById(id);
const el=(t,a,...c)=>{const e=document.createElement(t);Object.assign(e,a||{});c.forEach(x=>x!=null&&e.append(x));return e};
function initials(s){const w=s.replace(/[^\\p{L}\\p{N} ]/gu,' ').trim().split(/\\s+/);return ((w[0]||'?')[0]+(w[1]?w[1][0]:(w[0]||'').slice(1,2))).toUpperCase()}
function fmt(t,n){return t.replace('%d',n)}
function covers(domain,q){return q===domain||q.endsWith('.'+domain)}
function site(q){q=q.trim().toLowerCase().replace(/^[a-z]+:\\/\\//,'').replace(/[\\/:?#].*$/,'');return /^[a-z0-9.-]+\\.[a-z]{2,}$/.test(q)?q:''}
function render(){
 const box=$('services'),q=$('q').value.trim().toLowerCase(),host=site(q),hint=$('hint');box.textContent='';hint.textContent='';
 if(!data){box.append(el('div',{className:'empty',textContent:T.failed_load}));return}
 const list=data.services.slice();if(data.own.length)list.push({id:'-own',label:T.own,domains:data.own,up:data.tunnel});
 let shown=0,found=null;
 for(const s of list){
  const nameHit=s.label.toLowerCase().includes(q),hits=q?s.domains.filter(d=>d.includes(q)||(host&&covers(d,host))):[];
  if(host&&!found&&s.domains.some(d=>covers(d,host)))found=s;
  if(q&&!nameHit&&!hits.length)continue;shown++;
  const open=openId===s.id||(q&&hits.length&&!nameHit);
  const card=el('div',{className:'svc'+(open?' open':'')});
  const mark=el('span',{className:'mark',textContent:initials(s.label)});
  // The icon the router fetched from the service's site; the initials stay where there is none.
  if(s.id!=='-own'){const img=el('img',{alt:'',decoding:'async'});img.onload=()=>{mark.textContent='';mark.append(img)};img.src='/board/icon/'+encodeURIComponent(s.id)}
  const top=el('button',{className:'top',type:'button','aria-expanded':open?'true':'false'},mark,
   el('span',{style:'min-width:0'},el('div',{className:'name',textContent:s.label}),
    el('div',{className:'meta'},el('span',{className:'dot '+(s.up?'up':'down')}),el('span',{textContent:(s.up?T.works:T.down)+' · '+fmt(T.domains,s.domains.length)}))));
  top.setAttribute('aria-expanded',open?'true':'false');
  top.onclick=()=>{openId=openId===s.id?null:s.id;render()};card.append(top);
  if(open){const more=el('div',{className:'more'},el('div',{className:'chips'},...(hits.length?hits.concat(s.domains.filter(d=>!hits.includes(d))):s.domains).map(d=>el('span',{className:'chip'+(hits.includes(d)?' hit':''),textContent:d}))));
   if(s.id!=='-own'){const ask=el('button',{className:'outline',type:'button',textContent:T.ask});ask.onclick=()=>{$('resource').value=s.label;$('ask').scrollIntoView({behavior:'smooth',block:'start'});$('problem').focus()};more.append(el('div',{},ask))}
   card.append(more)}
  box.append(card);
 }
 if(!shown&&!(host&&!found))box.append(el('div',{className:'empty',textContent:q?T.nothing:T.empty}));
 if(host&&found)hint.append(el('b',{textContent:host}),' '+T.through+' ',el('b',{textContent:found.label}));
 if(host&&!found){const add=el('button',{className:'outline',type:'button',textContent:T.ask_add});
  add.onclick=()=>{$('resource').value=host;$('link').value=$('q').value.trim();$('ask').scrollIntoView({behavior:'smooth',block:'start'});$('problem').focus()};
  hint.append(el('b',{textContent:host}),' '+T.direct+' ',add)}
}
function state(){
 const b=$('state');b.textContent='';if(!data)return;
 const all=data.services.length,up=data.services.filter(s=>s.up).length;
 const cls=!data.tunnel?'bad':up<all?'warn':'ok';
 const text=cls==='bad'?T.all_down:cls==='warn'?T.some.replace('%d',up).replace('%d',all):T.all_up;
 b.className='state '+cls;b.append(el('span',{className:'dot'}),el('b',{textContent:text}));
 $('updated').textContent=fmt(T.updated,new Date(data.updated*1000).toLocaleString());
}
async function load(){
 data=await fetch('/board/services').then(r=>r.json()).catch(()=>null);state();render();
 const q=await fetch('/board/requests').then(r=>r.json()).catch(()=>[]),rb=$('requests');rb.textContent='';
 if(!q.length){rb.append(el('div',{className:'none',textContent:T.none}));return}
 q.forEach(r=>rb.append(el('div',{className:'req'},el('div',{},el('div',{className:'what',textContent:r.resource}),r.note?el('div',{className:'note',textContent:r.note}):null,el('time',{textContent:new Date(r.created*1000).toLocaleString()})),el('span',{className:'pill '+r.status,textContent:T[r.status]||r.status}))));
}
function add(file){if(!file||!/^image\\/(png|jpeg)$/.test(file.type)||file.size>2097152||shots.length>=3)return;
 const rd=new FileReader();rd.onload=()=>{const data=rd.result.split(',')[1];shots.push(data);const img=el('img',{src:rd.result,title:T.remove,alt:''});
 img.onclick=()=>{shots.splice(shots.indexOf(data),1);img.remove()};$('shots').append(img)};rd.readAsDataURL(file)}
document.addEventListener('paste',e=>[...e.clipboardData.files].forEach(add));
const drop=$('drop');drop.ondragover=e=>{e.preventDefault();drop.classList.add('over')};drop.ondragleave=()=>drop.classList.remove('over');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('over');[...e.dataTransfer.files].forEach(add)};
const pick=$('pick');drop.onclick=()=>pick.click();pick.onchange=()=>{[...pick.files].forEach(add);pick.value=''};
$('q').oninput=render;
$('form').onsubmit=async e=>{e.preventDefault();const f=e.target,msg=$('msg'),b=f.querySelector('button[type=submit]');
 const body={name:f.name.value,email:f.email.value,resource:f.resource.value,link:f.link.value,problem:f.problem.value,pictures:shots};
 msg.className='msg bad';
 if(!body.name.trim()||!body.resource.trim()||!body.problem.trim()){msg.textContent=T.missing;return}
 b.disabled=true;msg.textContent='';const r=await fetch('/board/requests',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}).catch(()=>null);b.disabled=false;
 if(r&&r.ok){msg.className='msg ok';msg.textContent=T.sent;f.reset();shots.length=0;$('shots').textContent='';load()}else msg.textContent=r&&r.status===429?T.too_many:T.failed};
load();setInterval(load,60000);
`;

function page(env) {
	let _ = translation(env);
	let text = {
		title: _('Network services'), lead: _('Services that go through the tunnel on this network, and whether they work now.'),
		search: _('Find a service or check a site'), own: _('Other sites'), domains: _('%d domains'),
		works: _('Works'), down: _('Unavailable'), all_up: _('All services work'), all_down: _('The tunnel is down: services are unavailable'),
		some: _('%d of %d services work'), through: _('goes through the tunnel as'), direct: _('is not in the tunnel: it opens the ordinary way.'),
		nothing: _('Nothing found.'), empty: _('No services yet.'), failed_load: _('The list of services could not be loaded.'),
		ask: _('Does not open'), ask_add: _('Ask to add it'), updated: _('Updated %d'),
		request: _('Something does not open'), request_lead: _('Say what you tried to open and what happened. The request is kept on this router and its status is shown below.'),
		name: _('Your name'), email: _('E-mail (optional)'), resource: _('Service or site'), link: _('Link'), problem: _('What does not work'),
		pictures: _('Screenshots: paste with Ctrl+V, drop here or click to choose, up to 3'), remove: _('Click to remove'),
		send: _('Send request'), sent: _('Request sent. Its status is shown below.'), failed: _('The request was not sent.'),
		too_many: _('Too many requests from this device. Try again in a few minutes.'),
		missing: _('Fill in your name, the service and what does not work.'), requests: _('Requests'), none: _('No requests yet.'),
		new: _('New'), working: _('In progress'), done: _('Done'), rejected: _('Not ours')
	};
	let nonce = new_id(), lang = substr(env.HTTP_ACCEPT_LANGUAGE ?? '', 0, 2) == 'ru' ? 'ru' : 'en';
	let search = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>';
	let field = (id, label, extra) => `<div class="field"><input id="${id}" name="${id}" placeholder=" " ${extra}><label for="${id}">${label}</label></div>`;
	let html = `<!doctype html><html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${text.title}</title><style>${style}</style></head><body><main>
<header><div><h1>${text.title}</h1><p class="sub">${text.lead}</p></div><div class="state" id="state">${_('Loading...')}</div></header>
<div class="layout"><section>
<div class="search">${search}<input id="q" type="search" placeholder="${text.search}" aria-label="${text.search}" autocomplete="off"></div>
<div class="hint" id="hint"></div><div class="grid" id="services"></div></section>
<aside><section class="card" id="ask"><h2>${text.request}</h2><p class="lead">${text.request_lead}</p><form id="form" class="form">
${field('name', text.name, 'maxlength="100" autocomplete="name"')}
${field('email', text.email, 'type="email" maxlength="200" autocomplete="email"')}
${field('resource', text.resource, 'maxlength="200"')}
${field('link', text.link, 'maxlength="500"')}
<div class="field"><textarea id="problem" name="problem" placeholder=" " maxlength="4000"></textarea><label for="problem">${text.problem}</label></div>
<div class="drop" id="drop" tabindex="0" role="button">${text.pictures}<input id="pick" type="file" accept="image/png,image/jpeg" multiple hidden><div class="shots" id="shots"></div></div>
<div class="actions"><button class="send" type="submit">${text.send}</button><span class="msg" id="msg" role="status"></span></div></form></section>
<section class="card"><h2>${text.requests}</h2><div class="reqs" id="requests"></div></section></aside></div>
<footer id="updated"></footer></main>
<script nonce="${nonce}">const T=${sprintf('%J', text)};${script}</script></body></html>`;
	send('200 OK', 'text/html; charset=utf-8', html,
		`Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; script-src 'nonce-${nonce}'\r\n`);
}

// The snapshot is made when the board starts; a page asked for later sets off
// a new one in the background once it is a few minutes old, so services the
// owner added or a tunnel that went down show up without a restart.
function refresh() {
	let made = stat(services_file)?.mtime ?? 0, asked = stat(refresh_stamp)?.mtime ?? 0, now = time();
	if (now - made < 120 || now - asked < 60) return;
	writefile(refresh_stamp, '');
	system(['start-stop-daemon', '-b', '-q', '-S', '-x', '/usr/libexec/ikev2-board', '--', 'snapshot']);
}

global.handle_request = function(env) {
	let path = replace(env.REQUEST_URI ?? '', /\?.*$/, '');
	if (env.REQUEST_METHOD == 'GET' && (path == '/board' || path == '/board/')) return page(env);
	if (env.REQUEST_METHOD == 'GET' && path == '/board/services') {
		refresh();
		let services = readfile(services_file);
		return services ? send('200 OK', 'application/json', services) : send_json('200 OK', { updated: time(), tunnel: false, services: [], own: [] });
	}
	// A service's icon as the router fetched it from the service's own site.
	let icon = length(path) <= 76 ? match(path, /^\/board\/icon\/([a-z0-9_.-]+)$/) : null;
	if (env.REQUEST_METHOD == 'GET' && icon) {
		for (let kind, type in icon_types) {
			let data = readfile(sprintf('%s/%s.%s', icons_dir, icon[1], kind), 65536);
			if (data != null) return send('200 OK', type, data, 'Cache-Control: max-age=86400\r\n');
		}
		return send_json('404 Not Found', { error: 'no_icon' });
	}
	if (env.REQUEST_METHOD == 'GET' && path == '/board/requests')
		return send_json('200 OK', map(slice(requests(), 0, 30), public_view));
	if (env.REQUEST_METHOD == 'POST' && path == '/board/requests') return submit(env);
	send_json('404 Not Found', { error: 'not_found' });
};
%}
