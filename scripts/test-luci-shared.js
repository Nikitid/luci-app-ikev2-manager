'use strict';

// shared.js was stubbed out by every other JS test, so nothing ever evaluated
// it. That hid a page-breaking regression: styles() returned an empty string,
// and LuCI's E() falls through to document.createElement() for anything that is
// neither a node nor markup, so every view raised InvalidCharacterError.
//
// The E() dispatch below mirrors luci.js so this test fails the same way the
// browser did.

const assert = require('assert');
const fsNode = require('fs');

let createdTags = [];

class Node {
	constructor(nodeType, tag) {
		this.nodeType = nodeType;
		this.tagName = tag;
		this.childNodes = [];
		this.attributes = {};
		this.id = '';
		this.dataset = {};
		this.disabled = false;
		this.style = {};
		this.offsetWidth = 0;
	}
	replaceChildren(...nodes) {
		this.childNodes = nodes;
	}
	appendChild(child) {
		if (child == null || typeof child !== 'object' || !('nodeType' in child))
			throw new TypeError('appendChild expects a node');
		// A document fragment contributes its children and then itself is empty.
		if (child.nodeType === 11) {
			child.childNodes.forEach(item => this.childNodes.push(item));
			child.childNodes = [];
			return child;
		}
		this.childNodes.push(child);
		return child;
	}
	setAttribute(name, value) {
		this.attributes[name] = value;
		if (name === 'id')
			this.id = value;
	}
	removeAttribute(name) {
		delete this.attributes[name];
	}
	get textContent() {
		return this.childNodes.map(item =>
			typeof item === 'string' ? item : item.textContent).join('');
	}
	set textContent(value) {
		this.childNodes = [ String(value) ];
	}
	get innerHTML() {
		return this.childNodes.map(item =>
			typeof item === 'string' ? item : item.textContent).join('');
	}
	set innerHTML(value) {
		this.childNodes = [ String(value) ];
	}
}

const document = {
	head: new Node(1, 'head'),
	byId: {},
	createElement(tag) {
		createdTags.push(tag);
		// The real DOM raises this for an empty or otherwise invalid tag name.
		if (typeof tag !== 'string' || !/^[A-Za-z][A-Za-z0-9-]*$/.test(tag))
			throw new Error('InvalidCharacterError: The string contains invalid characters.');
		return new Node(1, tag);
	},
	createDocumentFragment() {
		return new Node(11, null);
	},
	createTextNode(value) {
		const node = new Node(3, null);
		node.value = String(value);
		Object.defineProperty(node, 'textContent', { get: () => node.value });
		return node;
	},
	getElementById(id) {
		return document.byId[id] || null;
	},
	querySelectorAll() {
		return [];
	}
};

function isNode(value) {
	return value != null && typeof value === 'object' && 'nodeType' in value;
}

// Mirrors the dispatch in luci.js: array -> fragment, node -> as is,
// string starting with '<' -> parsed markup, anything else -> createElement.
function E(html, attr, data) {
	let elem;
	if (!(attr instanceof Object) || Array.isArray(attr)) {
		data = attr;
		attr = null;
	}
	if (Array.isArray(html)) {
		elem = document.createDocumentFragment();
		html.forEach(item => elem.appendChild(E(item)));
	}
	else if (isNode(html)) {
		elem = html;
	}
	else if (typeof html === 'string' && html.charCodeAt(0) === 60) {
		elem = new Node(1, 'parsed');
	}
	else {
		elem = document.createElement(html);
	}
	if (attr)
		Object.keys(attr).forEach(name => {
			if (attr[name] != null)
				elem.setAttribute(name, attr[name]);
		});
	if (data != null) {
		const items = Array.isArray(data) ? data : [ data ];
		items.forEach(item => {
			if (item == null || item === '')
				return;
			elem.appendChild(isNode(item) ? item : document.createTextNode(item));
		});
	}
	if (elem.id)
		document.byId[elem.id] = elem;
	return elem;
}

// LuCI installs this on String.prototype; shared.js relies on it.
if (!String.prototype.format)
	String.prototype.format = function() {
		const args = Array.prototype.slice.call(arguments);
		return this.replace(/%[sd]/g, () => String(args.shift()));
	};

// LuCI's cbi.js declares _() globally; resources call it directly.
const nativeTranslate = value => 'native:' + value;
globalThis._ = nativeTranslate;
const windowStub = {
	_: nativeTranslate,
	navigator: { language: 'en-US' },
	localStorage: { getItem: () => null, setItem: () => {} },
	setTimeout: () => {}
};

const baseclass = { extend: object => object };
const fs = {};

const source = fsNode.readFileSync('luci-ikev2-manager/shared.js', 'utf8');
const factory = new Function(
	'window', 'document', 'L', 'baseclass', 'fs', 'E', source);
const common = factory(windowStub, document, {}, baseclass, fs, E);

// The regression: whatever styles() returns is placed among E() children.
createdTags = [];
const first = common.styles();
assert(isNode(first), 'styles() must return something LuCI.dom.elem() accepts');
assert(!createdTags.includes(''),
	'styles() caused document.createElement("")');

// Passing it through E() the way every view does must not throw.
assert.doesNotThrow(() => E([ first, E('div', {}, [ 'x' ]) ]),
	'the styles() result is not accepted as an E() child');

// The stylesheet is installed once per document, not rebuilt on every render.
const injected = document.head.childNodes.filter(node => node.tagName === 'style');
assert.strictEqual(injected.length, 1, 'the stylesheet was not installed');
common.styles();
common.styles();
assert.strictEqual(
	document.head.childNodes.filter(node => node.tagName === 'style').length, 1,
	'the stylesheet was installed more than once');

// Strings resolve through LuCI's own translator, and the module never replaces
// it: that would change every other application on shared pages such as
// Status Overview.
assert.strictEqual(windowStub._, nativeTranslate,
	'shared.js replaced the global translation function');
assert.strictEqual(globalThis._, nativeTranslate,
	'shared.js replaced the global translation function');
assert.strictEqual(common.formatDuration(90), 'native:1m',
	'durations do not go through the LuCI catalogue');

// Spot-check a couple of exported helpers actually run.
assert.strictEqual(common.formatBytes(0), '0 B');
assert.strictEqual(typeof common.pill('x', 'good'), 'object');

// Busy state may wrap buttons, checkboxes and selects. Non-button controls
// must retain their contents and current value while disabled.
const select = E('select', {}, [ E('option', {}, [ 'Warnings' ]), E('option', {}, [ 'Debug' ]) ]);
select.value = 'debug';
const selectMarkup = select.innerHTML;
common.setBusy(select, true, 'Applying...');
assert.strictEqual(select.innerHTML, selectMarkup, 'setBusy erased select options');
assert.strictEqual(select.value, 'debug', 'setBusy changed select value');
assert.strictEqual(select.disabled, true, 'setBusy did not disable select');
common.setBusy(select, false);
assert.strictEqual(select.innerHTML, selectMarkup, 'setBusy did not preserve select options');
assert.strictEqual(select.value, 'debug', 'setBusy did not preserve select value');
assert.strictEqual(select.disabled, false, 'setBusy did not restore select state');

// rpcd hands a session its grants when the session is created, so a page left
// open across an upgrade that adds a helper call keeps the older set and the
// call is refused. Surfacing rpcd's bare wording reads as a bug in the app;
// the message has to name the cause and what clears it.
(async () => {
	const captured = [];
	const sink = {
		busy() {}, ok() {},
		err(text) { captured.push(text); }
	};
	await common.runAction({
		result: sink,
		run() { throw new Error('Permission denied'); }
	});
	assert.strictEqual(captured.length, 1, 'runAction did not report the failure');
	assert.ok(/rpcd/i.test(captured[0]),
		'a permission denial is still reported as rpcd words it: ' + captured[0]);
	assert.ok(captured[0].length > 'Permission denied'.length,
		'the permission message says nothing beyond the refusal: ' + captured[0]);

	captured.length = 0;
	await common.runAction({
		result: sink,
		run() { throw new Error('Invalid DNS upstream'); }
	});
	assert.strictEqual(captured[0], 'Invalid DNS upstream',
		'an ordinary failure was rewritten as a permission problem');

	// The result line is where a failure explains itself. Clipping it to one
	// line turns the messages that say what to do into a fragment.
	const styles = fsNode.readFileSync('luci-ikev2-manager/shared.js', 'utf8');
	const resultStart = styles.search(/\n\s*\.ikev2-result \{/);
	const resultRule = styles.slice(resultStart, styles.indexOf('.ikev2-result.busy'));
	assert.ok(resultStart > 0, 'the result line rule is missing');
	assert.ok(!/white-space:\s*nowrap/.test(resultRule),
		'the result line is clipped to one line again');
	assert.ok(!/text-overflow:\s*ellipsis/.test(resultRule),
		'the result line still truncates with an ellipsis');

	// Button lifecycle, as the pages use it. A button keeps to a spinner while
	// its action runs, stays busy until onSuccess has read the new state, and
	// then shows the outcome itself: a success for three seconds, a failure or a
	// warning until it is used again. Only those two are also written out.
	const timers = [];
	const realSetTimeout = windowStub.setTimeout;
	windowStub.setTimeout = (fn, ms) => { timers.push([ fn, ms ]); return timers.length; };
	windowStub.clearTimeout = () => {};
	function actionButton(label) {
		const button = E('button', {}, [ label ]);
		button.className = 'cbi-button';
		button.offsetWidth = 120;
		const listeners = {};
		button.addEventListener = (type, fn) => { listeners[type] = fn; };
		button.removeEventListener = type => { delete listeners[type]; };
		button.click = () => listeners.click && listeners.click();
		return button;
	}
	const result = common.inlineResult();

	const pause = actionButton('Pause tunnel routing');
	let labelWhileBusy = null, widthWhileBusy = null, busyDuringRefresh = null;
	await common.runAction({
		button: pause, result, busy: 'Pausing...', success: 'Paused.',
		run() { labelWhileBusy = pause.textContent; widthWhileBusy = pause.style.minWidth; },
		// The page reads the new state: Pause becomes Resume, and a form that
		// now matches the router greys its button out.
		onSuccess() {
			busyDuringRefresh = pause.dataset.busy;
			pause.textContent = 'Resume tunnel routing';
			pause.disabled = true;
		}
	});
	assert.ok(!labelWhileBusy.includes('Pausing'), 'the button grew its busy label');
	assert.strictEqual(widthWhileBusy, '120px', 'the button width was not held while busy');
	assert.strictEqual(busyDuringRefresh, '1', 'the button showed its idle look before the result');
	assert.strictEqual(pause.textContent, '✓ Paused', 'the success was not shown on the button');
	assert.ok(/ikev2-flash-ok/.test(pause.className), 'the success was not coloured');
	assert.ok(/quiet/.test(result.node.className), 'the success was written out beside the button');
	assert.strictEqual(pause.disabled, true, 'the restore overrode the state set in onSuccess');
	const flashTimer = timers.find(item => item[1] === 3000);
	assert.ok(flashTimer, 'the success did not return after three seconds');
	flashTimer[0]();
	assert.strictEqual(pause.textContent, 'Resume tunnel routing',
		'the button did not return to the label the refresh gave it');
	assert.strictEqual(pause.className, 'cbi-button', 'the success colour stayed');
	assert.strictEqual(pause.style.minWidth, '', 'the width hold was not released');

	// A failure: red, with the reason under the button, until it is used again.
	timers.length = 0;
	const restart = actionButton('Restart reliable mode');
	await common.runAction({
		button: restart, result, busy: 'Restarting...', failed: 'Failed',
		run() { throw new Error('FakeIP resolver did not answer'); },
		onError() { assert.ok(!restart.dataset.busy, 'onError saw a busy button'); }
	});
	assert.strictEqual(restart.textContent, '✕ Failed', 'the failure was not shown on the button');
	assert.ok(/ikev2-flash-err/.test(restart.className), 'the failure was not coloured');
	assert.strictEqual(restart.title, 'FakeIP resolver did not answer', 'the reason was lost');
	assert.ok(/\berr\b/.test(result.node.className) && result.node.textContent.includes('did not answer'),
		'the reason was not written under the button');
	assert.ok(!timers.some(item => item[1] === 3000), 'a failure cleared itself');
	restart.click();
	assert.strictEqual(restart.textContent, 'Restart reliable mode', 'using the button again did not clear the failure');

	// An action that ended by reporting a warning itself does not turn green.
	const install = actionButton('Install');
	await common.runAction({
		button: install, result, busy: 'Installing...',
		run() { result.warn('The operation continues in the background.'); }
	});
	assert.ok(/ikev2-flash-warn/.test(install.className), 'a warning showed as a success: ' + install.textContent);
	assert.ok(result.node.textContent.includes('continues in the background'), 'the warning was not written out');

	// A long success message gives way to a short word on the button.
	const save = actionButton('Save');
	await common.runAction({
		button: save, result, busy: 'Saving...',
		run() { result.ok('Saved. All names now resolve through the tunnel.'); }
	});
	assert.ok(save.textContent.endsWith('Done') && !save.textContent.includes('Saved'),
		'a long message was squeezed onto the button: ' + save.textContent);
	assert.strictEqual(save.title, 'Saved. All names now resolve through the tunnel.', 'the full message was lost');

	// An icon-only button shows the mark alone.
	const icon = E('button', {}, [ E('span', {}, []) ]);
	icon.className = 'cbi-button';
	await common.runAction({ button: icon, result, busy: 'Generating...', run() {} });
	assert.strictEqual(icon.textContent, '✓', 'an icon button was blown up by its result: ' + icon.textContent);

	// A form saved in onSuccess greys its Save button out once the action ends.
	const applyButton = actionButton('Apply router settings');
	const applyField = E('input', {}, []);
	applyField.value = 'a';
	const applyTracker = common.trackChanges(applyButton, [ applyField ], { read: () => applyField.value });
	applyField.value = 'b';
	applyTracker.update();
	assert.strictEqual(applyButton.disabled, false, 'a changed form left Apply grey');
	await common.runAction({
		button: applyButton, result, busy: 'Applying...', success: 'Applied',
		onSuccess() { applyTracker.reset(); }
	});
	assert.strictEqual(applyButton.disabled, true, 'Apply stayed usable after the form was saved');

	// What the page writes to the same line after the action is written out.
	result.ok('VPN user saved.');
	assert.ok(!/quiet/.test(result.node.className), 'a later message was hidden with the button result');

	// A ticked box shows its own success, so no line appears to move the
	// section below; its failure is written out.
	const checkbox = E('input', {}, []);
	const boxResult = common.inlineResult();
	await common.runAction({ button: checkbox, result: boxResult, busy: 'Saving...', success: 'Saved.' });
	assert.ok(/quiet/.test(boxResult.node.className), 'a checkbox success was written out');
	await common.runAction({ button: checkbox, result: boxResult, busy: 'Saving...',
		run() { throw new Error('Device routing failed'); } });
	// The .quiet rule spares .err, so this class alone keeps it on screen.
	assert.ok(/\berr\b/.test(boxResult.node.className), 'a checkbox failure was hidden');

	// A button too short for the word shows the mark alone.
	const add = actionButton('Add');
	Object.defineProperty(add, 'scrollWidth', { get: () => add.textContent.length > 2 ? 90 : 40 });
	add.clientWidth = 60;
	await common.runAction({ button: add, result, busy: 'Adding...', success: 'Saved' });
	assert.strictEqual(add.textContent, '✓', 'a short button squeezed its result: ' + add.textContent);
	assert.strictEqual(add.title, 'Saved', 'the word was lost from the tooltip');
	windowStub.setTimeout = realSetTimeout;

	const lines = [];
	const line = {
		clear() { lines.length = 0; },
		busy(text) { lines.push('busy:' + text); },
		ok(text) { lines.push('ok:' + text); },
		err(text) { lines.push('err:' + text); },
		warn(text) { lines.push('warn:' + text); }
	};

	// Progress beside the button skips the backend's "Queued..." and anything
	// the button already says, and shows a genuinely new step.
	lines.length = 0;
	common.showProgress(line, 'Queued...', 'native:Restarting PBR...');
	common.showProgress(line, 'Restarting PBR...', 'native:Restarting PBR...');
	common.showProgress(line, 'Waiting for other router actions...', 'native:Restarting PBR...');
	assert.deepStrictEqual(lines, [ 'busy:native:Waiting for other router actions...' ],
		'progress filter: ' + lines.join(' | '));

	// Save buttons are grey until the form differs from what it was loaded with;
	// going back to the loaded value greys them again, and reset() takes the
	// saved state as the new baseline.
	const field = E('input', {}, []);
	field.type = 'text';
	field.value = 'wan';
	const toggle = E('input', {}, []);
	toggle.type = 'checkbox';
	toggle.checked = true;
	const apply = E('button', {}, [ 'Apply' ]);
	const second = E('button', {}, [ 'Save' ]);
	let blocked = false;
	const tracker = common.trackChanges([ apply, second ], [ field, toggle ], {
		blocked: () => blocked
	});
	assert.strictEqual(apply.disabled, true, 'an unchanged form left Apply enabled');
	field.value = 'wan2';
	tracker.update();
	assert.strictEqual(apply.disabled, false, 'a changed field did not enable Apply');
	assert.strictEqual(second.disabled, false, 'the second button of the same form stayed grey');
	field.value = 'wan';
	tracker.update();
	assert.strictEqual(apply.disabled, true, 'reverting the change left Apply enabled');
	toggle.checked = false;
	tracker.update();
	assert.strictEqual(apply.disabled, false, 'a changed switch did not enable Apply');
	blocked = true;
	tracker.update();
	assert.strictEqual(apply.disabled, true, 'a blocking condition was ignored');
	blocked = false;
	// The form is changed, so an idle button would be enabled here. A busy
	// button stays disabled and takes the tracker's word for afterwards.
	common.setBusy(apply, true, 'Applying...');
	tracker.update();
	assert.strictEqual(apply.disabled, true, 'the tracker changed a button a running action owns');
	common.setBusy(apply, false);
	assert.strictEqual(apply.disabled, false, 'a changed form left Apply grey after the action');
	toggle.checked = false;
	tracker.reset();
	assert.strictEqual(apply.disabled, true, 'reset did not take the saved state as the baseline');

	console.log('luci shared module tests OK');
})();
