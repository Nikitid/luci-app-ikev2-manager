'use strict';
'require baseclass';
'require fs';

// Translations come from LuCI's catalog for the language LuCI is using: the
// package ships po/ru/ikev2-manager.po compiled to ikev2-manager.ru.lmo, and
// the global _() from cbi.js resolves it. Nothing here shadows or replaces it.

// LuCI marks the page with its active language.
function uiLocale() {
	var lang = (typeof document !== 'undefined' && document.documentElement &&
		document.documentElement.lang) || 'en';
	return lang.replace('_', '-');
}

function parseKeyValues(text) {
	var result = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var p = line.indexOf('=');
		if (p > 0)
			result[line.slice(0, p)] = line.slice(p + 1);
	});
	return result;
}

function parseSwanmon(result) {
	try {
		var parsed = JSON.parse((result && result.stdout) || '{}');
		return parsed.data || [];
	}
	catch (e) {
		return [];
	}
}

function formatBytes(value) {
	var n = Number(value || 0);
	var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return '%s %s'.format(i ? n.toFixed(1) : n.toFixed(0), units[i]);
}

function formatDuration(value) {
	var seconds = Number(value || 0);
	var days = Math.floor(seconds / 86400);
	var hours = Math.floor(seconds % 86400 / 3600);
	var minutes = Math.floor(seconds % 3600 / 60);
	if (days)
		return _('%dd %dh').format(days, hours);
	if (hours)
		return _('%dh %dm').format(hours, minutes);
	if (minutes)
		return _('%dm').format(minutes);
	return _('%ds').format(Math.max(0, seconds));
}

// Local date and time of a Unix timestamp in seconds, in LuCI's language.
function formatDateTime(seconds) {
	var date = new Date(Number(seconds || 0) * 1000);
	if (!Number(seconds) || isNaN(date.getTime()))
		return _('Unknown');
	return new Intl.DateTimeFormat(uiLocale(), {
		month: 'short',
		day: 'numeric',
		hour: '2-digit',
		minute: '2-digit'
	}).format(date);
}

function formatDate(value) {
	var date = new Date(value);
	if (isNaN(date.getTime()))
		return value || _('Unknown');
	return new Intl.DateTimeFormat(uiLocale(), {
		year: 'numeric',
		month: 'short',
		day: 'numeric'
	}).format(date);
}

function daysUntil(value) {
	var date = new Date(value);
	if (isNaN(date.getTime()))
		return null;
	return Math.ceil((date.getTime() - Date.now()) / 86400000);
}

var STYLE_ID = 'ikev2-manager-styles-v6';

var CSS = `
			/* A bare custom property is not an animatable type, so the
			   \`transition: --val\` on the gauge ring below did nothing and the
			   arc jumped to its new length. Registering it as a percentage is
			   what makes that transition real. */
			@property --val {
				syntax: "<number>";
				inherits: true;
				initial-value: 0;
			}

			.ikev2-page {
				--ikev2-accent: #4f7dff;
				--ikev2-accent-2: #8b5cf6;
				--ikev2-grad: linear-gradient(135deg, #4f7dff, #8b5cf6);
				--ikev2-grad-soft: linear-gradient(135deg,
					color-mix(in srgb, #4f7dff 16%, transparent),
					color-mix(in srgb, #8b5cf6 12%, transparent));
				--ikev2-border: rgba(128, 128, 128, .22);
				--ikev2-border-strong: rgba(128, 128, 128, .34);
				--ikev2-surface: rgba(128, 128, 128, .06);
				--ikev2-surface-2: rgba(128, 128, 128, .11);
				--ikev2-muted: rgba(128, 128, 128, .85);
				--ikev2-good: #16a34a;
				--ikev2-warn: #d97706;
				--ikev2-bad: #e11d48;
				--ikev2-info: #2f6fbe;
				/* Controls are painted in flat accent. The gradient stays as a
				   decorative wash on the hero and the card rules, where it is
				   scenery rather than a surface a label has to sit on: colour
				   that shifts under text is what makes a control read as a
				   sticker instead of a button. */
				--ikev2-fill: #4f7dff;
				--ikev2-fill-hover: #3f6bef;
				--ikev2-on-fill: #fff;

				/* One 4px step. Every gap, pad and margin below is drawn from
				   this, so the page has a rhythm instead of thirty hand-picked
				   values between .35rem and 1.5rem. */
				--ikev2-s1: .25rem;
				--ikev2-s2: .5rem;
				--ikev2-s3: .75rem;
				--ikev2-s4: 1rem;
				--ikev2-s5: 1.25rem;
				--ikev2-s6: 1.5rem;

				/* Bigger surfaces read as thicker: chips and rows sit flat on
				   the page, cards and sections lift a little, the hero sits one
				   step above them. Two steps are all the page uses - a third
				   was declared here and never applied to anything. */
				--ikev2-e1: 0 1px 2px rgba(0, 0, 0, .04);
				--ikev2-e2: 0 1px 2px rgba(0, 0, 0, .05), 0 8px 20px -14px rgba(0, 0, 0, .4);

				--ikev2-radius: 16px;
				--ikev2-radius-sm: 11px;
				/* Marks and inline controls sit a tier below the panels they
				   are drawn inside. Three hand-written values between .7rem
				   and .75rem all rounded to the same pixel as radius-sm;
				   they were the same corner spelled three ways. */
				--ikev2-radius-xs: 7px;
				/* Critically damped: reaches the target and stops, no
				   overshoot. Used for every state change a pointer causes. */
				--ikev2-ease: cubic-bezier(.32, .72, 0, 1);
				/* A press must read before the finger lifts, so it is the one
				   transition short enough to land inside the touch. */
				--ikev2-press: 90ms;
				--ikev2-shadow: var(--ikev2-e1);
				--ikev2-shadow-lg: var(--ikev2-e2);
				max-width: 1220px;
				font-feature-settings: "tnum" 0;
			}
			.ikev2-page * { box-sizing: border-box; }

			/* ── Header ─────────────────────────────────────────────── */
			.ikev2-header {
				display: flex;
				align-items: flex-start;
				justify-content: space-between;
				gap: var(--ikev2-s5);
				margin: 0 0 var(--ikev2-s6);
			}
			/* Tracking tightens as the face grows; leading tightens with it.
			   Size, weight and leading are set together rather than size alone. */
			.ikev2-header h2 {
				margin: 0 0 var(--ikev2-s1);
				font-size: clamp(1.5rem, 2.6vw, 1.95rem);
				font-weight: 700;
				line-height: 1.12;
				letter-spacing: -.022em;
			}
			.ikev2-subtitle {
				margin: 0;
				max-width: 780px;
				color: var(--ikev2-muted);
				line-height: 1.55;
			}
			.ikev2-header-actions {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .55rem;
			}
			/* ── Grid + cards ───────────────────────────────────────── */
			.ikev2-grid {
				display: grid;
				grid-template-columns: repeat(12, minmax(0, 1fr));
				gap: var(--ikev2-s3);
				margin: var(--ikev2-s4) 0;
			}
			.ikev2-card {
				grid-column: span 3;
				min-width: 0;
				position: relative;
				overflow: hidden;
				padding: var(--ikev2-s4);
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
				transition: transform .16s var(--ikev2-ease), box-shadow .16s var(--ikev2-ease),
					border-color .16s var(--ikev2-ease);
			}
			.ikev2-card::before {
				content: "";
				position: absolute;
				inset: 0 0 auto 0;
				height: 3px;
				background: var(--ikev2-grad);
				opacity: .25;
				transition: opacity .16s var(--ikev2-ease);
			}
			.ikev2-card:hover {
				box-shadow: var(--ikev2-shadow-lg);
				border-color: var(--ikev2-border-strong);
			}
			.ikev2-card:hover::before { opacity: 1; }
			.ikev2-card.wide { grid-column: span 6; }
			.ikev2-card.full { grid-column: 1 / -1; }
			.ikev2-card-label {
				margin-bottom: .5rem;
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-card-value {
				display: flex;
				align-items: center;
				gap: .5rem;
				min-height: 1.8rem;
				font-size: clamp(1.4rem, 2.4vw, 1.7rem);
				font-weight: 700;
				line-height: 1.15;
				letter-spacing: -.02em;
				font-variant-numeric: tabular-nums;
				overflow-wrap: anywhere;
			}
			.ikev2-card-detail {
				margin-top: .5rem;
				font-size: .84rem;
				line-height: 1.5;
				color: var(--ikev2-muted);
				overflow-wrap: anywhere;
			}

			/* ── Hero ───────────────────────────────────────────────── */
			.ikev2-hero {
				display: grid;
				grid-template-columns: minmax(0, 1.6fr) minmax(17rem, .85fr);
				gap: 1.25rem;
				margin: 0 0 var(--ikev2-s4);
				padding: var(--ikev2-s6);
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background:
					radial-gradient(120% 140% at 0% 0%, color-mix(in srgb, var(--ikev2-accent) 18%, transparent), transparent 55%),
					radial-gradient(120% 160% at 100% 0%, color-mix(in srgb, var(--ikev2-accent-2) 16%, transparent), transparent 55%),
					var(--ikev2-surface);
				box-shadow: var(--ikev2-e2);
			}
			.ikev2-hero h3 {
				margin: 0 0 .4rem;
				font-size: 1.3rem;
				font-weight: 700;
				letter-spacing: -.01em;
			}
			.ikev2-hero p { margin: 0; color: var(--ikev2-muted); line-height: 1.55; }
			.ikev2-hero-side {
				display: flex;
				flex-direction: column;
				gap: 1rem;
				align-items: center;
				justify-content: center;
			}

			/* ── Gauge (donut) ──────────────────────────────────────── */
			.ikev2-gauge {
				position: relative;
				width: 132px;
				height: 132px;
				flex: none;
			}
			.ikev2-gauge__ring {
				position: absolute;
				inset: 0;
				border-radius: 50%;
				background: conic-gradient(var(--rc, var(--ikev2-good)) calc(var(--val, 0) * 1%),
					var(--ikev2-surface-2) 0);
				-webkit-mask: radial-gradient(farthest-side, transparent 63%, #000 65%);
				mask: radial-gradient(farthest-side, transparent 63%, #000 65%);
				transition: --val .5s var(--ikev2-ease);
			}
			.ikev2-gauge__center {
				position: absolute;
				inset: 0;
				display: grid;
				place-content: center;
				text-align: center;
			}
			.ikev2-gauge__center b {
				font-size: 1.55rem;
				font-weight: 700;
				line-height: 1;
				letter-spacing: -.02em;
				font-variant-numeric: tabular-nums;
			}
			.ikev2-gauge__center span {
				display: block;
				margin-top: .2rem;
				font-size: .68rem;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}

			/* ── Health list ────────────────────────────────────────── */
			.ikev2-health-list {
				display: grid;
				gap: .15rem;
				width: 100%;
				align-content: center;
			}
			.ikev2-health-row {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				padding: .5rem .15rem;
				border-bottom: 1px solid var(--ikev2-border);
			}
			.ikev2-health-row:last-child { border-bottom: 0; }
			/* A row with an action reports on the button itself (flashButton),
			   so progress and success take no space next to it. Only a failure
			   adds its reason under the button, where it stays until retried. */
			.ikev2-health-row.ikev2-action-row { padding: .7rem .15rem; }
			.ikev2-action-row > .ikev2-actions {
				flex: none;
				flex-direction: column;
				flex-wrap: nowrap;
				align-items: flex-end;
				gap: .35rem;
				max-width: 24rem;
			}
			.ikev2-action-row > .ikev2-actions > .cbi-button {
				min-width: 12.5rem;
				white-space: nowrap;
				overflow: hidden;
				text-overflow: ellipsis;
			}
			.ikev2-health-copy {
				display: flex;
				flex-direction: column;
				min-width: 0;
			}
			.ikev2-health-copy .ikev2-toggle-sub {
				display: block;
				margin-top: .15rem;
				font-size: .86rem;
				font-weight: 400;
				line-height: 1.45;
				color: var(--ikev2-muted);
			}

			/* ── Issues ─────────────────────────────────────────────── */
			.ikev2-issue-list { display: grid; gap: .6rem; margin: 1.1rem 0; }
			.ikev2-issue {
				padding: .8rem .95rem .8rem 1rem;
				border: 1px solid color-mix(in srgb, var(--ikev2-warn) 32%, var(--ikev2-border));
				border-left: .26rem solid var(--ikev2-warn);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-warn) 8%, transparent);
				line-height: 1.5;
			}

			/* ── Quick links ────────────────────────────────────────── */
			.ikev2-quick-link {
				display: inline-flex;
				align-items: center;
				min-height: 2.3rem;
				padding: .45rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, currentColor 5%, transparent);
				text-decoration: none;
				font-weight: 600;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					background .14s var(--ikev2-ease), border-color .14s var(--ikev2-ease);
			}
			.ikev2-quick-link:hover {
				background: var(--ikev2-surface-2);
				border-color: var(--ikev2-border-strong);
			}

			/* ── Pills ──────────────────────────────────────────────── */
			.ikev2-pill {
				display: inline-flex;
				align-items: center;
				gap: .4rem;
				padding: .26rem .65rem;
				border: 1px solid color-mix(in srgb, currentColor 30%, transparent);
				border-radius: 999px;
				background: color-mix(in srgb, currentColor 12%, transparent);
				font-size: .78rem;
				font-weight: 600;
				line-height: 1.2;
				white-space: nowrap;
			}
			.ikev2-pill::before {
				content: "";
				width: .48rem;
				height: .48rem;
				border-radius: 50%;
				background: currentColor;
				box-shadow: 0 0 0 .18rem color-mix(in srgb, currentColor 22%, transparent);
			}
			.ikev2-pill.good { color: var(--ikev2-good); }
			.ikev2-pill.warn { color: var(--ikev2-warn); }
			.ikev2-pill.bad { color: var(--ikev2-bad); }
			.ikev2-pill.info { color: var(--ikev2-info); }
			.ikev2-pill.neutral {
				color: var(--ikev2-muted);
				background: var(--ikev2-surface-2);
				border-color: var(--ikev2-border);
			}

			/* ── Sections ───────────────────────────────────────────── */
			.ikev2-section {
				margin: var(--ikev2-s4) 0;
				padding: var(--ikev2-s5);
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
			}
			.ikev2-section-head {
				display: flex;
				align-items: flex-start;
				justify-content: space-between;
				gap: 1rem;
				margin-bottom: 1rem;
			}
			.ikev2-section-head > .ikev2-actions {
				flex: none;
				align-self: flex-start;
			}
			.ikev2-section-head > .ikev2-advanced-toggle {
				flex: none;
				align-self: flex-start;
				margin-left: auto;
			}
			/* LuCI's own h3/h4 sizes differ per theme, so the section title is
			   pinned here; otherwise the same heading changed size between
			   pages depending on which tag the caller reached for. */
			.ikev2-section-head h3,
			.ikev2-section-head h4 {
				margin: 0 0 var(--ikev2-s1);
				font-size: 1.05rem;
				font-weight: 700;
				line-height: 1.3;
				letter-spacing: -.012em;
			}
			.ikev2-section-head p { margin: 0; color: var(--ikev2-muted); line-height: 1.5; }
			.ikev2-engine {
				display: block;
			}
			.ikev2-engine-head {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1.25rem;
			}
			.ikev2-engine-state {
				display: grid;
				justify-items: start;
				gap: .55rem;
				min-width: 0;
			}
			.ikev2-engine-summary {
				margin: 0;
				max-width: 52rem;
				color: var(--ikev2-muted);
				line-height: 1.5;
			}
			.ikev2-engine-action {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .65rem;
				flex: none;
			}
			.ikev2-engine-action .cbi-button {
				min-width: 11.5rem;
			}
			.ikev2-actions {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .6rem;
			}
			.ikev2-icon-button {
				display: inline-flex !important;
				align-items: center;
				justify-content: center;
				gap: .42rem;
				min-height: 2.25rem;
				padding: .42rem .72rem !important;
				border-radius: var(--ikev2-radius-sm) !important;
				font-weight: 600;
				white-space: nowrap;
			}
			.ikev2-icon {
				width: 1rem;
				height: 1rem;
				flex: none;
				fill: none;
				stroke: currentColor;
				stroke-width: 1.9;
				stroke-linecap: round;
				stroke-linejoin: round;
			}

			/* ── Key/value table ────────────────────────────────────── */
			/* Fixed layout keeps the label column at its width; a long value
			   wraps inside its own column instead of widening the table past
			   its card and squeezing the labels. */
			.ikev2-kv { width: 100%; border-collapse: collapse; table-layout: fixed; }
			.ikev2-kv td:last-child { overflow-wrap: anywhere; }
			.ikev2-kv .ikev2-pill { white-space: normal; max-width: 100%; }
			.ikev2-kv td {
				padding: .58rem .25rem;
				border-top: 1px solid var(--ikev2-border);
				vertical-align: top;
				line-height: 1.45;
			}
			.ikev2-kv tr:first-child td { border-top: 0; }
			.ikev2-kv td:first-child {
				width: 34%;
				padding-right: 1rem;
				color: var(--ikev2-muted);
			}
			.ikev2-deps-summary {
				padding: .8rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-deps-summary h4 {
				margin: 0 0 .55rem;
				font-size: .82rem;
				color: var(--ikev2-muted);
			}
			.ikev2-diagnostics {
				margin-top: .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-surface) 80%, transparent);
			}
			.ikev2-diagnostics > summary {
				display: flex;
				align-items: center;
				gap: .5rem;
				padding: .75rem .9rem;
				cursor: pointer;
				font-weight: 600;
				list-style: none;
			}
			.ikev2-diagnostics > summary::-webkit-details-marker { display: none; }
			.ikev2-diagnostics > summary::before {
				content: "\\203A";
				font-size: 1.2rem;
				line-height: 1;
				transition: transform .15s var(--ikev2-ease);
			}
			.ikev2-diagnostics[open] > summary::before { transform: rotate(90deg); }
			.ikev2-diagnostics-body {
				padding: 0 .9rem .8rem;
				border-top: 1px solid var(--ikev2-border);
			}

			/* ── VPN user cards ─────────────────────────────────────── */
			.ikev2-windows-app {
				display: grid;
				grid-template-columns: auto minmax(12rem, 1fr) auto auto;
				align-items: center;
				gap: .85rem;
				width: 100%;
				margin: 0 0 1rem;
				padding: .7rem .8rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-windows-app-mark {
				display: grid;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-grad-soft);
				color: var(--ikev2-accent);
			}
			.ikev2-windows-app-mark .ikev2-icon { width: 1.15rem; height: 1.15rem; }
			.ikev2-windows-app-copy { display: grid; gap: .14rem; min-width: 0; }
			.ikev2-windows-app-copy span { color: var(--ikev2-muted); font-size: .84rem; }
			.ikev2-user-list { display: grid; gap: .75rem; }
			.ikev2-user-card {
				display: grid;
				grid-template-columns: minmax(10rem, .8fr) minmax(18rem, 1.6fr) auto;
				align-items: center;
				gap: 1rem;
				padding: .9rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-user-identity {
				display: flex;
				align-items: center;
				gap: .65rem;
				min-width: 0;
			}
			.ikev2-user-avatar {
				display: grid;
				place-content: center;
				width: 2.25rem;
				height: 2.25rem;
				flex: none;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-grad-soft);
				color: var(--ikev2-accent);
				font-weight: 700;
				text-transform: uppercase;
			}
			.ikev2-user-name {
				display: block;
				margin-bottom: .28rem;
				overflow: hidden;
				text-overflow: ellipsis;
			}
			.ikev2-session-list { display: grid; gap: .5rem; min-width: 0; }
			.ikev2-session {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .8rem;
				min-width: 0;
			}
			.ikev2-session-main { min-width: 0; }
			.ikev2-session-address {
				display: block;
				margin-bottom: .2rem;
				font-weight: 600;
				overflow-wrap: anywhere;
			}
			.ikev2-session-meta {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .3rem .75rem;
				color: var(--ikev2-muted);
				font-size: .82rem;
			}
			.ikev2-traffic {
				display: inline-flex;
				align-items: center;
				gap: .22rem;
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-traffic .ikev2-icon {
				width: .78rem;
				height: .78rem;
				stroke-width: 2.25;
			}
			.ikev2-traffic.received { color: color-mix(in srgb, var(--ikev2-good) 78%, var(--ikev2-muted)); }
			.ikev2-traffic.sent { color: color-mix(in srgb, var(--ikev2-info) 82%, var(--ikev2-muted)); }
			.ikev2-user-actions {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .45rem;
			}
			.ikev2-profile-actions {
				display: inline-flex;
				align-items: center;
				gap: .35rem;
				padding-right: .55rem;
				margin-right: .1rem;
				border-right: 1px solid var(--ikev2-border);
			}
			.ikev2-platform-action {
				display: inline-grid !important;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				min-width: 2.35rem !important;
				padding: 0 !important;
			}
			.ikev2-device-policy-scroll { overflow-x: auto; }
			.ikev2-device-policy-table {
				display: grid;
				gap: .45rem;
				min-width: 48rem;
			}
			.ikev2-device-policy-row {
				display: grid;
				grid-template-columns: minmax(12rem, 1.5fr) minmax(7rem, .65fr)
					repeat(3, 4rem) minmax(9rem, .8fr) 2.6rem;
				align-items: center;
				gap: .65rem;
				padding: .68rem .75rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-device-policy-row.head {
				padding-block: .3rem;
				border: 0;
				background: transparent;
				color: var(--ikev2-muted);
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
			}
			/* With more than one tunnel a full-route device names its own. */
			.ikev2-device-policy-table.ikev2-with-tunnel { min-width: 60rem; }
			.ikev2-with-tunnel .ikev2-device-policy-row {
				grid-template-columns: minmax(12rem, 1.5fr) minmax(7rem, .65fr)
					repeat(3, 4rem) minmax(12rem, 1fr) minmax(9rem, .8fr) 2.6rem;
			}
			.ikev2-page .ikev2-with-tunnel select { width: 100%; min-width: 0; }
			.ikev2-device-policy-name { display: grid; gap: .18rem; min-width: 0; }
			/* The address is a caption under the name, not a field: the theme's
			   grey code box made it read as an input. */
			.ikev2-page .ikev2-device-policy-name code {
				overflow-wrap: anywhere;
				padding: 0;
				background: none;
				border: 0;
				color: var(--ikev2-muted);
				font-size: .82rem;
			}
			.ikev2-device-policy-traffic {
				color: var(--ikev2-muted);
				font-size: .82rem;
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-policy-check {
				display: inline-grid;
				place-content: center;
				justify-self: start;
				width: 2rem;
				height: 2rem;
				cursor: pointer;
			}
			.ikev2-policy-check input {
				position: absolute;
				opacity: 0;
				pointer-events: none;
			}
			.ikev2-policy-check span {
				display: grid;
				place-content: center;
				width: 1.2rem;
				height: 1.2rem;
				border: 1px solid var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius-xs);
				background: var(--ikev2-surface);
			}
			.ikev2-policy-check input:checked + span {
				border-color: transparent;
				background: var(--ikev2-fill);
			}
			.ikev2-policy-check input:checked + span::after {
				content: "\\2713";
				color: #fff;
				font-size: .78rem;
				font-weight: 700;
			}
			.ikev2-policy-check input:focus-visible + span {
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-policy-check input:disabled + span { opacity: .5; cursor: wait; }
			.ikev2-policy-na { color: var(--ikev2-muted); }
			.ikev2-square-action {
				display: inline-grid !important;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				min-width: 2.35rem !important;
				padding: 0 !important;
			}
			.ikev2-status-widget { display: grid; gap: .75rem; }
			.ikev2-widget-summary {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .75rem;
			}
			.ikev2-widget-summary-label {
				color: var(--ikev2-muted);
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
			}
			.ikev2-widget-overview {
				display: grid;
				grid-template-columns: repeat(3, minmax(0, 1fr));
				gap: .65rem;
			}
			.ikev2-widget-component {
				display: flex;
				flex-direction: column;
				min-width: 0;
				padding: .82rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-widget-component-label {
				margin-bottom: .5rem;
				color: var(--ikev2-muted);
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
			}
			.ikev2-widget-component-head {
				display: flex;
				align-items: center;
				min-height: 1.65rem;
			}
			.ikev2-widget-component-detail {
				margin-top: .48rem;
				color: var(--ikev2-muted);
				font-size: .82rem;
				line-height: 1.4;
			}
			.ikev2-widget-component-meta {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .35rem .7rem;
				margin-top: auto;
				padding-top: .52rem;
				color: var(--ikev2-muted);
				font-size: .78rem;
			}
			.ikev2-widget-component-meta .ikev2-traffic {
				color: var(--ikev2-muted);
			}
			.ikev2-widget-clients {
				display: grid;
				gap: .55rem;
				padding-top: .15rem;
			}
			.ikev2-widget-clients-head {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .75rem;
			}
			.ikev2-widget-client-list { display: grid; gap: .55rem; }
			.ikev2-widget-client {
				display: grid;
				grid-template-columns: minmax(10rem, 1fr) auto auto;
				align-items: center;
				gap: .75rem 1rem;
				padding: .72rem .8rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-widget-client-name { min-width: 0; }
			.ikev2-widget-address,
			.ikev2-widget-duration {
				color: var(--ikev2-muted);
				font-size: .82rem;
			}
			.ikev2-widget-address {
				display: block;
				overflow-wrap: anywhere;
			}
			.ikev2-widget-duration { white-space: nowrap; }
			.ikev2-widget-traffic {
				display: inline-flex;
				align-items: center;
				justify-content: flex-end;
				gap: .65rem;
			}
			.ikev2-widget-footer {
				display: flex;
				justify-content: flex-end;
			}

			/* ── Notes ──────────────────────────────────────────────── */
			.ikev2-note {
				padding: .9rem 1rem;
				border: 1px solid color-mix(in srgb, var(--ikev2-info) 30%, var(--ikev2-border));
				border-left: .26rem solid var(--ikev2-info);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-info) 7%, transparent);
				line-height: 1.5;
			}
			.ikev2-note.warn {
				border-color: color-mix(in srgb, var(--ikev2-warn) 32%, var(--ikev2-border));
				border-left-color: var(--ikev2-warn);
				background: color-mix(in srgb, var(--ikev2-warn) 8%, transparent);
			}
			.ikev2-note.bad {
				border-color: color-mix(in srgb, var(--ikev2-bad) 32%, var(--ikev2-border));
				border-left-color: var(--ikev2-bad);
				background: color-mix(in srgb, var(--ikev2-bad) 8%, transparent);
			}

			/* ── Forms ──────────────────────────────────────────────── */
			.ikev2-form-grid {
				display: grid;
				grid-template-columns: minmax(9rem, 15rem) minmax(20rem, 1fr);
				gap: .9rem 1.4rem;
				align-items: center;
			}
			.ikev2-field-label { font-weight: 600; }
			.ikev2-field-help {
				display: block;
				margin-top: .22rem;
				font-size: .8rem;
				font-weight: 400;
				color: var(--ikev2-muted);
			}
			.ikev2-page input[type="text"],
			.ikev2-page input[type="password"],
			.ikev2-page input[type="number"],
			.ikev2-page select,
			.ikev2-page textarea {
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				/* The field ground is a tint of the page's own text colour, so
				   the field follows the theme. Its foreground has to follow the
				   same way - left to the user agent it stayed the light-theme
				   field colour and the value went unreadable on a dark ground,
				   the same failure the disabled button had. */
				background: color-mix(in srgb, currentColor 3%, transparent);
				color: inherit;
				padding: var(--ikev2-s2) .65rem;
				transition: border-color .14s var(--ikev2-ease), box-shadow .14s var(--ikev2-ease);
			}
			/* The bootstrap theme pins input and select to a fixed height: 30px
			   with box-sizing: border-box. Together with the padding above that
			   leaves roughly 12px for a line box that needs about 18px. Blink on
			   macOS lets the glyphs overflow, but Edge on Windows clips the
			   descenders of the selected option. Size these controls by their
			   content and keep a floor that matches the buttons next to them. */
			.ikev2-page input[type="text"],
			.ikev2-page input[type="password"],
			.ikev2-page input[type="number"],
			.ikev2-page select,
			.ikev2-page textarea {
				height: auto;
				min-height: 2.25rem;
				line-height: 1.35;
			}
			.ikev2-page textarea,
			.ikev2-page select[multiple] { min-height: 6rem; }
			/* A native select is drawn by the platform, which honours our radius
			   only loosely - next to a text field of the same radius its corners
			   read as sharper. Take the control over and draw the chevron here.
			   Its grey matches --ikev2-muted, which is theme-independent, so one
			   colour is correct on both grounds. */
			.ikev2-page select:not([multiple]) {
				appearance: none;
				-webkit-appearance: none;
				padding-right: 2rem;
				background-color: color-mix(in srgb, currentColor 3%, transparent);
				background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12' fill='none' stroke='%23808080' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2.5 4.5 6 8l3.5-3.5'/%3E%3C/svg%3E");
				background-repeat: no-repeat;
				background-position: right .62rem center;
				background-size: .72rem;
			}
			.ikev2-form-grid input[type="text"],
			.ikev2-form-grid input[type="password"],
			.ikev2-form-grid input[type="number"] { width: 100%; max-width: 34rem; }
			.ikev2-form-grid textarea,
			.ikev2-form-grid select { width: 100%; max-width: 34rem; }
			.ikev2-form-grid-compact {
				grid-template-columns: minmax(13rem, 19rem) minmax(0, 1fr);
				align-items: start;
			}
			.ikev2-form-grid-compact > .ikev2-field-label { padding-top: .48rem; }
			.ikev2-form-grid-compact input[type="text"],
			.ikev2-form-grid-compact input[type="password"],
			.ikev2-form-grid-compact input[type="number"],
			.ikev2-form-grid-compact select,
			.ikev2-form-grid-compact textarea { max-width: none; }
			.ikev2-choice-custom {
				display: grid;
				gap: .55rem;
				width: 100%;
			}
			.ikev2-choice-custom > select,
			.ikev2-choice-custom > input { max-width: none; }
			.ikev2-choice-list {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
				gap: .45rem;
			}
			.ikev2-choice-list label {
				display: flex;
				align-items: center;
				gap: .5rem;
				min-height: 2.4rem;
				padding: .45rem .65rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface);
				cursor: pointer;
			}
			.ikev2-choice-list input { margin: 0; }
			.ikev2-dns-managed { margin-top: 1rem; }
			.ikev2-dns-preset-picker {
				display: grid;
				grid-template-columns: minmax(0, 1fr) auto;
				gap: .55rem;
				max-width: 34rem;
			}
			.ikev2-dns-preset-picker select { max-width: none; }
			.ikev2-dns-editor {
				display: grid;
				gap: .55rem;
				width: 100%;
				max-width: none;
			}
			.ikev2-dns-endpoints { display: grid; gap: .45rem; }
			/* One line per endpoint: where it came from, then the endpoint
			   itself. A stacked row reads as several settings rather than one,
			   and a list of them is hard to scan. The row wraps rather than
			   squeezing the endpoint when the column is too narrow for both. */
			/* One grid per row with fixed picker tracks, so every row in a list
			   lines up whatever its longest option label happens to be, and the
			   spacing between the controls is the same everywhere. Concentric
			   corners: the row's radius is the controls' radius plus the padding
			   between them - equal radii are what made the nesting look wrong. */
			.ikev2-dns-endpoint {
				display: grid;
				grid-template-columns: 13rem minmax(0, 1fr) 2.4rem;
				align-items: center;
				gap: .5rem;
				padding: .5rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
			}
			.ikev2-dns-editor-choosable .ikev2-dns-endpoint {
				grid-template-columns: 13rem 13rem minmax(0, 1fr) 2.4rem;
			}
			.ikev2-page .ikev2-dns-endpoint select,
			.ikev2-page .ikev2-dns-endpoint input[type="text"],
			.ikev2-page .ikev2-dns-endpoint .cbi-button {
				box-sizing: border-box;
				width: 100%;
				min-width: 0;
				max-width: none;
				height: 2.4rem;
				min-height: 2.4rem;
				padding-block: 0;
				border-radius: .5rem;
				font-size: .85rem;
				line-height: 1.2;
			}
			.ikev2-page .ikev2-dns-endpoint input[type="text"] {
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
			}
			.ikev2-page .ikev2-dns-endpoint .cbi-button {
				padding-inline: 0;
			}
			.ikev2-dns-empty {
				padding: .58rem .7rem;
				border: 1px dashed var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				color: var(--ikev2-muted);
				font-size: .84rem;
			}
			.ikev2-segment-list {
				display: flex;
				flex-direction: column;
				gap: .9rem;
			}
			.ikev2-segment-block {
				display: flex;
				flex-direction: column;
				gap: .85rem;
				padding: .95rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface);
			}
			.ikev2-segment-title {
				display: flex;
				align-items: center;
				gap: .5rem;
			}
			.ikev2-wide-button {
				display: block;
				width: 100%;
				margin-top: .9rem;
				text-align: center;
			}
			.ikev2-dns-editor-actions {
				display: flex;
				justify-content: flex-start;
			}
			.ikev2-page input:focus,
			.ikev2-page select:focus,
			.ikev2-page textarea:focus {
				outline: none;
				border-color: var(--ikev2-accent);
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-readonly {
				display: inline-block;
				padding: .4rem .6rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				overflow-wrap: anywhere;
			}

			/* ── Buttons (scoped) ───────────────────────────────────── */
			.ikev2-page .cbi-button {
				display: inline-flex;
				align-items: center;
				justify-content: center;
				box-sizing: border-box;
				min-height: 2.35rem;
				border-radius: var(--ikev2-radius-sm);
				padding: .5rem 1rem;
				border: 1px solid var(--ikev2-border);
				background: var(--ikev2-surface-2);
				font-weight: 600;
				line-height: 1.2;
				white-space: nowrap;
				cursor: pointer;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					box-shadow .14s var(--ikev2-ease),
					background .14s var(--ikev2-ease),
					border-color .14s var(--ikev2-ease),
					filter .14s var(--ikev2-ease);
			}
			.ikev2-page .cbi-button:hover {
				background: color-mix(in srgb, currentColor 12%, transparent);
				border-color: var(--ikev2-border-strong);
			}
			/* A press has to answer the pointer going down, not the click going
			   up. The old rule only cancelled the hover lift, so a touch device
			   - which never hovers - got no feedback at all until the action
			   itself finished, and a slow action read as a dead button. */
			.ikev2-page .cbi-button:active:not([disabled]) { transform: scale(.97); }
			.ikev2-page .cbi-button-apply,
			.ikev2-page .cbi-button-positive,
			.ikev2-page .cbi-button-add,
			.ikev2-page .cbi-button-save {
				background: var(--ikev2-fill);
				background-image: none;
				border-color: transparent;
				color: var(--ikev2-on-fill);
				box-shadow: 0 6px 16px -10px var(--ikev2-fill);
			}
			.ikev2-page .cbi-button-apply:hover,
			.ikev2-page .cbi-button-positive:hover,
			.ikev2-page .cbi-button-add:hover,
			.ikev2-page .cbi-button-save:hover {
				background: var(--ikev2-fill-hover);
				background-image: none;
			}
			.ikev2-page .cbi-button-action,
			.ikev2-page .cbi-button-edit {
				border-color: color-mix(in srgb, var(--ikev2-accent) 45%, var(--ikev2-border));
				color: var(--ikev2-accent);
			}
			.ikev2-page .cbi-button-remove,
			.ikev2-page .cbi-button-negative {
				color: var(--ikev2-bad);
				border-color: color-mix(in srgb, var(--ikev2-bad) 40%, var(--ikev2-border));
			}
			.ikev2-page .cbi-button-remove:hover,
			.ikev2-page .cbi-button-negative:hover {
				background: color-mix(in srgb, var(--ikev2-bad) 12%, transparent);
			}
			/* A result on the button: tinted, with a mark, so colour is not the
			   only signal. */
			/* overflow:hidden lets a flex item shrink below its content, and a
			   crowded row squeezed the button; it keeps the width it had. */
			.ikev2-page .cbi-button.ikev2-flash {
				flex-shrink: 0;
				white-space: nowrap;
				overflow: hidden;
				text-overflow: ellipsis;
				background-image: none;
				box-shadow: none;
				transition: background-color .2s ease, color .2s ease, border-color .2s ease;
			}
			.ikev2-page .cbi-button.ikev2-flash-ok {
				color: var(--ikev2-good);
				background: color-mix(in srgb, var(--ikev2-good) 14%, transparent);
				border-color: color-mix(in srgb, var(--ikev2-good) 55%, var(--ikev2-border));
			}
			.ikev2-page .cbi-button.ikev2-flash-err {
				color: var(--ikev2-bad);
				background: color-mix(in srgb, var(--ikev2-bad) 12%, transparent);
				border-color: color-mix(in srgb, var(--ikev2-bad) 55%, var(--ikev2-border));
			}
			.ikev2-page .cbi-button.ikev2-flash-warn {
				color: var(--ikev2-warn, #d97706);
				background: color-mix(in srgb, var(--ikev2-warn, #d97706) 12%, transparent);
				border-color: color-mix(in srgb, var(--ikev2-warn, #d97706) 55%, var(--ikev2-border));
			}
			/* A Save button greys out once the form is saved; its "Saved" must
			   still read at full strength for the moment it is shown. */
			.ikev2-page .cbi-button.ikev2-flash[disabled] { opacity: 1; }
			@media (prefers-reduced-motion: reduce) {
				.ikev2-page .cbi-button.ikev2-flash { transition: none; }
			}
			/* Only opacity was set here, so a disabled button kept the UA's own
			   disabled colour - near-black at 30% - and vanished on a dark
			   theme. The busy-state pattern disables the primary button while
			   an action runs, so the label disappeared exactly while the
			   operator was waiting on it. Opacity alone carries "disabled". */
			.ikev2-page button[disabled] {
				opacity: .55;
				color: inherit;
				cursor: wait;
				transform: none;
			}

			/* ── Pointer and keyboard states ────────────────────────── */
			/* :hover latches on a touch screen: the last thing tapped keeps the
			   hover state until something else is. A lift that stays up reads
			   as a stuck card, so the movement is scoped to pointers that can
			   actually hover and leave. The colour and shadow hovers above are
			   harmless when they latch and stay unscoped. */
			@media (hover: hover) and (pointer: fine) {
				.ikev2-card:hover { transform: translateY(-3px); }
				.ikev2-quick-link:hover { transform: translateY(-1px); }
				.ikev2-page .cbi-button:hover:not([disabled]) { transform: translateY(-1px); }
			}
			/* After the hover block on purpose. A press is also a hover on a
			   mouse, both selectors weigh the same, so the later rule is the
			   one that decides - and a press must beat a lift. */
			.ikev2-page .cbi-button:active:not([disabled]),
			.ikev2-quick-link:active,
			.ikev2-chip:active,
			.ikev2-netpick:active,
			.ikev2-service-option:active,
			.ikev2-advanced-toggle:active { transform: scale(.97); }
			.ikev2-page .cbi-button:focus-visible,
			.ikev2-quick-link:focus-visible,
			.ikev2-advanced-toggle:focus-visible,
			.ikev2-page .cbi-tabmenu li a:focus-visible,
			.ikev2-diagnostics > summary:focus-visible,
			.ikev2-advanced summary:focus-visible,
			.ikev2-netpick:focus-within,
			.ikev2-service-option:focus-within {
				outline: none;
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			/* The gradient buttons already carry a shadow; adding the ring to it
			   keeps both rather than replacing the lift shadow with the ring. */
			.ikev2-page .cbi-button-apply:focus-visible,
			.ikev2-page .cbi-button-positive:focus-visible,
			.ikev2-page .cbi-button-add:focus-visible,
			.ikev2-page .cbi-button-save:focus-visible {
				box-shadow: 0 8px 20px -10px var(--ikev2-accent),
					0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 32%, transparent);
			}
			/* ── Toggle switch ──────────────────────────────────────── */
			.ikev2-switch {
				display: inline-flex;
				align-items: center;
				gap: .6rem;
				cursor: pointer;
				user-select: none;
			}
			.ikev2-switch input {
				position: absolute;
				opacity: 0;
				width: 0;
				height: 0;
			}
			.ikev2-switch-track {
				position: relative;
				flex: none;
				width: 3.05rem;
				height: 1.7rem;
				/* Track padding box (3.05rem less the 1px borders) minus the
				   knob and its inset at each end. Kept as a token so the two
				   knob rules below cannot drift apart. */
				--ikev2-switch-travel: 1.275rem;
				border-radius: 999px;
				border: 1px solid var(--ikev2-border);
				background: var(--ikev2-surface-2);
				transition: background .16s var(--ikev2-ease), border-color .16s var(--ikev2-ease);
			}
			.ikev2-switch-track::after {
				content: "";
				position: absolute;
				top: 50%;
				left: .2rem;
				transform: translate(0, -50%);
				width: 1.25rem;
				height: 1.25rem;
				border-radius: 50%;
				background: #fff;
				box-shadow: 0 1px 3px rgba(0, 0, 0, .35);
				transition: transform .16s var(--ikev2-ease);
			}
			.ikev2-switch input:checked + .ikev2-switch-track {
				background: var(--ikev2-fill);
				border-color: transparent;
			}
			.ikev2-switch input:checked + .ikev2-switch-track::after {
				transform: translate(var(--ikev2-switch-travel), -50%);
			}
			.ikev2-switch input:focus-visible + .ikev2-switch-track {
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-switch input:disabled + .ikev2-switch-track { opacity: .5; cursor: not-allowed; }
			.ikev2-switch-text { font-weight: 600; }

			/* ── Toggle row (label + switch on one line) ─────────────── */
			.ikev2-toggle-row {
				margin-top: 1rem;
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				padding: .85rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			/* A switch is a row of its own wherever it sits: in a form grid it
			   spans the label and the control columns instead of being a
			   bare switch beside a label. */
			.ikev2-form-grid > .ikev2-toggle-row { grid-column: 1 / -1; margin-top: 0; }
			.ikev2-toggle-row > :first-child { min-width: 0; }
			.ikev2-toggle-row .ikev2-toggle-text { font-weight: 600; }
			.ikev2-toggle-row .ikev2-toggle-sub {
				display: block;
				font-weight: 400;
				font-size: .86rem;
				color: var(--ikev2-muted);
				margin-top: .15rem;
			}

			/* ── Inline action result (next to buttons) ──────────────── */
			/* A result line is where a failure explains itself, so it wraps
			   instead of being cut off. Clipping it to one line turned the
			   longer messages - the ones that say what to do about the
			   failure - into an unreadable fragment. */
			.ikev2-result {
				display: inline-flex;
				align-items: flex-start;
				gap: .35rem;
				flex: 0 1 auto;
				min-width: 0;
				max-width: 34rem;
				font-size: .88rem;
				font-weight: 500;
				line-height: 1.4;
				text-align: left;
				white-space: normal;
				overflow-wrap: anywhere;
			}
			/* One place for every result: under the buttons it reports on,
			   aligned with them. Beside a button it pushed the button away the
			   moment it appeared; above it, it moved the button down. */
			.ikev2-actions > .ikev2-result,
			.ikev2-engine-action > .ikev2-result,
			.ikev2-inline-form > .ikev2-result {
				order: 99;
				flex: 1 0 100%;
				max-width: none;
			}
			.ikev2-actions.end > .ikev2-result,
			.ikev2-actions.bar > .ikev2-result,
			.ikev2-engine-action > .ikev2-result,
			.ikev2-inline-form > .ikev2-result {
				justify-content: flex-end;
				text-align: right;
			}
			.ikev2-action-row > .ikev2-actions > .ikev2-result {
				flex: none;
				max-width: 24rem;
				justify-content: flex-end;
				text-align: right;
			}
			/* While an action runs, progress and success stay here only for
			   screen readers, which a button colour or a ticked box does not
			   reach. A line that appeared and faded moved the section below. */
			.ikev2-result.quiet:not(.err):not(.warn) {
				position: absolute;
				width: 1px;
				height: 1px;
				overflow: hidden;
				clip: rect(0 0 0 0);
			}
			.ikev2-result.idle { display: none; }
			/* A success fades once read; the state it reports stays on the page
			   in the pills and buttons. Failures stay: they say what to do. */
			.ikev2-result { transition: opacity .6s ease; }
			.ikev2-result.fading { opacity: 0; }
			@media (prefers-reduced-motion: reduce) {
				.ikev2-result { transition: none; }
			}
			.ikev2-result.busy { color: var(--ikev2-muted); }
			.ikev2-result.ok { color: var(--ikev2-good, #16a34a); }
			.ikev2-result.warn { color: var(--ikev2-warn, #d97706); }
			.ikev2-result.err { color: var(--ikev2-bad, #dc2626); }
			.ikev2-save-bar {
				margin-top: 1.4rem;
				padding-top: 1.1rem;
				border-top: 1px solid var(--ikev2-border);
			}
			/* On its own under the sections the bar is a card like them. A lone
			   rule line there matched no card edge and ran into the button. */
			/* The note reads from the left and the button stays at the right, on
			   one line while they fit. */
			.ikev2-save-bar > .ikev2-field-help {
				flex: 1 1 18rem;
				margin: 0;
				text-align: left;
			}
			.ikev2-page > .ikev2-save-bar {
				margin: var(--ikev2-s4) 0;
				padding: var(--ikev2-s4) var(--ikev2-s5);
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
			}

			/* ── Advanced disclosure ────────────────────────────────── */
			.ikev2-advanced {
				margin-top: 1.1rem;
				border-top: 1px solid var(--ikev2-border);
				padding-top: .9rem;
			}
			.ikev2-advanced summary,
			.ikev2-section > details > summary {
				cursor: pointer;
				font-weight: 600;
				margin-bottom: .9rem;
				list-style: none;
			}
			.ikev2-advanced summary::-webkit-details-marker { display: none; }
			.ikev2-advanced summary::before {
				content: "\\203A";
				display: inline-block;
				margin-right: .5rem;
				transition: transform .15s var(--ikev2-ease);
			}
			.ikev2-advanced[open] summary::before { transform: rotate(90deg); }
			.ikev2-advanced-toggle {
				display: inline-flex;
				align-items: center;
				justify-content: center;
				flex: none;
				width: 2.1rem;
				height: 2.1rem;
				padding: 0;
				border: 1px solid var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface);
				color: inherit;
				cursor: pointer;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					background .15s var(--ikev2-ease), border-color .15s var(--ikev2-ease),
					color .15s var(--ikev2-ease);
			}
			.ikev2-advanced-toggle:hover {
				background: var(--ikev2-surface-2);
				border-color: var(--ikev2-accent);
			}
			.ikev2-advanced-toggle.ikev2-advanced-open {
				border-color: var(--ikev2-accent);
				color: var(--ikev2-accent);
				background: color-mix(in srgb, var(--ikev2-accent) 12%, transparent);
			}
			.ikev2-advanced-panel {
				margin-top: 1.1rem;
				padding-top: .9rem;
				border-top: 1px solid var(--ikev2-border);
			}
			.ikev2-advanced-group + .ikev2-advanced-group { margin-top: 1.1rem; }
			.ikev2-advanced-group > h4 {
				margin: 0 0 .7rem;
				font-size: .86rem;
				font-weight: 600;
				letter-spacing: .02em;
				color: var(--ikev2-muted);
			}

			.ikev2-panel-note {
				margin: 0 0 1rem;
				color: var(--ikev2-muted);
				line-height: 1.5;
			}

			/* ── Password row ───────────────────────────────────────── */
			.ikev2-password {
				display: flex;
				align-items: center;
				gap: .45rem;
				min-width: 15rem;
			}
			.ikev2-password code {
				flex: 1;
				padding: .35rem .5rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				user-select: all;
				overflow-wrap: anywhere;
			}

			/* ── Empty state ────────────────────────────────────────── */
			.ikev2-empty {
				padding: 1.6rem;
				text-align: center;
				color: var(--ikev2-muted);
				border: 1px dashed var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
			}

			/* ── Service catalog ────────────────────────────────────── */
			.ikev2-service-grid {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(15rem, 1fr));
				gap: .9rem;
			}
			.ikev2-service-group {
				padding: .95rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				transition: border-color .14s var(--ikev2-ease), box-shadow .14s var(--ikev2-ease);
			}
			.ikev2-service-group:hover {
				border-color: var(--ikev2-border-strong);
				box-shadow: var(--ikev2-shadow);
			}
			.ikev2-service-group h4 {
				margin: 0 0 .6rem;
				padding-bottom: .45rem;
				border-bottom: 1px solid var(--ikev2-border);
				font-weight: 700;
			}
			.ikev2-service-option {
				display: flex;
				align-items: flex-start;
				gap: .55rem;
				margin: .15rem -.4rem;
				padding: .35rem .4rem;
				border-radius: var(--ikev2-radius-sm);
				cursor: pointer;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					background .12s var(--ikev2-ease);
			}
			.ikev2-service-option:hover { background: var(--ikev2-surface-2); }

			/* ── Compact selectable chips (service catalog) ──────────── */
			.ikev2-chip-group { margin-bottom: 1rem; }
			.ikev2-chip-group:last-child { margin-bottom: 0; }
			.ikev2-chip-group h4 {
				margin: 0 0 .55rem;
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-chips { display: flex; flex-wrap: wrap; gap: .45rem; }
			.ikev2-chip {
				display: inline-flex;
				align-items: center;
				gap: .35rem;
				padding: .32rem .7rem;
				border: 1px solid var(--ikev2-border);
				border-radius: 999px;
				background: var(--ikev2-surface-2);
				color: inherit;
				cursor: pointer;
				user-select: none;
				font-size: .85rem;
				font-weight: 600;
				line-height: 1.3;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					background .12s var(--ikev2-ease), border-color .12s var(--ikev2-ease),
					color .12s var(--ikev2-ease);
			}
			.ikev2-chip:hover { border-color: var(--ikev2-border-strong); }
			.ikev2-chip:focus-within {
				border-color: var(--ikev2-accent);
				box-shadow: 0 0 0 2px color-mix(in srgb, var(--ikev2-accent) 22%, transparent);
			}
			.ikev2-chip.selected {
				border-color: transparent;
				background: var(--ikev2-fill);
				color: var(--ikev2-on-fill);
			}
			.ikev2-chip.broad {
				border-color: color-mix(in srgb, var(--ikev2-warn) 45%, var(--ikev2-border));
			}
			.ikev2-chip.broad.selected { background: var(--ikev2-warn); }
			.ikev2-chip input { position: absolute; opacity: 0; width: 0; height: 0; }
			.ikev2-chip .ikev2-icon { width: .85rem; height: .85rem; }

			/* ── Routes: a field per tunnel, services as chips ───────── */
			.ikev2-routes { display: grid; gap: .75rem; }
			.ikev2-route-bar {
				display: flex;
				flex-wrap: wrap;
				align-items: center;
				gap: .5rem;
				min-height: 2.6rem;
				margin-bottom: .75rem;
				padding: .55rem .75rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-route-lane {
				padding: .75rem .9rem .6rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			/* The field a click in the catalogue adds a service to. */
			.ikev2-route-lane.active { border-color: var(--ikev2-accent); }
			.ikev2-route-lane-head {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .75rem;
				cursor: pointer;
			}
			.ikev2-route-zone-label {
				margin-top: .6rem;
				font-size: .78rem;
				color: var(--ikev2-muted);
			}
			.ikev2-route-zone {
				display: flex;
				flex-wrap: wrap;
				gap: .4rem;
				min-height: 2.5rem;
				margin-top: .3rem;
				padding: .3rem;
				border: 1px dashed transparent;
				border-radius: var(--ikev2-radius-sm);
			}
			.ikev2-route-zone.over {
				border-color: var(--ikev2-accent);
				background: color-mix(in srgb, var(--ikev2-accent) 9%, transparent);
			}
			.ikev2-route-zone-empty {
				align-self: center;
				padding: 0 .3rem;
				font-size: .82rem;
				color: var(--ikev2-muted);
			}
			.ikev2-route-catalog { display: block; margin-top: 0; }
			.ikev2-route-chip { cursor: grab; }
			.ikev2-route-chip:focus-visible {
				outline: none;
				border-color: var(--ikev2-accent);
				box-shadow: 0 0 0 2px color-mix(in srgb, var(--ikev2-accent) 22%, transparent);
			}
			/* A list that always stays out of the tunnel: shown, not moved. */
			.ikev2-route-chip.fixed {
				cursor: pointer;
				border-style: dashed;
				font-weight: 500;
				color: var(--ikev2-muted);
			}

			/* ── Dialog (a service's definition) ─────────────────────── */
			.ikev2-dialog-backdrop {
				position: fixed;
				inset: 0;
				z-index: 2000;
				display: flex;
				align-items: center;
				justify-content: center;
				padding: 1rem;
				background: rgba(0, 0, 0, .55);
			}
			.ikev2-dialog {
				width: min(64rem, 100%);
				max-height: 92vh;
				overflow: auto;
				padding: 1.1rem 1.25rem;
				border: 1px solid var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius);
				/* The page surfaces are tints over the theme's ground and would
				   show the dimmed page through; the window takes the ground
				   itself, which the page reads from the theme when it opens. */
				background: var(--ikev2-bg, Canvas);
			}
			.ikev2-dialog h3 { margin: 0 0 1rem; }
			/* Labels sit above their fields here, so a list is as wide as the
			   window allows; the two lists share a row until it gets narrow. */
			.ikev2-dialog-field { display: grid; gap: .4rem; margin-bottom: 1rem; min-width: 0; }
			.ikev2-dialog-field > input,
			.ikev2-dialog-field > select,
			.ikev2-dialog-field > textarea { width: 100%; max-width: none; }
			.ikev2-dialog-lists {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: 0 1.25rem;
				align-items: start;
			}
			@media (max-width: 720px) {
				.ikev2-dialog-lists { grid-template-columns: 1fr; }
			}
			.ikev2-chip-mark { font-size: .7rem; opacity: .65; }
			.ikev2-service-editor {
				margin-top: 1rem;
				padding: 1rem;
				border: 1px solid var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface-2);
			}
			.ikev2-service-editor h3 { margin: 0 0 1rem; }
			.ikev2-picker-row {
				display: flex;
				align-items: center;
				gap: .5rem;
			}
			.ikev2-picker-row > select { flex: 1; min-width: 0; }
			.ikev2-picker-row > .cbi-button { flex: none; }

			/* ── Network picker (selectable cards) ──────────────────── */
			.ikev2-netpick-grid {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr));
				gap: .7rem;
			}
			.ikev2-netpick {
				display: flex;
				align-items: center;
				gap: .7rem;
				padding: .7rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				cursor: pointer;
				transition: transform var(--ikev2-press) var(--ikev2-ease),
					border-color .14s var(--ikev2-ease), background .14s var(--ikev2-ease),
					box-shadow .14s var(--ikev2-ease);
			}
			.ikev2-netpick:hover { border-color: var(--ikev2-border-strong); }
			.ikev2-netpick.selected {
				border-color: var(--ikev2-accent);
				background: var(--ikev2-grad-soft);
				box-shadow: 0 0 0 1px var(--ikev2-accent) inset;
			}
			.ikev2-netpick input { position: absolute; opacity: 0; width: 0; height: 0; }
			.ikev2-netpick-check {
				flex: none;
				width: 1.3rem;
				height: 1.3rem;
				border-radius: var(--ikev2-radius-xs);
				border: 1.5px solid var(--ikev2-border-strong);
				display: grid;
				place-content: center;
				color: #fff;
				font-size: .82rem;
				line-height: 1;
				transition: background .14s var(--ikev2-ease), border-color .14s var(--ikev2-ease);
			}
			.ikev2-netpick.selected .ikev2-netpick-check {
				background: var(--ikev2-fill);
				border-color: transparent;
			}
			.ikev2-netpick.selected .ikev2-netpick-check::after { content: "\\2713"; }
			.ikev2-netpick-body { min-width: 0; }
			.ikev2-netpick-name { font-weight: 600; }
			.ikev2-netpick-meta {
				display: block;
				font-size: .8rem;
				color: var(--ikev2-muted);
				overflow-wrap: anywhere;
			}
			.ikev2-actions.end { justify-content: flex-end; }
			/* status on the left, action button hard-right (bottom of a block) */
			.ikev2-actions.spread { justify-content: space-between; width: 100%; }
			/* a block's primary actions, separated and right-aligned at the bottom */
			.ikev2-actions.bar {
				justify-content: flex-end;
				margin-top: 1.2rem;
				padding-top: 1rem;
				border-top: 1px solid var(--ikev2-border);
			}
			.ikev2-card.third { grid-column: span 4; }

			/* ── Tags ───────────────────────────────────────────────── */
			.ikev2-tags { display: flex; flex-wrap: wrap; gap: .4rem; }
			.ikev2-tag {
				display: inline-block;
				margin-left: .4rem;
				padding: .12rem .45rem;
				border: 1px solid color-mix(in srgb, currentColor 35%, transparent);
				border-radius: 999px;
				background: color-mix(in srgb, currentColor 10%, transparent);
				font-size: .7rem;
				font-weight: 600;
				vertical-align: middle;
			}
			.ikev2-tags .ikev2-tag { margin-left: 0; }
			.ikev2-tag.warn { color: var(--ikev2-warn); }
			.ikev2-tag.good { color: var(--ikev2-good); }
			.ikev2-tag-x {
				margin-left: .4rem;
				padding: 0;
				border: 0;
				background: none;
				color: inherit;
				cursor: pointer;
				opacity: .55;
				font-size: 1rem;
				line-height: 1;
			}
			.ikev2-tag-x:hover { opacity: 1; color: var(--ikev2-bad); }

			/* ── Layout helpers ─────────────────────────────────────── */
			.ikev2-two-col {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: 1rem;
			}
			.ikev2-inline-form {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .55rem;
			}
			/* Inputs/selects share the row width; the action button is pushed to the
			   right edge so it lines up with the bottom-right convention. */
			.ikev2-inline-form > input { flex: 1 1 12rem; min-width: 10rem; }
			.ikev2-inline-form > select { flex: 1 1 15rem; min-width: 12rem; }
			.ikev2-inline-form > .ikev2-device-picker { flex: 2 1 30rem; min-width: 20rem; }
			.ikev2-inline-form > .ikev2-device-picker select { width: 100%; }
			/* A custom address goes beside the picker, not under it, so the
			   row keeps its height and the type and Add stay where they were. */
			.ikev2-inline-form > .ikev2-device-picker .ikev2-choice-custom {
				display: flex;
				align-items: center;
				gap: .55rem;
			}
			.ikev2-inline-form > .ikev2-device-picker .ikev2-choice-custom > select { flex: 1 1 auto; min-width: 0; }
			.ikev2-inline-form > .ikev2-device-picker .ikev2-choice-custom > input { flex: 0 1 12rem; min-width: 8rem; }
			.ikev2-inline-form > .ikev2-device-picker + select {
				flex: 1 1 18rem;
				max-width: 24rem;
			}
			.ikev2-inline-form > .cbi-button { margin-left: auto; }
			.ikev2-status-box {
				margin: .9rem 0 0;
				padding: .75rem .9rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				font-size: .82rem;
				white-space: pre-wrap;
			}
			.ikev2-service-catalog {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: .4rem 2rem;
				align-items: start;
			}
			/* Scoped to the page on purpose: the shared .ikev2-page textarea
			   floor is a class plus an element, so a bare class selector here
			   loses the cascade and every editor stayed at the 6rem floor. */
			.ikev2-page .ikev2-domain-editor {
				width: 100%;
				min-height: 19rem;
				resize: vertical;
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				line-height: 1.5;
			}
			.ikev2-page .ikev2-domain-editor-small { min-height: 9rem; }
			/* In the service window a list takes what the screen has to give:
			   a prepared service runs to dozens of lines. After the rule it
			   narrows, and as specific, or the page-wide floor wins. */
			.ikev2-page .ikev2-dialog .ikev2-domain-editor {
				min-height: 12rem;
				height: min(30rem, 50vh);
			}
			/* Stacked, two tall lists would push the buttons far down. */
			@media (max-width: 720px) {
				.ikev2-page .ikev2-dialog .ikev2-domain-editor { height: 14rem; }
			}
			.ikev2-destination-editors {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: 1rem;
				margin: 1.1rem 0;
			}
			.ikev2-destination-editors > .ikev2-section {
				min-width: 0;
				margin: 0;
			}
			.ikev2-toggle-controls {
				display: inline-flex;
				align-items: center;
				justify-content: flex-end;
				gap: .65rem;
				flex: none;
			}
			.ikev2-service-editor-heading {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				margin-bottom: 1rem;
			}
			.ikev2-service-editor-heading h3 { margin: 0; }

			/* ── LuCI primitives inside page ────────────────────────── */
			/* A segmented control is the width of its segments. Stretched to the
			   content column it stopped reading as a control and started
			   reading as a toolbar with three links parked at the left. */
			.ikev2-page .cbi-tabmenu {
				display: inline-flex;
				width: auto;
				max-width: 100%;
				flex-wrap: wrap;
				gap: var(--ikev2-s1);
				margin: var(--ikev2-s4) 0;
				padding: var(--ikev2-s1);
				border: 1px solid var(--ikev2-border);
				border-radius: 999px;
				background: var(--ikev2-surface);
				list-style: none;
			}
			.ikev2-page .cbi-tabmenu li {
				margin: 0;
				border: 0;
				background: none;
			}
			.ikev2-page .cbi-tabmenu li a {
				display: block;
				padding: .45rem 1.1rem;
				border-radius: 999px;
				text-decoration: none;
				font-weight: 600;
				color: var(--ikev2-muted);
				transition: background .14s var(--ikev2-ease), color .14s var(--ikev2-ease);
			}
			.ikev2-page .cbi-tabmenu li.cbi-tab a {
				color: var(--ikev2-on-fill);
				background: var(--ikev2-fill);
			}
			.ikev2-page .cbi-tabmenu li:not(.cbi-tab) a:hover {
				color: inherit;
				background: var(--ikev2-surface-2);
			}
			.ikev2-page .cbi-tabmenu li.cbi-tab-disabled a:hover {
				color: var(--ikev2-muted);
				background: var(--ikev2-surface-2);
			}
			.ikev2-page .table { margin: .4rem 0 0; }
			.ikev2-page .table .th,
			.ikev2-page .table .td { vertical-align: middle; padding: .55rem .6rem; }
			.ikev2-page .table .tr.table-titles .th {
				font-size: .72rem;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-page .cbi-section-descr { color: var(--ikev2-muted); line-height: 1.5; }
			.ikev2-page code {
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
			}

			/* ── Busy state ─────────────────────────────────────────── */
			.ikev2-spin {
				display: inline-block;
				width: .85em;
				height: .85em;
				margin-right: .45rem;
				border: 2px solid currentColor;
				border-right-color: transparent;
				border-radius: 50%;
				vertical-align: -.12em;
				animation: ikev2-spin .6s linear infinite;
			}
			.ikev2-page button > .ikev2-spin:only-child { margin-right: 0; }
			@keyframes ikev2-spin { to { transform: rotate(360deg); } }

			/* ── Tunnel quality ─────────────────────────────────────── */
			/* A segmented control: one pressed state, the rest recede. The
			   pressed segment lifts onto the surface instead of filling with
			   accent colour, so it reads as a view choice, not an action. */
			.ikev2-page .ikev2-seg {
				display: inline-flex;
				padding: 3px;
				gap: 2px;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-page .ikev2-seg button {
				min-width: 3.2rem;
				padding: .3rem .7rem;
				border: 0;
				border-radius: calc(var(--ikev2-radius-sm) - 3px);
				background: transparent;
				color: var(--ikev2-muted);
				font: inherit;
				font-size: .82rem;
				font-weight: 600;
				font-variant-numeric: tabular-nums;
				cursor: pointer;
				transition: background-color .16s var(--ikev2-ease), color .16s var(--ikev2-ease),
					box-shadow .16s var(--ikev2-ease), transform var(--ikev2-press) ease-out;
			}
			.ikev2-page .ikev2-seg button:active { transform: scale(.96); }
			/* A neutral tint rather than the page colour: on a dark theme the
			   page colour is darker than the track and the pressed segment
			   would read as sunk instead of raised. */
			.ikev2-page .ikev2-seg button[aria-pressed="true"] {
				background: rgba(128, 128, 128, .3);
				color: inherit;
				box-shadow: var(--ikev2-e2);
			}
			.ikev2-page .ikev2-seg button:focus-visible {
				outline: 2px solid var(--ikev2-accent);
				outline-offset: 1px;
			}
			.ikev2-page .ikev2-quality-verdict {
				display: flex;
				flex-wrap: wrap;
				align-items: baseline;
				gap: .35rem .9rem;
				margin: 0 0 var(--ikev2-s3);
			}
			.ikev2-page .ikev2-quality-verdict b {
				font-size: 1.25rem;
				font-weight: 700;
				letter-spacing: -.015em;
			}
			.ikev2-page .ikev2-quality-verdict b.good { color: var(--ikev2-good); }
			.ikev2-page .ikev2-quality-verdict b.warn { color: var(--ikev2-warn); }
			.ikev2-page .ikev2-quality-verdict b.bad { color: var(--ikev2-bad); }
			.ikev2-page .ikev2-quality-verdict span {
				font-size: .88rem;
				color: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-quality-grid { margin: 0 0 var(--ikev2-s4); }
			.ikev2-page .ikev2-quality-chart {
				position: relative;
				margin: 0 0 var(--ikev2-s2);
				touch-action: pan-y;
				transition: opacity .18s var(--ikev2-ease);
			}
			.ikev2-page .ikev2-quality-chart.loading { opacity: .45; }
			.ikev2-page .ikev2-quality-chart svg {
				display: block;
				width: 100%;
				height: 14rem;
				overflow: visible;
			}
			.ikev2-page .ikev2-quality-chart .grid { stroke: var(--ikev2-border); stroke-width: 1; }
			.ikev2-page .ikev2-quality-chart .axis {
				fill: var(--ikev2-muted);
				font-size: 11px;
				font-variant-numeric: tabular-nums;
			}
			.ikev2-page .ikev2-quality-chart .tunnel {
				fill: none;
				stroke: var(--ikev2-accent);
				stroke-width: 2.25;
				stroke-linejoin: round;
				stroke-linecap: round;
			}
			.ikev2-page .ikev2-quality-chart .area { fill: url(#ikev2-quality-fill); stroke: none; }
			.ikev2-page .ikev2-quality-chart .direct {
				fill: none;
				stroke: var(--ikev2-muted);
				stroke-width: 1.5;
				stroke-dasharray: 3 4;
				stroke-linecap: round;
				opacity: .8;
			}
			.ikev2-page .ikev2-quality-chart .loss { fill: var(--ikev2-bad); opacity: .85; }
			.ikev2-page .ikev2-quality-chart .outage { fill: var(--ikev2-bad); opacity: .1; }
			.ikev2-page .ikev2-quality-chart .off { fill: var(--ikev2-muted); opacity: .1; }
			.ikev2-page .ikev2-quality-chart .maint { fill: var(--ikev2-info); opacity: .14; }
			.ikev2-page .ikev2-quality-chart .event { stroke: var(--ikev2-bg, Canvas); stroke-width: 2; }
			.ikev2-page .ikev2-quality-chart .event.warn { fill: var(--ikev2-warn); }
			.ikev2-page .ikev2-quality-chart .event.bad { fill: var(--ikev2-bad); }
			.ikev2-page .ikev2-quality-chart .event.good { fill: var(--ikev2-good); }
			.ikev2-page .ikev2-quality-chart .event.info { fill: var(--ikev2-info); }
			.ikev2-page .ikev2-quality-chart .cursor { stroke: var(--ikev2-border-strong); stroke-width: 1; }
			.ikev2-page .ikev2-quality-chart .cursor-dot {
				fill: var(--ikev2-accent);
				stroke: var(--ikev2-bg, Canvas);
				stroke-width: 2;
			}
			/* The readout follows the pointer without easing: it is feedback,
			   and any lag makes it feel detached from the hand. */
			.ikev2-page .ikev2-quality-tip {
				position: absolute;
				top: 0;
				z-index: 2;
				min-width: 9.5rem;
				padding: .5rem .65rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-bg, Canvas) 88%, transparent);
				-webkit-backdrop-filter: blur(14px) saturate(160%);
				backdrop-filter: blur(14px) saturate(160%);
				box-shadow: var(--ikev2-e2);
				font-size: .8rem;
				line-height: 1.45;
				font-variant-numeric: tabular-nums;
				pointer-events: none;
			}
			.ikev2-page .ikev2-quality-tip b { display: block; margin-bottom: .15rem; font-weight: 650; }
			.ikev2-page .ikev2-quality-tip span { color: var(--ikev2-muted); }
			.ikev2-page .ikev2-quality-legend {
				display: flex;
				flex-wrap: wrap;
				gap: .3rem 1.1rem;
				margin: 0 0 var(--ikev2-s4);
				font-size: .8rem;
				color: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-quality-legend i {
				display: inline-block;
				width: .9rem;
				height: .55rem;
				margin-right: .4rem;
				border-radius: 2px;
				vertical-align: baseline;
			}
			.ikev2-page .ikev2-quality-legend i.tunnel { height: 3px; background: var(--ikev2-accent); vertical-align: middle; }
			.ikev2-page .ikev2-quality-legend i.direct {
				height: 0;
				border-top: 2px dashed var(--ikev2-muted);
				vertical-align: middle;
			}
			.ikev2-page .ikev2-quality-legend i.loss { background: var(--ikev2-bad); }
			.ikev2-page .ikev2-quality-legend i.outage { background: color-mix(in srgb, var(--ikev2-bad) 22%, transparent); }
			.ikev2-page .ikev2-quality-legend i.maint { background: color-mix(in srgb, var(--ikev2-info) 28%, transparent); }
			.ikev2-page .ikev2-quality-empty {
				padding: 2.6rem 1rem;
				text-align: center;
				color: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-quality-lower {
				display: grid;
				grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr);
				gap: var(--ikev2-s5);
				align-items: start;
			}
			.ikev2-page .ikev2-quality-lower h4 {
				margin: 0 0 .55rem;
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-quality-events {
				display: grid;
				grid-template-columns: auto auto minmax(0, 1fr);
				gap: .45rem .6rem;
				align-items: center;
				margin: 0;
				padding: 0;
				list-style: none;
				font-size: .86rem;
			}
			.ikev2-page .ikev2-quality-events li { display: contents; }
			.ikev2-page .ikev2-quality-events time {
				color: var(--ikev2-muted);
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-page .ikev2-quality-events .dot {
				width: .5rem;
				height: .5rem;
				border-radius: 50%;
				background: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-quality-events .dot.good { background: var(--ikev2-good); }
			.ikev2-page .ikev2-quality-events .dot.warn { background: var(--ikev2-warn); }
			.ikev2-page .ikev2-quality-events .dot.bad { background: var(--ikev2-bad); }
			.ikev2-page .ikev2-quality-events .dot.info { background: var(--ikev2-info); }
			.ikev2-page .ikev2-quality-quiet { margin: 0; font-size: .86rem; color: var(--ikev2-muted); }
			/* One column per direction, the two paths on one scale in each:
			   the comparison is the point, so the shorter bar has to look
			   shorter at a glance, and the two directions never share a scale
			   they do not have in common. */
			.ikev2-page .ikev2-speed-results {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
				gap: var(--ikev2-s4) var(--ikev2-s5);
				margin: 0 0 .7rem;
			}
			.ikev2-page .ikev2-speed-column { display: grid; gap: .55rem; align-content: start; min-width: 0; }
			.ikev2-page .ikev2-speed-column-title { font-size: .86rem; font-weight: 650; }
			.ikev2-page .ikev2-speed-row { display: grid; gap: .3rem; }
			.ikev2-page .ikev2-speed-row-head {
				display: flex;
				justify-content: space-between;
				align-items: baseline;
				gap: .5rem;
				font-size: .84rem;
			}
			.ikev2-page .ikev2-speed-row-head > span { color: var(--ikev2-muted); }
			.ikev2-page .ikev2-speed-row-head b {
				font-size: .95rem;
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-page .ikev2-speed-row-head b.warn { color: var(--ikev2-warn); cursor: help; }
			.ikev2-page .ikev2-speed-row-head b.muted { color: var(--ikev2-muted); font-weight: 500; cursor: help; }
			.ikev2-page .ikev2-speed-ratio { font-size: .78rem; color: var(--ikev2-muted); font-variant-numeric: tabular-nums; }
			.ikev2-page .ikev2-speed-bar {
				height: .5rem;
				border-radius: 999px;
				background: var(--ikev2-surface-2);
				overflow: hidden;
			}
			.ikev2-page .ikev2-speed-bar > span {
				display: block;
				height: 100%;
				border-radius: inherit;
				background: var(--ikev2-grad);
				transform-origin: left center;
				transition: transform .45s var(--ikev2-ease);
			}
			.ikev2-page .ikev2-speed-bar.direct > span { background: var(--ikev2-muted); }
			/* The live CPU bar follows a one-second poll, so it moves quickly
			   and without overshoot; its colour warns before it saturates. */
			.ikev2-page .ikev2-speed-bar.cpu > span {
				background: var(--ikev2-accent);
				transition: transform .3s ease-out, background-color .3s ease-out;
			}
			.ikev2-page .ikev2-speed-bar.cpu > span.warn { background: var(--ikev2-warn); }
			.ikev2-page .ikev2-speed-bar.cpu > span.bad { background: var(--ikev2-bad); }
			.ikev2-page .ikev2-speed-meta { margin: 0 0 .7rem; font-size: .8rem; color: var(--ikev2-muted); }
			.ikev2-page .ikev2-speed-live {
				display: grid;
				gap: .45rem;
				margin: 0 0 .8rem;
				padding: .7rem .8rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface);
				font-size: .84rem;
			}
			.ikev2-page .ikev2-speed-live-head { display: flex; justify-content: space-between; gap: .5rem; }
			.ikev2-page .ikev2-speed-live-head b,
			.ikev2-page .ikev2-speed-live-cpu b { font-variant-numeric: tabular-nums; white-space: nowrap; }
			.ikev2-page .ikev2-speed-live-cpu {
				display: grid;
				grid-template-columns: auto minmax(0, 1fr) 3rem;
				gap: .6rem;
				align-items: center;
			}
			.ikev2-page .ikev2-speed-live-cpu > span { color: var(--ikev2-muted); }
			.ikev2-page .ikev2-speed-live-cpu b { text-align: right; }
			.ikev2-page .ikev2-speed-options {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: .6rem .8rem;
				margin: 0 0 .6rem;
				align-items: start;
			}
			.ikev2-page .ikev2-speed-option { display: grid; gap: .25rem; min-width: 0; }
			.ikev2-page .ikev2-speed-option > span {
				font-size: .72rem;
				font-weight: 600;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-page .ikev2-speed-option select,
			.ikev2-page .ikev2-speed-url input { width: 100%; }

			/* ── Motion / a11y ──────────────────────────────────────── */
			/* Cutting the transition alone left every end state in place, so a
			   reduced-motion user still got the card lift and the press scale -
			   just delivered as a jump, which is the part that provokes. Remove
			   the movement and keep the colour and border changes, which are
			   what actually says "this is the control you are on". */
			@media (prefers-reduced-motion: reduce) {
				.ikev2-page *,
				.ikev2-page *::before,
				.ikev2-page *::after {
					transition-duration: .01ms !important;
					animation-duration: .01ms !important;
				}
				.ikev2-card:hover,
				.ikev2-quick-link:hover,
				.ikev2-page .cbi-button:hover,
				.ikev2-page .cbi-button:active,
				.ikev2-quick-link:active,
				.ikev2-chip:active,
				.ikev2-netpick:active,
				.ikev2-service-option:active,
				.ikev2-advanced-toggle:active { transform: none; }
				.ikev2-spin { animation: none; opacity: .55; }
				.ikev2-page .ikev2-seg button:active { transform: none; }
				.ikev2-page .ikev2-speed-bar > span { transition: none; }
				/* The knob still has to say which side it is on; it just gets
				   there without travelling. */
				.ikev2-switch-track::after { transition: none; }
			}

			/* The surfaces here are neutral-grey tints rather than backdrop
			   glass, so the fix is opacity, not blur: raise every tint until it
			   separates on its own and drop the decorative gradient washes. */
			@media (prefers-reduced-transparency: reduce) {
				.ikev2-page {
					--ikev2-surface: rgba(128, 128, 128, .14);
					--ikev2-surface-2: rgba(128, 128, 128, .22);
					--ikev2-border: rgba(128, 128, 128, .42);
					--ikev2-border-strong: rgba(128, 128, 128, .6);
					--ikev2-grad-soft: rgba(128, 128, 128, .22);
				}
				.ikev2-hero { background: var(--ikev2-surface); }
				.ikev2-card::before { opacity: 1; }
				.ikev2-page .ikev2-quality-tip {
					background: var(--ikev2-bg, Canvas);
					-webkit-backdrop-filter: none;
					backdrop-filter: none;
				}
			}

			/* Near-solid grounds and a border that is present rather than
			   implied. Muted text stops being a tint of the background. */
			@media (prefers-contrast: more) {
				.ikev2-page {
					--ikev2-surface: rgba(128, 128, 128, .16);
					--ikev2-surface-2: rgba(128, 128, 128, .26);
					--ikev2-border: currentColor;
					--ikev2-border-strong: currentColor;
					--ikev2-muted: inherit;
					--ikev2-shadow: none;
					--ikev2-shadow-lg: none;
				}
				.ikev2-hero { background: var(--ikev2-surface); }
				.ikev2-page .cbi-button,
				.ikev2-card,
				.ikev2-section,
				.ikev2-chip,
				.ikev2-netpick,
				.ikev2-pill { border-width: 2px; }
				.ikev2-card::before { opacity: 1; }
			}

			/* ── Responsive ─────────────────────────────────────────── */
			@media (max-width: 900px) {
				.ikev2-service-catalog { grid-template-columns: 1fr; }
				.ikev2-card { grid-column: span 6; }
				.ikev2-card.wide { grid-column: 1 / -1; }
				.ikev2-hero { grid-template-columns: 1fr; }
				.ikev2-hero-side { flex-direction: row; flex-wrap: wrap; }
				.ikev2-widget-overview { grid-template-columns: 1fr; }
				.ikev2-user-card {
					grid-template-columns: minmax(10rem, .8fr) minmax(16rem, 1.4fr);
				}
				.ikev2-user-actions { grid-column: 1 / -1; }
				.ikev2-destination-editors { grid-template-columns: 1fr; }
				.ikev2-page .ikev2-quality-lower { grid-template-columns: 1fr; }
				/* Two fixed pickers plus an endpoint no longer fit one line. */
				.ikev2-dns-editor-choosable .ikev2-dns-endpoint {
					grid-template-columns: 1fr 1fr 2.4rem;
				}
				.ikev2-dns-editor-choosable .ikev2-dns-endpoint > input[type="text"] {
					grid-column: 1 / span 2;
				}
			}
			@media (max-width: 600px) {
				.ikev2-page .cbi-button { white-space: normal; text-align: center; }
				.ikev2-windows-app { grid-template-columns: auto 1fr; }
				.ikev2-windows-app > .ikev2-result,
				.ikev2-windows-app > button { grid-column: 1 / -1; }
				.ikev2-header, .ikev2-section-head { display: block; }
				.ikev2-header > *, .ikev2-section-head > * { margin-bottom: .8rem; }
				.ikev2-card, .ikev2-card.wide { grid-column: 1 / -1; }
				/* Four short numbers read better as a square than as a column. */
				.ikev2-page .ikev2-quality-grid .ikev2-card { grid-column: span 6; }
				.ikev2-page .ikev2-quality-grid .ikev2-card-value { font-size: 1.3rem; }
				.ikev2-form-grid { grid-template-columns: 1fr; gap: .4rem; }
				.ikev2-form-grid-compact { grid-template-columns: 1fr; }
				.ikev2-form-grid-compact > .ikev2-field-label { padding-top: 0; }
				/* Controls, not labels, close a pair; a toggle row is a pair
				   in one child, so the pairs are told by class, not by
				   position. */
				.ikev2-form-grid > :not(.ikev2-field-label) { margin-bottom: .8rem; }
				.ikev2-two-col { grid-template-columns: 1fr; }
				.ikev2-dns-endpoint,
				.ikev2-dns-editor-choosable .ikev2-dns-endpoint {
					grid-template-columns: minmax(0, 1fr) 2.4rem;
				}
				.ikev2-dns-endpoint > select { grid-column: 1 / span 2; }
				.ikev2-dns-endpoint > input[type="text"] { grid-column: 1; }
				.ikev2-page .table { display: block; overflow-x: auto; }
				.ikev2-user-card { grid-template-columns: 1fr; }
				.ikev2-user-actions { grid-column: auto; justify-content: flex-start; }
				.ikev2-session { align-items: flex-start; flex-direction: column; }
				.ikev2-widget-client { grid-template-columns: 1fr auto; }
				.ikev2-widget-duration { grid-column: 1; }
				.ikev2-widget-traffic { grid-column: 2; grid-row: 1 / span 2; }
				.ikev2-engine-head { align-items: stretch; flex-direction: column; }
				.ikev2-engine-action { justify-content: flex-start; }
				.ikev2-engine-action .cbi-button { width: 100%; min-width: 0; }
			}
	`;

// The Status Overview include re-renders on every poll. Returning a fresh
// <style> node each time replaced ~1300 lines of CSS in the live document
// several times a minute, forcing a full style recalculation and a visible
// flash. The sheet is static, so it is installed once per document instead.
// Callers place the result among the children of an E() call. LuCI's E()
// accepts a node or a string it can parse, and falls through to
// document.createElement() for anything else — so returning an empty string
// would raise InvalidCharacterError and break the whole page. An empty
// document fragment satisfies LuCI.dom.elem() and appends nothing.
function styles() {
	if (typeof document === 'undefined')
		return '';
	if (!document.getElementById(STYLE_ID))
		document.head.appendChild(E('style', { 'id': STYLE_ID }, [ CSS ]));
	return document.createDocumentFragment();
}

function pill(text, tone) {
	return E('span', { 'class': 'ikev2-pill ' + (tone || 'neutral') }, [ text ]);
}

function setPill(node, text, tone) {
	if (!node)
		return;
	node.className = 'ikev2-pill ' + (tone || 'neutral');
	node.textContent = text;
}

function icon(name) {
	var paths = {
		key: 'M21 2l-2 2m-7.6 7.6a5 5 0 1 1-7.1-7.1 5 5 0 0 1 7.1 7.1ZM11 11l4 4m0 0 2-2m-2 2-2 2',
		disconnect: 'M9 12h6m-3-3 3 3-3 3M5 5a9 9 0 1 0 14 0',
		trash: 'M3 6h18M8 6V4h8v2m-9 0 1 14h8l1-14M10 10v6m4-6v6',
		addUser: 'M15 19a6 6 0 0 0-12 0m6-8a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm9-2v6m-3-3h6',
		disconnectAll: 'M4 12h10m-3-3 3 3-3 3m7-8a8 8 0 1 1 0 10',
		sliders: 'M4 7h6m4 0h6M12 5v4M4 12h10m4 0h2M16 10v4M4 17h3m4 0h9M9 15v4',
		settings: 'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7.4-3.5a7.8 7.8 0 0 0-.1-1l2-1.6-2-3.4-2.5 1a8 8 0 0 0-1.7-1L14.7 3h-4L10 6a8 8 0 0 0-1.7 1L5.8 6 3.8 9.4l2 1.6a7.8 7.8 0 0 0 0 2L3.8 14.6l2 3.4 2.5-1a8 8 0 0 0 1.7 1l.7 3h4l.7-3a8 8 0 0 0 1.7-1l2.5 1 2-3.4-2-1.6a7.8 7.8 0 0 0 .1-1Z',
		down: 'M12 3v14m-5-5 5 5 5-5M5 21h14',
		up: 'M12 21V7m-5 5 5-5 5 5M5 3h14',
		download: 'M12 3v12m-4-4 4 4 4-4M5 21h14',
		windows: 'M3 5h8v7H3V5Zm10 0h8v7h-8V5ZM3 14h8v7H3v-7Zm10 0h8v7h-8v-7Z',
		phone: 'M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Zm2 3h4m-3 12h2',
		android: 'M7 9h10v8H7V9Zm2-3-2-2m8 2 2-2M9 12h.01M15 12h.01M5 10v6m14-6v6m-9 1v3m4-3v3',
		lock: 'M7 11V8a5 5 0 0 1 10 0v3M6 11h12v9H6v-9Z'
	};
	return E('<svg class="ikev2-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
		'<path d="' + (paths[name] || paths.key) + '"></path></svg>');
}

function header(title, subtitle, actions) {
	var actionItems = [];
	if (actions) {
		if (Array.isArray(actions))
			actionItems = actionItems.concat(actions);
		else
			actionItems.push(actions);
	}

	return E('div', { 'class': 'ikev2-header' }, [
		E('div', {}, [
			E('h2', {}, [ title ]),
			subtitle ? E('p', { 'class': 'ikev2-subtitle' }, [ subtitle ]) : ''
		]),
		E('div', { 'class': 'ikev2-header-actions' }, actionItems)
	]);
}

function card(label, value, detail, extraClass) {
	return E('div', { 'class': 'ikev2-card ' + (extraClass || '') }, [
		E('div', { 'class': 'ikev2-card-label' }, [ label ]),
		E('div', { 'class': 'ikev2-card-value' }, [ value ]),
		detail ? E('div', { 'class': 'ikev2-card-detail' }, [ detail ]) : ''
	]);
}

function section(title, description, content, actions) {
	return E('section', { 'class': 'ikev2-section' }, [
		E('div', { 'class': 'ikev2-section-head' }, [
			E('div', {}, [
				E('h3', {}, [ title ]),
				description ? E('p', {}, [ description ]) : ''
			]),
			actions || ''
		]),
		content
	]);
}

// Advanced options belong to the section they modify. A square toggle in that
// section's header opens them in place, instead of a disclosure block pushed
// below the controls it qualifies - which read as a separate subject and
// pushed the section's own actions further away the more of them there were.
function advancedPanel(content, label) {
	var title = label || _('Advanced settings');
	var panel = E('div', { 'class': 'ikev2-advanced-panel' }, [ content ]);
	var toggle = E('button', {
		'class': 'ikev2-advanced-toggle',
		'type': 'button',
		'title': title,
		'aria-label': title,
		'aria-expanded': 'false'
	}, [ icon('sliders') ]);
	panel.style.display = 'none';
	toggle.addEventListener('click', function(event) {
		// The toggle often sits inside a <summary>; a click on it must not also
		// collapse the panel it belongs to.
		if (event) {
			if (event.preventDefault) event.preventDefault();
			if (event.stopPropagation) event.stopPropagation();
		}
		var open = panel.style.display === 'none';
		panel.style.display = open ? '' : 'none';
		toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
		toggle.classList.toggle('ikev2-advanced-open', open);
	});
	return { toggle: toggle, panel: panel };
}

function keyValueTable(rows) {
	return E('table', { 'class': 'ikev2-kv' }, rows.map(function(row) {
		return E('tr', {}, [
			E('td', {}, [ row[0] ]),
			E('td', {}, [ row[1] == null || row[1] === '' ? '-' : row[1] ])
		]);
	}));
}

function fieldLabel(title, help) {
	return E('label', { 'class': 'ikev2-field-label' }, [
		title,
		help ? E('span', { 'class': 'ikev2-field-help' }, [ help ]) : ''
	]);
}

// A button reports on itself: a spinner while its action runs, then the
// outcome in its own colour and words. A busy label was longer than the idle
// one, in Russian by half, and widened the button into what stood beside it.
// A checkbox or a select cannot say anything, so its result stays in words.
function reportsOnButton(button) {
	return !!(button && String(button.tagName || '').toLowerCase() === 'button');
}

// The outcome shown on the button itself, where the eye already is: a success
// for three seconds, a failure or a warning until the button is used again.
// The width is held, so a short result does not shrink the button, and an
// icon button keeps to the mark.
function flashButton(button, kind, text, detail) {
	if (!button)
		return;
	if (button.ikev2FlashRestore)
		button.ikev2FlashRestore();
	var mark = { ok: '✓', err: '✕', warn: '!' }[kind] || '';
	var shown = String(button.textContent || '').trim() ? mark + ' ' + text : mark;
	var html = button.innerHTML, title = button.title || '', width = button.style.width || '';
	var cls = ' ikev2-flash ikev2-flash-' + kind;
	var timer = null;
	if (button.offsetWidth)
		button.style.width = button.offsetWidth + 'px';
	button.className += cls;
	button.textContent = shown;
	// A short button (Add) cannot hold the word: the mark alone, the word in
	// the tooltip, rather than a squeezed label.
	if (button.scrollWidth > button.clientWidth + 1)
		button.textContent = shown = mark;
	button.title = detail || text;
	function restore() {
		button.ikev2FlashRestore = null;
		if (timer && typeof window !== 'undefined' && window.clearTimeout)
			window.clearTimeout(timer);
		button.className = String(button.className).split(cls).join('');
		// A refresh may have relabelled the button meanwhile; keep that label.
		if (button.textContent === shown)
			button.innerHTML = html;
		button.title = title;
		button.style.width = width;
		if (button.removeEventListener)
			button.removeEventListener('click', restore, true);
	}
	button.ikev2FlashRestore = restore;
	if (kind !== 'ok') {
		if (button.addEventListener)
			button.addEventListener('click', restore, true);
	}
	else if (typeof window !== 'undefined' && window.setTimeout)
		timer = window.setTimeout(restore, 3000);
}

// A form the page refuses to send: the button says so and the reason goes
// under it, the same as a failure the router reported.
function refuse(button, result, message) {
	if (result)
		result.err(message);
	if (reportsOnButton(button))
		flashButton(button, 'err', _('Check the form'), message);
}

// A result short enough for a button, or nothing.
function buttonWords(text) {
	text = String(text || '').replace(/[.…]+$/, '').trim();
	return text.length && text.length <= 22 ? text : '';
}

// A button stays busy until the page has read the new state, and that read
// often decides whether the button is usable (a Save button greys out once the
// form matches the router). Such a decision, made while busy, becomes the state
// the button returns to instead of being overwritten by the one it started in.
function holdDisabled(button) {
	if (Object.prototype.hasOwnProperty.call(button, 'disabled') &&
	    Object.getOwnPropertyDescriptor(button, 'disabled').set)
		return;
	Object.defineProperty(button, 'disabled', {
		configurable: true,
		enumerable: true,
		get: function() { return true; },
		set: function(value) { button.dataset.idleDisabled = value ? '1' : '0'; }
	});
	button.setAttribute('disabled', '');
}

function setBusy(button, busy, label) {
	if (!button)
		return;
	var rewritesContent = String(button.tagName || '').toLowerCase() === 'button';
	if (busy) {
		if (button.dataset.busy !== '1') {
			button.dataset.idleDisabled = button.disabled ? '1' : '0';
			// Keep the button at least as wide as it was, so the busy label does not
			// shrink it and pull the rest of the row along.
			button.dataset.idleMinWidth = button.style.minWidth || '';
			if (button.offsetWidth)
				button.style.minWidth = button.offsetWidth + 'px';
			if (rewritesContent) {
				button.dataset.idleLabel = button.textContent;
				button.dataset.idleHtml = button.innerHTML;
			}
		}
		button.dataset.busy = '1';
		button.disabled = true;
		button.setAttribute('aria-busy', 'true');
		// A disabled button alone reads as broken. The spinner says the action was
		// accepted and is still running, which is the difference between "nothing
		// happened" and "wait". The words come with the outcome (flashButton).
		if (rewritesContent) {
			button.replaceChildren(E('span', { 'class': 'ikev2-spin', 'aria-hidden': 'true' }));
			button.dataset.busyText = button.textContent;
			holdDisabled(button);
		}
	}
	else {
		if (button.dataset.busy !== '1')
			return;
		delete button.dataset.busy;
		if (rewritesContent)
			delete button.disabled;
		button.disabled = button.dataset.idleDisabled === '1';
		delete button.dataset.idleDisabled;
		button.style.minWidth = button.dataset.idleMinWidth || '';
		delete button.dataset.idleMinWidth;
		button.removeAttribute('aria-busy');
		// A relabel made while the button was still busy is the newer state.
		var relabelled = button.dataset.busyText != null &&
			button.textContent !== button.dataset.busyText;
		delete button.dataset.busyText;
		if (rewritesContent && !relabelled) {
			if (button.dataset.idleHtml != null)
				button.innerHTML = button.dataset.idleHtml;
			else
				button.textContent = button.dataset.idleLabel || button.textContent;
		}
	}
}

// rpcd refuses a call the session's ACL does not cover. On its own its wording
// names neither the cause nor anything the reader can act on, and it is not a
// failure of the operation the button describes - so say where it came from.
function errorMessage(error, fallback) {
	var message = (error && error.message) ||
		(typeof error === 'string' ? error : '') ||
		fallback || _('Operation failed');
	if (/permission denied|access denied/i.test(message))
		return _('Permission denied by the router: this call is not covered by the application\'s rpcd rules.');
	return message;
}

function execChecked(path, args, fallback) {
	return fs.exec(path, args || []).then(function(response) {
		if (response && response.code)
			throw new Error(((response.stderr || response.stdout || '').trim()) ||
				fallback || _('Operation failed'));
		return response || {};
	});
}

function delay(ms) {
	return new Promise(function(resolve) { window.setTimeout(resolve, ms); });
}

// Poll a key=value status command for one exact backend action id. A unique id
// prevents a stale status from an earlier click being mistaken for this run.
function pollAction(path, args, actionId, options) {
	options = options || {};
	var deadline = Date.now() + (options.timeout || 90000);
	var interval = options.interval || 1500;

	function once() {
		return L.resolveDefault(fs.exec(path, args || []), { stdout: '' }).then(function(response) {
			var status = parseKeyValues((response && response.stdout) || '');
			if (options.onProgress)
				options.onProgress(status);
			if (status.action_id === actionId &&
			    (status.state === 'ok' || status.state === 'error'))
				return status;
			if (Date.now() >= deadline)
				return null;
			return delay(interval).then(once);
		});
	}

	return once();
}

// Standard action lifecycle for every button:
// idle -> spinner -> outcome on the button -> idle.
// The button stays busy until onSuccess has read the new state, so it goes
// from the spinner straight to its outcome. A relabel or a disable made in
// onSuccess (Pause becoming Resume, Save greying out) is kept, not overwritten
// by the state saved when the action started. A failure and a warning are also
// written out under the button; progress and success only for screen readers.
// A checkbox or a select keeps its written result and is restored before
// onSuccess, as before.
function runAction(options) {
	options = options || {};
	var button = options.button;
	var result = options.result;
	var onButton = reportsOnButton(button);
	setBusy(button, true, options.busy || _('Working...'));
	if (result && result.quiet)
		result.quiet(true);
	if (result && onButton)
		result.busy(options.busy || _('Working...'));
	else if (result && result.clear)
		result.clear();

	// The button shows what the action last reported: a run that ended in a
	// warning ("continues in the background") or a failure it wrote itself
	// must not turn green.
	function showOutcome() {
		var last = result && result.last ? result.last() : { kind: 'ok', text: '' };
		if (last.kind === 'err')
			flashButton(button, 'err', options.failed || _('Failed'), last.text);
		else if (last.kind === 'warn')
			flashButton(button, 'warn', buttonWords(last.text) || _('Attention'), last.text);
		else
			flashButton(button, 'ok', options.done || buttonWords(last.kind === 'ok' ? last.text : '') ||
				buttonWords(options.success) || _('Done'), last.text || options.success);
	}

	return Promise.resolve().then(options.run).then(function(value) {
		if (options.success && result)
			result.ok(options.success);
		// A button that shows its own outcome stays busy while onSuccess reads
		// the new state, so it goes from the spinner straight to the result
		// instead of flashing its idle look in between.
		if (!onButton)
			setBusy(button, false);
		return Promise.resolve(options.onSuccess ? options.onSuccess(value) : null).then(function() {
			setBusy(button, false);
			if (onButton)
				showOutcome();
			return value;
		});
	}).catch(function(error) {
		setBusy(button, false);
		var message = errorMessage(error, options.failure);
		if (result)
			result.err(message);
		// The reason does not fit on a button; it stays on the line under it.
		if (onButton)
			flashButton(button, 'err', options.failed || _('Failed'), message);
		if (options.onError)
			options.onError(message, error);
		return null;
	}).finally(function() {
		setBusy(button, false);
		// Only this action's own report is left to its button; whatever the
		// page writes to the same line later is written out again.
		if (result && result.quiet)
			result.quiet(false);
	});
}

// Show a backend progress step beside the button unless it only repeats what
// the button already says. "Queued..." is the backend's first word for every
// action and tells nobody anything.
function showProgress(result, message, busyLabel) {
	if (!result || !message || message === 'Queued...')
		return;
	var text = _(message);
	if (text === busyLabel)
		return;
	result.busy(text);
}

// Start a detached backend action. The starter must return action_id=<id>
// immediately; completion is read from the supplied status command.
function runJob(options) {
	options = options || {};
	return runAction({
		button: options.button,
		result: options.result,
		busy: options.busy,
		failure: options.failure,
		done: options.done,
		failed: options.failed,
		run: function() {
			return execChecked(options.startPath, options.startArgs, options.failure)
				.then(function(response) {
					var started = parseKeyValues(response.stdout || '');
					var actionId = started.action_id;
					if (!actionId && options.allowImmediate) {
						if (options.result)
							options.result.ok(options.success || _('Done'));
						return { state: 'ok', immediate: true };
					}
					if (!actionId)
						throw new Error(options.failure || _('Action did not start'));
					var statusArgs = (options.statusArgs || []).slice();
					if (options.statusIdArg !== false)
						statusArgs.push(actionId);
					return pollAction(options.statusPath, statusArgs, actionId, {
						timeout: options.timeout,
						interval: options.interval,
						onProgress: function(status) {
							if (options.onProgress)
								options.onProgress(status);
							if (options.progress !== false &&
							    status.action_id === actionId && status.state === 'running')
								showProgress(options.result, status.message, options.busy);
						}
					}).then(function(status) {
						if (!status) {
							if (options.result)
								options.result.warn(options.timeoutMessage ||
									_('The operation is still running in the background.'));
							if (options.onTimeout)
								options.onTimeout();
							return { state: 'timeout', action_id: actionId };
						}
						if (status.state === 'error')
							throw new Error(status.message ? _(status.message) :
								(options.failure || _('Operation failed')));
						if (options.result)
							options.result.ok(options.success || _('Done'));
						return status;
					});
				});
		},
		onSuccess: options.onSuccess,
		onError: options.onError
	});
}

// Save and Apply buttons stay grey until what they would save differs from
// what the page was loaded with, or last saved. The state is read from the form
// controls inside the given nodes, so composite fields - lists that grow a row,
// a choice with a custom value - count without knowing their internals.
function formState(nodes) {
	var parts = [];
	nodes.forEach(function(node) {
		if (!node)
			return;
		var own = /^(input|select|textarea)$/i.test(String(node.tagName || ''));
		var controls = own ? [ node ] :
			Array.prototype.slice.call(node.querySelectorAll ?
				node.querySelectorAll('input, select, textarea') : []);
		controls.forEach(function(control) {
			var type = String(control.type || '').toLowerCase();
			if (type === 'button' || type === 'submit' || type === 'file')
				return;
			parts.push(type === 'checkbox' || type === 'radio' ?
				(control.checked ? '1' : '0') : String(control.value == null ? '' : control.value));
		});
	});
	return JSON.stringify(parts);
}

// Keep BUTTONS (one or a list that saves the same form) disabled while the
// controls in NODES are unchanged. Call reset() once a save has succeeded and
// the page shows what the router now has. options.read replaces the DOM
// reading; options.blocked adds a reason of its own to keep the buttons
// disabled (dependencies missing, say).
function trackChanges(buttons, nodes, options) {
	options = options || {};
	buttons = (Array.isArray(buttons) ? buttons : [ buttons ]).filter(Boolean);
	var sources = (Array.isArray(nodes) ? nodes : [ nodes ]).filter(Boolean);
	var read = options.read || function() { return formState(sources); };
	var baseline = read();
	var tracker = {
		dirty: function() {
			return read() !== baseline;
		},
		update: function() {
			var disabled = !tracker.dirty() || !!(options.blocked && options.blocked());
			// A busy button takes this as the state to return to (holdDisabled),
			// so a reset() in onSuccess greys the button out once it is done.
			buttons.forEach(function(button) {
				button.disabled = disabled;
			});
		},
		reset: function() {
			baseline = read();
			tracker.update();
		}
	};
	function later() {
		window.setTimeout(tracker.update, 0);
	}
	sources.forEach(function(node) {
		if (!node.addEventListener)
			return;
		[ 'input', 'change', 'click', 'keyup', 'paste' ].forEach(function(name) {
			node.addEventListener(name, later);
		});
	});
	tracker.update();
	return tracker;
}

function copyText(text) {
	if (navigator.clipboard && navigator.clipboard.writeText)
		return navigator.clipboard.writeText(text);
	var input = E('textarea', {
		'style': 'position:fixed;left:-9999px;top:-9999px;'
	}, [ text ]);
	document.body.appendChild(input);
	input.select();
	document.execCommand('copy');
	input.remove();
	return Promise.resolve();
}

function switchLabel(input, text) {
	return E('label', { 'class': 'ikev2-switch' }, [
		input,
		E('span', { 'class': 'ikev2-switch-track' }),
		text ? E('span', { 'class': 'ikev2-switch-text' }, [ text ]) : ''
	]);
}

// A finite set of safe presets with an explicit final Custom… branch. The
// current value is always preserved: an unknown value selects Custom and is
// shown in the input instead of being replaced by a default.
function choiceWithCustom(value, choices, options) {
	options = options || {};
	var customValue = '__ikev2_custom__';
	var field = E('input', Object.assign({
		'type': options.type || 'text',
		'class': 'cbi-input-text',
		'placeholder': options.placeholder || ''
	}, options.attrs || {}));
	var select = E('select', { 'class': 'cbi-input-select' },
		(choices || []).map(function(choice) {
			return E('option', { 'value': String(choice.value) }, [ choice.label ]);
		}).concat([
			E('option', { 'value': customValue }, [ options.customLabel || _('Custom…') ])
		]));
	var node = E('div', { 'class': 'ikev2-choice-custom' }, [ select, field ]);

	function hasChoice(next) {
		return (choices || []).some(function(choice) {
			return String(choice.value) === String(next == null ? '' : next);
		});
	}

	function sync() {
		var custom = select.value === customValue;
		field.style.display = custom ? '' : 'none';
		field.disabled = !custom;
	}

	function setValue(next) {
		next = String(next == null ? '' : next);
		field.value = next;
		select.value = hasChoice(next) ? next : customValue;
		sync();
	}

	select.addEventListener('change', function() {
		if (select.value !== customValue)
			field.value = select.value;
		sync();
	});
	setValue(value);
	return {
		node: node,
		select: select,
		input: field,
		value: function() { return select.value === customValue ? field.value.trim() : select.value; },
		setValue: setValue
	};
}

// Multi-value counterpart used for detected firewall zones. Known values are
// checkboxes; values no longer present on the router stay in the Custom field.
function multiChoiceWithCustom(value, choices, options) {
	options = options || {};
	var picks = [];
	var customField = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'placeholder': options.placeholder || ''
	});
	var knownNodes = (options.prependNodes || []).slice();
	knownNodes = knownNodes.concat((choices || []).map(function(choice) {
			var pick = netPick(String(choice.value), choice.name || choice.label,
				choice.meta || '', false);
			picks.push(pick);
			return pick.node;
		}));
	var list = E('div', { 'class': 'ikev2-netpick-grid' }, knownNodes);
	var customPick = netPick('__custom__', options.customLabel || _('Custom…'),
		options.customMeta || '', false);
	var customList;
	if (options.customBelow)
		customList = E('div', { 'class': 'ikev2-netpick-grid' }, [ customPick.node ]);
	else {
		list.appendChild(customPick.node);
		customList = '';
	}
	var node = E('div', { 'class': 'ikev2-choice-custom' },
		[ list, customList, customField ]);

	function sync() {
		customField.style.display = customPick.input.checked ? '' : 'none';
		customField.disabled = !customPick.input.checked;
	}

	function setValue(next) {
		var selected = String(next || '').trim().split(/\s+/).filter(Boolean);
		var known = {};
		picks.forEach(function(pick) {
			known[pick.input.value] = true;
			pick.setChecked(selected.indexOf(pick.input.value) >= 0);
		});
		var custom = selected.filter(function(item) { return !known[item]; });
		customField.value = custom.join(' ');
		customPick.setChecked(custom.length > 0 || !picks.length);
		sync();
	}

	customPick.input.addEventListener('change', sync);
	setValue(value);
	return {
		node: node,
		value: function() {
			var selected = picks.filter(function(pick) { return pick.input.checked; })
				.map(function(pick) { return pick.input.value; });
			if (customPick.input.checked)
				selected = selected.concat(customField.value.trim().split(/\s+/).filter(Boolean));
			return selected.filter(function(item, index) { return selected.indexOf(item) === index; }).join(' ');
		},
		setValue: setValue
	};
}

// A labelled toggle row: title/description on the left, switch on the right.
function toggleRow(input, title, sub, status) {
	return E('div', { 'class': 'ikev2-toggle-row' }, [
		E('div', {}, [
			E('span', { 'class': 'ikev2-toggle-text' }, [ title ]),
			sub ? E('span', { 'class': 'ikev2-toggle-sub' }, [ sub ]) : ''
		]),
		E('div', { 'class': 'ikev2-toggle-controls' }, [
			status || '',
			switchLabel(input, '')
		])
	]);
}

// Selectable network card (modern replacement for a bare checkbox). Returns
// { node, input }; the card highlights when its hidden checkbox is checked.
function netPick(value, name, meta, checked) {
	var input = E('input', { 'type': 'checkbox', 'value': value, 'checked': checked ? '' : null });
	var card = E('label', { 'class': 'ikev2-netpick' + (checked ? ' selected' : '') }, [
		input,
		E('span', { 'class': 'ikev2-netpick-check' }),
		E('span', { 'class': 'ikev2-netpick-body' }, [
			E('span', { 'class': 'ikev2-netpick-name' }, [ name ]),
			meta ? E('span', { 'class': 'ikev2-netpick-meta' }, [ meta ]) : ''
		])
	]);
	function setChecked(next) {
		input.checked = !!next;
		card.classList.toggle('selected', input.checked);
	}
	input.addEventListener('change', function() { setChecked(input.checked); });
	return { node: card, input: input, setChecked: setChecked };
}

// Inline status chip shown next to an action button instead of a top-of-page
// notification. err() truncates with a hover tooltip carrying the full text.
function inlineResult() {
	var node = E('span', { 'class': 'ikev2-result idle' }, []);
	var fadeTimer = null, hideTimer = null;
	// While an action runs, only a failure or a warning is written out here:
	// those are read. A success is seen on the button, or in the checkbox or
	// select the operator just changed.
	var onButton = '';
	var last = { kind: '', text: '' };
	function stopFade() {
		if (typeof window === 'undefined' || !window.clearTimeout) return;
		window.clearTimeout(fadeTimer);
		window.clearTimeout(hideTimer);
		fadeTimer = hideTimer = null;
	}
	function set(cls, text, full) {
		stopFade();
		node.className = 'ikev2-result ' + cls + onButton;
		node.textContent = text;
		node.title = full || text;
		last = { kind: cls, text: full || '' };
	}
	// A success is read in a few seconds and then only takes space.
	function fadeLater() {
		if (typeof window === 'undefined' || !window.setTimeout) return;
		fadeTimer = window.setTimeout(function() {
			node.className += ' fading';
			hideTimer = window.setTimeout(function() {
				node.className = 'ikev2-result idle' + onButton;
				node.textContent = '';
				node.title = '';
			}, 650);
		}, 6000);
	}
	return {
		node: node,
		busy: function(msg) { set('busy', msg || _('Working...'), ''); },
		ok: function(msg) { set('ok', '✓ ' + (msg || _('Done')), msg || ''); if (!onButton) fadeLater(); },
		warn: function(msg) { set('warn', '… ' + (msg || _('Still running')), msg || ''); },
		err: function(msg) { set('err', '✕ ' + (msg || _('Failed')), msg || ''); },
		clear: function() {
			stopFade();
			node.className = 'ikev2-result idle' + onButton;
			node.textContent = '';
			node.title = '';
			last = { kind: '', text: '' };
		},
		last: function() { return last; },
		quiet: function(flag) { onButton = flag ? ' quiet' : ''; }
	};
}

function inputToken() {
	var random = Math.floor(Math.random() * 0x100000000).toString(36);
	return Date.now().toString(36) + '-' + random;
}

function gate(title, subtitle) {
	return E('div', { 'class': 'ikev2-page' }, [
		header(title, subtitle),
		E('div', { 'class': 'ikev2-empty', 'style': 'padding:2.4rem 1.6rem' }, [
			E('div', { 'style': 'font-size:1.1rem;font-weight:680;margin-bottom:.4rem' }, [
				_('Runtime dependencies are not installed') ]),
			E('p', { 'style': 'margin:0 auto 1.2rem;max-width:34rem' }, [
				_('Install the runtime dependencies on the Overview page, then this page becomes available.') ]),
			E('a', { 'class': 'ikev2-quick-link',
				'href': L.url('admin', 'services', 'ikev2-manager', 'setup') }, [
				_('Go to Overview') ])
		])
	]);
}

return baseclass.extend({
	parseKeyValues: parseKeyValues,
	parseSwanmon: parseSwanmon,
	formatBytes: formatBytes,
	formatDuration: formatDuration,
	formatDate: formatDate,
	formatDateTime: formatDateTime,
	daysUntil: daysUntil,
	styles: styles,
	pill: pill,
	setPill: setPill,
	icon: icon,
	header: header,
	gate: gate,
	switchLabel: switchLabel,
	toggleRow: toggleRow,
	netPick: netPick,
	choiceWithCustom: choiceWithCustom,
	multiChoiceWithCustom: multiChoiceWithCustom,
	inlineResult: inlineResult,
	inputToken: inputToken,
	card: card,
	section: section,
	advancedPanel: advancedPanel,
	keyValueTable: keyValueTable,
	fieldLabel: fieldLabel,
	setBusy: setBusy,
	execChecked: execChecked,
	pollAction: pollAction,
	runAction: runAction,
	refuse: refuse,
	flashButton: flashButton,
	showProgress: showProgress,
	runJob: runJob,
	formState: formState,
	trackChanges: trackChanges,
	copyText: copyText
});
