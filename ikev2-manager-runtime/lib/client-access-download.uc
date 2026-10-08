// The page a person sees when they open their link in a browser: where to
// get Waypoint for the computer in front of them, and what to do with the
// link. Nothing here knows the link - its secret part never reaches a server -
// and nothing is read from the request but the browser's own description.
'use strict';
import { readfile } from 'fs';

const RELEASES = 'https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v';

function platform(agent) {
	if (type(agent) != 'string' || length(agent) > 512) return 'other';
	if (match(agent, /iPhone|iPad|iPod|Android/)) return 'phone';
	if (match(agent, /Windows NT/)) return 'windows';
	if (match(agent, /Macintosh|Mac OS X/)) return 'macos';
	return 'other';
}

export function client_download_page(env) {
	let version = replace(readfile('/usr/share/ikev2-manager/version') ?? '', /\s+$/, '');
	if (!match(version, /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/)) return null;
	let headers = env.headers ?? {}, system = platform(headers['user-agent']);
	let russian = type(headers['accept-language']) == 'string' && length(headers['accept-language']) <= 256 && match(headers['accept-language'], /^ru|[, ]ru/) != null;
	let text = russian ? {
		title: 'Waypoint: доступ к сервисам', lead: 'Эта ссылка регистрирует ваш компьютер. Установите Waypoint и вставьте её в программу.',
		windows: 'Скачать для Windows', macos: 'Скачать для macOS', other: 'Другая система:',
		phone: 'Waypoint работает на компьютерах с Windows и macOS. Откройте эту ссылку на компьютере; для телефона попросите у администратора VPN-профиль.',
		steps: [ 'Скачайте и установите Waypoint.', 'Откройте Waypoint и нажмите «Регистрация».', 'Вставьте адрес этой страницы целиком - скопируйте его из адресной строки браузера.' ],
		note: 'Ссылка действует ограниченное время и только для ваших устройств. Не пересылайте её.', version: 'Версия'
	} : {
		title: 'Waypoint: access to services', lead: 'This link registers your computer. Install Waypoint and paste the link into it.',
		windows: 'Download for Windows', macos: 'Download for macOS', other: 'Another system:',
		phone: 'Waypoint runs on Windows and macOS computers. Open this link on a computer; for a phone, ask your administrator for a VPN profile.',
		steps: [ 'Download and install Waypoint.', 'Open Waypoint and press Registration.', 'Paste the whole address of this page - copy it from the address bar of the browser.' ],
		note: 'The link works for a limited time and only for your devices. Do not forward it.', version: 'Version'
	};
	let files = { windows: RELEASES + version + '/WaypointSetup.exe', macos: RELEASES + version + '/Waypoint-' + version + '.pkg' };
	let button = (name, main) => `<a class="${main ? 'main' : 'plain'}" href="${files[name]}" rel="noreferrer">${text[name]}</a>`;
	let offer;
	if (system == 'phone') offer = `<p>${text.phone}</p>`;
	else if (system == 'windows' || system == 'macos') {
		let second = system == 'windows' ? 'macos' : 'windows';
		offer = `<p>${button(system, true)}</p><p class="soft">${text.other} ${button(second, false)}</p>`;
	} else offer = `<p>${button('windows', true)} ${button('macos', true)}</p>`;
	let steps = system == 'phone' ? '' : '<ol>' + join('', map(text.steps, step => `<li>${step}</li>`)) + '</ol>';
	return { system: system, html: `<!doctype html><html lang="${russian ? 'ru' : 'en'}"><head><meta charset="utf-8">` +
		'<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><meta name="referrer" content="no-referrer">' +
		`<title>Waypoint</title><style>body{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#f5f5f7;color:#1c1c1e}` +
		'main{max-width:34rem;margin:8vh auto;padding:2rem;background:#fff;border-radius:14px;box-shadow:0 1px 3px rgba(0,0,0,.12)}h1{font-size:1.4rem;margin:0 0 .5rem}' +
		'a.main{display:inline-block;padding:.7rem 1.2rem;margin:.3rem .4rem .3rem 0;border-radius:9px;background:#0067c0;color:#fff;text-decoration:none;font-weight:600}' +
		'a.plain{color:#0067c0}.soft{color:#6e6e73;font-size:.9rem}ol{padding-left:1.2rem}li{margin:.3rem 0}' +
		'@media(prefers-color-scheme:dark){body{background:#1e1e20;color:#f0f0f2}main{background:#2c2c2e;box-shadow:none}.soft{color:#a0a0a6}a.plain{color:#6cb4ff}}</style></head>' +
		`<body><main><h1>${text.title}</h1><p>${text.lead}</p>${offer}${steps}<p class="soft">${text.note}</p><p class="soft">${text.version} ${version}</p></main></body></html>\n` };
};
