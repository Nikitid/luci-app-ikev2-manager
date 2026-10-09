// The page a person sees when they open their link in a browser: where to
// get Waypoint for the computer in front of them, and what to do with the
// link. Nothing here knows the link - its secret part never reaches a server:
// the page shows it in a field to copy by reading the browser's own address,
// on the person's machine. Nothing is read from the request but the browser's
// description of itself.
'use strict';
import { readfile, open } from 'fs';

const RELEASES = 'https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v';

function platform(agent) {
	if (type(agent) != 'string' || length(agent) > 512) return 'other';
	if (match(agent, /iPhone|iPad|iPod|Android/)) return 'phone';
	if (match(agent, /Windows NT/)) return 'windows';
	if (match(agent, /Macintosh|Mac OS X/)) return 'macos';
	return 'other';
}

// The program's icon: three lanes, one of them taken.
const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">' +
	'<stop offset="0" stop-color="#1660c9"/><stop offset="1" stop-color="#0a2e78"/></linearGradient></defs>' +
	'<rect x="4" y="4" width="56" height="56" rx="14" fill="url(#g)"/>' +
	'<rect x="17" y="21" width="30" height="4" rx="2" fill="#608ed6"/><rect x="17" y="39" width="30" height="4" rx="2" fill="#608ed6"/>' +
	'<rect x="17" y="30" width="25" height="4" rx="2" fill="#fff"/><path d="M48.5 32 41 26.2v11.6z" fill="#fff"/></svg>';

const TEXT = {
	ru: { title: 'Waypoint', lead: 'Доступ к рабочим сервисам. Эта ссылка регистрирует ваш компьютер: установите Waypoint и вставьте её в программу.',
		windows: 'Скачать для Windows', macos: 'Скачать для macOS', other: 'Другая система:',
		phone: 'Waypoint работает на компьютерах с Windows и macOS. Откройте эту ссылку на компьютере; для телефона попросите у администратора VPN-профиль.',
		install: 'Скачайте и установите Waypoint.', copy: 'Скопируйте ссылку регистрации:', paste: 'Откройте Waypoint, нажмите «Регистрация» и вставьте ссылку.',
		button: 'Скопировать', done: 'Скопировано', manual: 'Скопируйте адрес этой страницы целиком из адресной строки браузера.',
		partial: 'В адресе нет секретной части. Откройте ссылку из письма целиком.',
		note: 'Ссылка действует ограниченное время и только для ваших устройств. Не пересылайте её.', version: 'Версия', switch: 'English' },
	en: { title: 'Waypoint', lead: 'Access to work services. This link registers your computer: install Waypoint and paste the link into it.',
		windows: 'Download for Windows', macos: 'Download for macOS', other: 'Another system:',
		phone: 'Waypoint runs on Windows and macOS computers. Open this link on a computer; for a phone, ask your administrator for a VPN profile.',
		install: 'Download and install Waypoint.', copy: 'Copy the registration link:', paste: 'Open Waypoint, press Registration and paste the link.',
		button: 'Copy', done: 'Copied', manual: 'Copy the whole address of this page from the address bar of the browser.',
		partial: 'The address has no secret part. Open the link from the message in full.',
		note: 'The link works for a limited time and only for your devices. Do not forward it.', version: 'Version', switch: 'Русский' }
};

// What the page runs, on the person's machine only: it puts the address the
// browser holds into the field, copies it on request and switches language.
const SCRIPT = 'var d=document,r=d.documentElement;function q(s){return d.querySelectorAll(s)}' +
	'var whole=location.hash.length==65&&/^#[0-9a-f]+$/.test(location.hash);r.className=whole?"js":"js partial";' +
	'q("input").forEach(function(i){i.value=location.href;i.onfocus=function(){i.select()}});' +
	'q("button.copy").forEach(function(b){b.onclick=function(){var i=b.parentNode.querySelector("input"),t=b.textContent;' +
	'function ok(){b.textContent=b.getAttribute("data-done");setTimeout(function(){b.textContent=t},1600)}' +
	'function old(){i.focus();i.select();try{if(d.execCommand("copy"))ok()}catch(e){}}' +
	'if(navigator.clipboard)navigator.clipboard.writeText(i.value).then(ok,old);else old()}});' +
	'q("button.lang").forEach(function(b){b.onclick=function(){r.lang=r.lang=="ru"?"en":"ru"}});';

function nonce() {
	let source = open('/dev/urandom', 're'), raw = source?.read(16);
	source?.close();
	if (type(raw) != 'string' || length(raw) != 16) die('no randomness');
	return join('', map(split(raw, ''), byte => sprintf('%02x', ord(byte))));
}

function block(language, text, system, files) {
	let button = (name, main) => `<a class="${main ? 'main' : 'plain'}" href="${files[name]}" rel="noreferrer">${text[name]}</a>`;
	let offer;
	if (system == 'phone') offer = `<p>${text.phone}</p>`;
	else if (system == 'windows' || system == 'macos') {
		let second = system == 'windows' ? 'macos' : 'windows';
		offer = `<p>${button(system, true)}</p><p class="soft">${text.other} ${button(second, false)}</p>`;
	} else offer = `<p>${button('windows', true)} ${button('macos', true)}</p>`;
	let steps = system == 'phone' ? '' : `<ol><li>${text.install}</li>` +
		`<li><span class="scripted">${text.copy}</span><span class="plainly">${text.manual}</span>` +
		`<span class="link scripted"><input readonly spellcheck="false" aria-label="${text.copy}"><button class="copy" type="button" data-done="${text.done}">${text.button}</button></span>` +
		`<span class="warn">${text.partial}</span></li><li>${text.paste}</li></ol>`;
	return `<section lang="${language}"><header>${ICON}<h1>${text.title}</h1><button class="lang scripted" type="button">${text.switch}</button></header>` +
		`${system == 'phone' ? '' : `<p>${text.lead}</p>`}${offer}${steps}<p class="soft">${text.note}</p></section>`;
}

// Both languages are in the page; it opens in Russian and the person can
// switch. The request's language is not asked: the people these links go to
// read Russian, whatever their browser was installed in.
export function client_download_page(env) {
	let version = replace(readfile('/usr/share/ikev2-manager/version') ?? '', /\s+$/, '');
	if (!match(version, /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/)) return null;
	let headers = env.headers ?? {}, system = platform(headers['user-agent']), key = nonce();
	let files = { windows: RELEASES + version + '/WaypointSetup.exe', macos: RELEASES + version + '/Waypoint-' + version + '.pkg' };
	let icon = 'data:image/svg+xml,' + replace(replace(replace(ICON, /#/g, '%23'), /</g, '%3C'), />/g, '%3E');
	return { system: system, nonce: key, html: '<!doctype html><html lang="ru"><head><meta charset="utf-8">' +
		'<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><meta name="referrer" content="no-referrer">' +
		`<title>Waypoint</title><link rel="icon" type="image/svg+xml" href="${replace(icon, /"/g, "'")}">` +
		'<style>:root{--bg:#f5f5f7;--card:#fff;--ink:#1c1c1e;--soft:#6e6e73;--line:#d2d2d7;--field:#f5f5f7;--accent:#0f56b8;--warn:#b3261e}' +
		'@media(prefers-color-scheme:dark){:root{--bg:#1e1e20;--card:#2c2c2e;--ink:#f0f0f2;--soft:#a0a0a6;--line:#48484a;--field:#1e1e20;--accent:#3d8bff;--warn:#ff8a80}}' +
		'body{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;padding:0 16px;background:var(--bg);color:var(--ink)}' +
		'main{max-width:34rem;margin:8vh auto;padding:1.75rem 2rem;background:var(--card);border-radius:14px;box-shadow:0 1px 3px rgba(0,0,0,.12)}' +
		'header{display:flex;align-items:center;gap:.75rem;margin-bottom:.75rem}header svg{width:44px;height:44px;flex:none}h1{font-size:1.4rem;margin:0;flex:1}' +
		'a.main{display:inline-block;padding:.7rem 1.2rem;margin:.3rem .4rem .3rem 0;border-radius:9px;background:var(--accent);color:#fff;text-decoration:none;font-weight:600}' +
		'a.plain{color:var(--accent)}.soft{color:var(--soft);font-size:.9rem}ol{padding-left:1.2rem}li{margin:.5rem 0}' +
		'.link{display:flex;gap:.5rem;margin-top:.4rem}input{flex:1;min-width:0;padding:.55rem .7rem;border:1px solid var(--line);border-radius:8px;background:var(--field);color:var(--ink);font:13px ui-monospace,Menlo,Consolas,monospace}' +
		'button{font:inherit;cursor:pointer;border-radius:8px}button.copy{padding:.5rem .9rem;border:0;background:var(--accent);color:#fff;font-weight:600;white-space:nowrap}' +
		'button.lang{padding:.25rem .6rem;border:1px solid var(--line);background:none;color:var(--soft);font-size:.85rem}' +
		'a:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}' +
		'section{display:none}html[lang=ru] section[lang=ru],html[lang=en] section[lang=en]{display:block}' +
		'.scripted,.warn{display:none}.js span.scripted{display:block}.js span.link.scripted{display:flex}.js button.scripted{display:inline-block}.js .plainly{display:none}' +
		'.warn{color:var(--warn);font-size:.9rem;margin-top:.3rem}.partial .warn{display:block}html.partial span.link.scripted{display:none}</style></head>' +
		`<body><main>${block('ru', TEXT.ru, system, files)}${block('en', TEXT.en, system, files)}<p class="soft">v${version}</p></main>` +
		`<script nonce="${key}">${SCRIPT}</script></body></html>\n` };
};
