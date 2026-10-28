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
const fonts_dir = '/www/luci-static/resources/ikev2-manager/fonts';
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
// phone. Warm paper by day and graphite at night, one patina accent, a thin
// large heading over denser text, cards held by a hairline edge rather than a
// shadow. The typeface is Onest, served by the router itself.
const style = `
@font-face{font-family:Onest;font-style:normal;font-weight:100 900;font-display:swap;src:url(/board/font/onest-cyrillic.woff2) format('woff2');unicode-range:U+0301,U+0400-045F,U+0490-0491,U+04B0-04B1,U+2116}
@font-face{font-family:Onest;font-style:normal;font-weight:100 900;font-display:swap;src:url(/board/font/onest-latin.woff2) format('woff2');unicode-range:U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD}
:root{color-scheme:light dark;--bg:oklch(0.962 0.006 85);--sunken:oklch(0.940 0.007 85);--surface:oklch(0.985 0.004 85);--line:oklch(0.885 0.008 85);--line-strong:oklch(0.800 0.010 85);--text:oklch(0.250 0.012 250);--text-2:oklch(0.430 0.012 250);--text-3:oklch(0.520 0.010 250);--accent:oklch(0.500 0.075 195);--accent-text:oklch(0.440 0.070 195);--accent-soft:oklch(0.930 0.020 195);--success:oklch(0.470 0.085 150);--warning:oklch(0.480 0.090 75);--danger:oklch(0.480 0.130 28);--lit:rgb(255 255 255/.75);--ease:cubic-bezier(.22,1,.36,1)}
@media (prefers-color-scheme:dark){:root{--bg:oklch(0.225 0.005 255);--sunken:oklch(0.195 0.005 255);--surface:oklch(0.265 0.006 255);--line:oklch(0.350 0.008 255);--line-strong:oklch(0.450 0.010 255);--text:oklch(0.935 0.004 255);--text-2:oklch(0.760 0.008 255);--text-3:oklch(0.665 0.008 255);--accent:oklch(0.760 0.070 195);--accent-text:oklch(0.790 0.070 195);--accent-soft:oklch(0.320 0.032 195);--success:oklch(0.770 0.090 150);--warning:oklch(0.810 0.100 82);--danger:oklch(0.740 0.120 28);--lit:rgb(255 255 255/.055)}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:340 15.5px/1.55 Onest,-apple-system,"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
b{font-weight:480}
main{max-width:1160px;margin:0 auto;padding:56px 24px 72px}
header{margin-bottom:40px}
h1{font-size:clamp(40px,6vw,60px);line-height:1.04;font-weight:200;letter-spacing:-.025em;margin:0}
h2{font-size:28px;line-height:1.1;font-weight:200;letter-spacing:-.015em;margin:0 0 10px}
.rule{height:1px;background:var(--line);margin:18px 0 10px}.rule.bad{background:color-mix(in srgb,var(--danger) 55%,transparent)}
.status{display:flex;flex-wrap:wrap;justify-content:space-between;gap:4px 24px;font-size:12.5px;font-weight:400;color:var(--text-3);font-variant-numeric:tabular-nums}
.status #state{color:var(--text-2)}.status .bad{color:var(--danger)}.status #state.warn{color:var(--warning)}
.layout{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:40px;align-items:start}
aside{position:sticky;top:24px;display:flex;flex-direction:column;gap:24px}
@media (max-width:900px){.layout{grid-template-columns:1fr}aside{position:static}main{padding:32px 16px 56px}header{margin-bottom:28px}}
.search{position:relative;margin:0 0 16px}.search input{width:100%;padding:12px 14px 12px 42px;font:inherit;border:1px solid var(--line-strong);border-radius:5px;background:var(--surface);color:inherit}
.search input::placeholder{color:var(--text-3)}
.search input:focus,.field input:focus,.field textarea:focus{outline:2px solid var(--accent);outline-offset:-1px;border-color:transparent}
.search svg{position:absolute;left:14px;top:50%;transform:translateY(-50%);color:var(--text-3)}
.hint:empty{display:none}.hint{min-height:22px;margin:0 0 14px;color:var(--text-2);font-size:14px;display:flex;flex-wrap:wrap;align-items:center;gap:6px}.hint b{color:var(--text)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px}
.svc{background:var(--surface);border-radius:8px;box-shadow:0 0 0 1px var(--line),inset 0 1px 0 var(--lit);min-width:0;transition:box-shadow 140ms var(--ease)}
.svc:hover{box-shadow:0 0 0 1px var(--line-strong),inset 0 1px 0 var(--lit)}
.svc.open{grid-column:1/-1}
.top{display:flex;align-items:center;gap:12px;width:100%;padding:12px 14px;cursor:pointer;background:none;border:0;color:inherit;font:inherit;text-align:left;border-radius:8px}
.top:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.mark{width:36px;height:36px;border-radius:5px;display:grid;place-items:center;flex:none;background:var(--sunken);box-shadow:inset 0 0 0 1px var(--line);overflow:hidden;font-weight:450;font-size:13px;color:var(--text-2)}
.mark img{width:24px;height:24px;object-fit:contain}
.name{font-weight:480;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meta{color:var(--text-3);font-size:13px;font-weight:400;font-variant-numeric:tabular-nums}
.down{color:var(--danger)}
.more{padding:2px 14px 14px;display:flex;flex-direction:column;gap:12px}
.chips{display:flex;flex-wrap:wrap;gap:6px;max-height:220px;overflow:auto}
.chip{font-size:13px;font-weight:400;padding:2px 10px;border-radius:999px;border:1px solid var(--line);color:var(--text-2)}.chip.hit{border-color:var(--accent);background:var(--accent-soft);color:var(--accent-text)}
.outline{font:inherit;font-size:14px;font-weight:450;padding:7px 14px;border-radius:5px;border:1px solid var(--line-strong);background:transparent;color:var(--text);cursor:pointer;transition:background-color 140ms var(--ease),border-color 140ms var(--ease)}
.outline:hover{background:var(--accent-soft);border-color:var(--accent)}.outline:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.empty{color:var(--text-2);padding:28px 0;grid-column:1/-1}
.card{background:var(--surface);border-radius:8px;padding:22px;box-shadow:0 0 0 1px var(--line),inset 0 1px 0 var(--lit)}
.lead{color:var(--text-2);margin:0 0 18px;font-size:14px}
.form{display:grid;gap:10px}
.field{position:relative}
.field input,.field textarea{width:100%;font:inherit;padding:19px 12px 6px;border:1px solid var(--line-strong);border-radius:5px;background:var(--bg);color:inherit}
.field textarea{min-height:104px;resize:vertical;padding-top:23px}
.field label{position:absolute;left:12px;top:13px;color:var(--text-3);font-size:15px;pointer-events:none;transform-origin:0 0;transition:transform 140ms var(--ease),color 140ms var(--ease)}
.field input:focus+label,.field input:not(:placeholder-shown)+label,.field textarea:focus+label,.field textarea:not(:placeholder-shown)+label{transform:translateY(-8px) scale(.78);color:var(--text-2)}
.drop{border:1px dashed var(--line-strong);border-radius:5px;padding:12px;color:var(--text-3);font-size:13px;font-weight:400;cursor:pointer}
.drop.over{border-color:var(--accent);background:var(--accent-soft);color:var(--accent-text)}
.drop:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.shots{display:flex;gap:8px;flex-wrap:wrap}.shots:not(:empty){margin-top:10px}.shots img{height:60px;border-radius:5px;box-shadow:0 0 0 1px var(--line);cursor:pointer}
.actions{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:4px}
button.send{font:inherit;font-weight:480;padding:9px 18px;border-radius:5px;border:1.5px solid var(--accent);background:transparent;color:var(--accent-text);cursor:pointer;transition:background-color 140ms var(--ease)}
button.send:hover{background:var(--accent-soft)}button.send:focus-visible{outline:2px solid var(--accent);outline-offset:2px}button:disabled{opacity:.55;cursor:default}
.msg{font-size:14px}.msg.ok{color:var(--success)}.msg.bad{color:var(--danger)}
.reqs{display:flex;flex-direction:column}.req{display:flex;gap:10px;align-items:flex-start;justify-content:space-between;padding:12px 0;border-top:1px solid var(--line)}.req:first-child{border-top:0;padding-top:2px}
.req .what{font-weight:480}.req .note{color:var(--text-2);font-size:14px}.req time{color:var(--text-3);font-size:12.5px;font-weight:400;display:block;font-variant-numeric:tabular-nums}
.pill{font-size:12.5px;font-weight:450;padding:1px 10px;border-radius:999px;white-space:nowrap;border:1px solid var(--line);color:var(--text-2)}
.pill.new{color:var(--warning);border-color:currentColor}.pill.working{color:var(--accent-text);background:var(--accent-soft);border-color:var(--accent)}.pill.done{color:var(--success);border-color:currentColor}
.none{color:var(--text-3);font-size:14px}
@keyframes rise{from{opacity:0;transform:translateY(10px)}}
header,.layout>section,aside>*{animation:rise 520ms var(--ease) backwards}.layout>section{animation-delay:55ms}aside>:first-child{animation-delay:110ms}aside>:last-child{animation-delay:165ms}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important;scroll-behavior:auto!important}}
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
    el('div',{className:'meta'},s.up?'':el('span',{className:'down',textContent:T.down+' · '}),fmt(T.domains,s.domains.length))));
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
// The state of the page is a line of text under the heading: the norm in
// grey on the right, and colour only when something is wrong.
function ago(t){const m=Math.max(0,Math.round((Date.now()/1000-t)/60));return m<1?T.just_now:m<60?fmt(T.min_ago,m):fmt(T.h_ago,Math.round(m/60))}
function state(){
 const what=$('what'),b=$('state'),rule=$('rule');what.className='';b.className='';rule.className='rule';
 if(!data){what.textContent=T.failed_load;what.className='bad';rule.className='rule bad';b.textContent='';return}
 const down=data.services.filter(s=>!s.up),age=ago(data.updated),old=Date.now()/1000-data.updated>900;
 what.textContent=T.lead;b.textContent=T.all_up+' · '+age;
 if(!data.tunnel){what.textContent=T.all_down;what.className='bad';rule.className='rule bad';b.textContent=age}
 else if(down.length){what.textContent=T.not_answering.replace('%s',down.slice(0,3).map(s=>s.label).join(', ')+(down.length>3?' …':''));what.className='bad';rule.className='rule bad';b.textContent=(down.length<data.services.length?T.rest_work+' · ':'')+age}
 if(old){b.textContent=T.stale+' · '+T.last_data.replace('%s',new Date(data.updated*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));b.className='warn'}
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
		down: _('Unavailable'), all_up: _('All work'), all_down: _('The tunnel is down: services are unavailable'),
		through: _('goes through the tunnel as'), direct: _('is not in the tunnel: it opens the ordinary way.'),
		nothing: _('Nothing found.'), empty: _('No services yet.'), failed_load: _('The list of services could not be loaded.'),
		ask: _('Does not open'), ask_add: _('Ask to add it'), just_now: _('just now'), min_ago: _('%d min ago'), h_ago: _('%d h ago'),
		not_answering: _('Not answering: %s'), rest_work: _('the rest work'), stale: _('No fresh data'), last_data: _('last data %s'),
		request: _('Something does not open'), request_lead: _('Say what you tried to open and what happened. The request is kept on this router and its status is shown below.'),
		name: _('Your name'), email: _('E-mail (optional)'), resource: _('Service or site'), link: _('Link'), problem: _('What does not work'),
		pictures: _('Screenshots: paste with Ctrl+V, drop here or click to choose, up to 3'), remove: _('Click to remove'),
		send: _('Send request'), sent: _('Request sent. Its status is shown below.'), failed: _('The request was not sent.'),
		too_many: _('Too many requests from this device. Try again in a few minutes.'),
		missing: _('Fill in your name, the service and what does not work.'), requests: _('Requests'), none: _('No requests yet.'),
		new: _('New'), working: _('In progress'), done: _('Done'), rejected: _('Not ours')
	};
	let nonce = new_id(), lang = substr(env.HTTP_ACCEPT_LANGUAGE ?? '', 0, 2) == 'ru' ? 'ru' : 'en';
	let search = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/></svg>';
	let field = (id, label, extra) => `<div class="field"><input id="${id}" name="${id}" placeholder=" " ${extra}><label for="${id}">${label}</label></div>`;
	let html = `<!doctype html><html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${text.title}</title><style>${style}</style></head><body><main>
<header><h1>${text.title}</h1><div class="rule" id="rule"></div><div class="status"><span id="what">${text.lead}</span><span id="state">${_('Checking...')}</span></div></header>
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
</main>
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
	// The page's typeface, as the router pages have it.
	let font = length(path) <= 40 ? match(path, /^\/board\/font\/(onest-(latin|cyrillic)\.woff2)$/) : null;
	if (env.REQUEST_METHOD == 'GET' && font) {
		let data = readfile(fonts_dir + '/' + font[1]);
		return data != null ? send('200 OK', 'font/woff2', data, 'Cache-Control: max-age=604800\r\n') : send_json('404 Not Found', { error: 'no_font' });
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
