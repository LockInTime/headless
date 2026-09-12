import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';

const runtimeSource = await readFile(
  new URL('../Sources/HeadlessProtocol/Resources/AgentRuntime.js', import.meta.url),
  'utf8',
);

const fixture = await readFile(new URL('Fixtures/large-document.html', import.meta.url), 'utf8');
const dom = new JSDOM(fixture, {
  runScripts: 'dangerously',
  url: 'http://127.0.0.1:41739/large-document',
});
const {window} = dom;
window.TextEncoder = TextEncoder;
Object.defineProperties(window, {
  innerWidth: {value: 1160, configurable: true},
  innerHeight: {value: 760, configurable: true},
  scrollX: {value: 0, writable: true, configurable: true},
  scrollY: {value: 0, writable: true, configurable: true},
});
Object.defineProperty(window.HTMLElement.prototype, 'innerText', {
  configurable: true,
  get() { return this.textContent ?? ''; },
  set(value) { this.textContent = value; },
});
window.getComputedStyle = element => ({
  display: element.style?.display || 'block',
  visibility: element.style?.visibility || 'visible',
  opacity: element.style?.opacity || '1',
  getPropertyValue(property) { return element.style?.getPropertyValue(property) || ''; },
});
const positions = new WeakMap();
let nextPosition = 0;
window.Element.prototype.getBoundingClientRect = function getBoundingClientRect() {
  if (!positions.has(this)) positions.set(this, nextPosition++);
  const top = positions.get(this) * 64;
  return {x: 24, y: top, top, left: 24, right: 824, bottom: top + 48, width: 800, height: 48};
};
window.Element.prototype.scrollIntoView = () => {};
window.scrollTo = options => { window.scrollY = Number(options?.top || 0); };
window.scrollBy = options => { window.scrollY += Number(options?.top || 0); };
window.document.getAnimations = () => [];
Object.defineProperties(window.document.documentElement, {
  scrollWidth: {value: 1160, configurable: true},
  scrollHeight: {value: 32000, configurable: true},
});

window.eval(runtimeSource);
const agent = window.__headlessAgent;
assert(agent, 'agent runtime should initialize');

const full = agent.snapshot(false, false, {context: 'full'});
assert.equal(full.contextMode, 'full');
assert(full.elements.length > 200, 'large fixture should produce a broad full snapshot');

const summary = agent.snapshot(false, false, {
  context: 'summary',
  task: 'Linux service-account authentication',
  limit: 8,
  budget: 700,
});
assert.equal(summary.contextMode, 'summary');
assert(summary.contextStats.encodedBytes <= 2800, 'summary should respect its estimated-token budget');
assert(summary.regions.some(region => region.name === 'Linux service-account authentication'));
assert(summary.omitted.regions > 0, 'summary should disclose omitted regions');
assert.equal(summary.untrustedContent, true, 'page-derived content should be marked untrusted');

const outline = agent.snapshot(false, false, {
  context: 'outline',
  task: 'Linux service-account authentication',
  limit: 8,
  budget: 900,
});
const targetRegion = outline.regions.find(region => region.name === 'Linux service-account authentication');
assert.match(targetRegion?.ref ?? '', /^@r\d+$/);

const scopedText = agent.snapshot(false, false, {
  context: 'text',
  within: targetRegion.ref,
  task: 'Ubuntu service account',
  limit: 4,
  budget: 700,
});
assert.equal(scopedText.within, targetRegion.ref);
assert(scopedText.snippets.some(snippet => snippet.text.includes('short-lived service account')));
assert(scopedText.snippets.length <= 4);

const scopedActions = agent.snapshot(false, false, {
  context: 'actions',
  within: targetRegion.ref,
  task: 'copy authentication command',
  limit: 5,
  budget: 700,
});
assert(scopedActions.elements.some(element => element.name === 'Copy authentication command'));
assert(scopedActions.elements.every(element => element.actions.length > 0));

// Budget pruning measures every candidate once and removes the largest item
// wherever it appears, without discarding smaller entries that follow it.
const pruningFixture = window.document.createElement('section');
pruningFixture.innerHTML = `
  <p>Budget prefix should survive.</p>
  <p>${'🚧'.repeat(300)}</p>
  <p>Budget suffix should survive.</p>
`;
for (const [index, paragraph] of [...pruningFixture.querySelectorAll('p')].entries()) {
  paragraph.getBoundingClientRect = () => ({
    x: 24, y: 100 + index * 50, top: 100 + index * 50, left: 24,
    right: 824, bottom: 148 + index * 50, width: 800, height: 48,
  });
}
window.document.getElementById('content').prepend(pruningFixture);
let encodeCalls = 0;
const NativeTextEncoder = window.TextEncoder;
window.TextEncoder = class CountingTextEncoder extends NativeTextEncoder {
  encode(value) {
    encodeCalls += 1;
    return super.encode(value);
  }
};
const middlePruned = agent.snapshot(false, false, {context: 'text', limit: 4, budget: 256});
window.TextEncoder = NativeTextEncoder;
assert(
  middlePruned.snippets.some(item => item.text === 'Budget suffix should survive.'),
  JSON.stringify(middlePruned),
);
assert(!middlePruned.snippets.some(item => item.text.includes('🚧')));
assert(encodeCalls <= 8, 'budget pruning should encode the result and each candidate only once');
assert(middlePruned.contextStats.encodedBytes <= 1024);
assert.equal(
  new TextEncoder().encode(JSON.stringify(middlePruned)).length,
  middlePruned.contextStats.encodedBytes,
  'reported bytes should include the finalized context statistics',
);

assert.throws(
  () => agent.snapshot(false, false, {context: 'text', within: '@r999999'}),
  error => error.headlessCode === 'REGION_NOT_FOUND' && /REGION_NOT_FOUND/.test(error.message),
);

// A region reference issued by an earlier inspection stays usable, which is
// what makes the outline-then-scope workflow possible across calls.
assert.equal(
  agent.snapshot(false, false, {context: 'text', within: targetRegion.ref, limit: 2}).within,
  targetRegion.ref,
);
assert.throws(
  () => agent.snapshot(false, false, {context: 'text', within: '@r999999'}),
  /REGION_NOT_FOUND.*unknown/,
);

// Element references describe the most recent inspection only. A stale one has
// to say it expired, otherwise an agent cannot tell "re-inspect" from
// "this element never existed" and retries the dead reference.
const staleRef = full.elements[full.elements.length - 1].ref;
assert.match(staleRef, /^@e\d+$/);
agent.snapshot(false, false, {context: 'summary', limit: 8, budget: 700});
assert.throws(
  () => agent.click({target: staleRef}),
  error => error.headlessCode === 'ELEMENT_NOT_FOUND' && /ELEMENT_NOT_FOUND.*expired/.test(error.message),
);
assert.throws(
  () => agent.click({target: '@e999999'}),
  error => error.headlessCode === 'ELEMENT_NOT_FOUND' && /ELEMENT_NOT_FOUND.*unknown/.test(error.message),
);

// A reference from the latest inspection still resolves.
const fresh = agent.snapshot(false, false, {context: 'actions', limit: 5});
assert(fresh.elements.length > 0, 'actions context should return executable controls');
assert.equal(agent.click({target: fresh.elements[0].ref}).clicked, fresh.elements[0].ref);

// Exercise the command surface against controls with unique semantic names.
const controls = window.document.createElement('section');
controls.innerHTML = `
  <button type="button" aria-label="Runtime action">Run</button>
  <input aria-label="Runtime input">
  <a href="javascript:alert(1)" aria-label="Unsafe runtime link">Unsafe</a>
  <div role="button" aria-label="Read only runtime control" tabindex="0">Read only</div>
`;
window.document.body.prepend(controls);
const button = controls.querySelector('button');
const input = controls.querySelector('input');
button.getBoundingClientRect = () => ({x: 20, y: 20, top: 20, left: 20, right: 120, bottom: 60, width: 100, height: 40});
input.getBoundingClientRect = () => ({x: 20, y: 80, top: 80, left: 20, right: 220, bottom: 120, width: 200, height: 40});
let clicks = 0;
let inputs = 0;
let changes = 0;
const pressed = [];
button.addEventListener('click', () => { clicks += 1; });
input.addEventListener('input', () => { inputs += 1; });
input.addEventListener('change', () => { changes += 1; });
input.addEventListener('keydown', event => pressed.push(`down:${event.key}`));
input.addEventListener('keyup', event => pressed.push(`up:${event.key}`));

window.document.elementFromPoint = () => button;
const trustedClickTarget = agent.inputTarget({role: 'button', name: 'Runtime action'}, 'click');
assert.match(trustedClickTarget.ref, /^@e\d+$/);
assert.equal(trustedClickTarget.role, 'button');
assert(Number.isFinite(trustedClickTarget.x) && Number.isFinite(trustedClickTarget.y));
window.document.elementFromPoint = () => input;
const trustedFillTarget = agent.inputTarget({role: 'textbox', name: 'Runtime input'}, 'fill');
assert.equal(trustedFillTarget.role, 'textbox');
window.document.elementFromPoint = () => window.document.body;
assert.throws(
  () => agent.inputTarget({role: 'button', name: 'Runtime action'}, 'click'),
  /ELEMENT_OBSCURED/,
);

const clicked = agent.click({role: 'button', name: 'Runtime action'});
assert.match(clicked.clicked, /^@e\d+$/);
assert.equal(clicks, 1, 'click should dispatch exactly once');
const filled = agent.fill({role: 'textbox', name: 'Runtime input', value: 'private value'});
assert.equal(filled.valueLength, 13);
assert.equal(filled.value, undefined, 'fill responses must not echo values');
assert.equal(input.value, 'private value');
assert.equal(inputs, 1);
assert.equal(changes, 1);
assert.equal(agent.press('A').pressed, 'A');
assert.deepEqual(pressed, ['down:A', 'up:A']);
assert.throws(
  () => agent.fill({role: 'button', name: 'Read only runtime control', value: 'no'}),
  /NOT_EDITABLE/,
);
assert.throws(
  () => agent.click({role: 'link', name: 'Unsafe runtime link'}),
  error => error.headlessCode === 'UNSAFE_NAVIGATION' && /UNSAFE_NAVIGATION:javascript:/.test(error.message),
);

window.__headlessNavigationAllowlist = Object.freeze(['127.0.0.1']);
const offAllowlist = window.document.createElement('a');
offAllowlist.href = 'https://example.com/';
offAllowlist.setAttribute('aria-label', 'Off allowlist link');
window.document.body.prepend(offAllowlist);
assert.throws(
  () => agent.click({role: 'link', name: 'Off allowlist link'}),
  error => error.headlessCode === 'UNSAFE_NAVIGATION',
);
const onAllowlist = window.document.createElement('a');
onAllowlist.href = 'http://127.0.0.1:41739/next';
onAllowlist.setAttribute('aria-label', 'On allowlist link');
window.document.body.prepend(onAllowlist);
assert.equal(agent.click({role: 'link', name: 'On allowlist link'}).role, 'link');

const offAllowlistForm = window.document.createElement('form');
offAllowlistForm.action = 'https://example.com/';
offAllowlistForm.method = 'get';
offAllowlistForm.addEventListener('submit', event => event.preventDefault());
const offAllowlistSubmit = window.document.createElement('button');
offAllowlistSubmit.type = 'submit';
offAllowlistSubmit.textContent = 'Leave via form';
offAllowlistForm.append(offAllowlistSubmit);
window.document.body.prepend(offAllowlistForm);
assert.throws(
  () => agent.click({role: 'button', name: 'Leave via form'}),
  error => error.headlessCode === 'UNSAFE_NAVIGATION',
);
const formactionSubmit = window.document.createElement('button');
formactionSubmit.type = 'submit';
formactionSubmit.setAttribute('formaction', 'https://example.com/leave');
formactionSubmit.textContent = 'Leave via formaction';
const localForm = window.document.createElement('form');
localForm.action = 'http://127.0.0.1:41739/next';
localForm.addEventListener('submit', event => event.preventDefault());
localForm.append(formactionSubmit);
window.document.body.prepend(localForm);
assert.throws(
  () => agent.click({role: 'button', name: 'Leave via formaction'}),
  error => error.headlessCode === 'UNSAFE_NAVIGATION',
);
const localSubmit = window.document.createElement('button');
localSubmit.type = 'submit';
localSubmit.textContent = 'Stay via form';
localForm.append(localSubmit);
assert.equal(agent.click({role: 'button', name: 'Stay via form'}).role, 'button');
window.__headlessNavigationAllowlist = [];
assert.equal(agent.click({role: 'link', name: 'Off allowlist link'}).role, 'link');
assert.equal(agent.click({role: 'button', name: 'Leave via form'}).role, 'button');

window.scrollY = 0;
const downward = agent.scroll({direction: 'down', amount: 300});
assert.equal(downward.direction, 'down');
assert.equal(downward.amount, 300);
assert.equal(window.scrollY, 300);
agent.scroll({direction: 'up', amount: 125});
assert.equal(window.scrollY, 175);
agent.scroll({direction: 'top'});
assert.equal(window.scrollY, 0);
agent.scroll({direction: 'bottom'});
assert.equal(window.scrollY, 32000);

const pageState = agent.state();
assert.equal(pageState.url, 'http://127.0.0.1:41739/large-document');
assert.equal(pageState.contentHeight, 32000);
assert.equal(pageState.runningAnimations, 0);
assert(pageState.text.includes('Run'));
assert(pageState.text.length <= 30000, 'state text must stay bounded');

const authenticationFixture = window.document.createElement('section');
authenticationFixture.innerHTML = `
  <form method="post" aria-label="Sign in">
    <input type="email" autocomplete="username" aria-label="Email">
    <input type="password" autocomplete="current-password" aria-label="Password">
    <button type="submit">Sign in</button>
  </form>
`;
window.document.body.append(authenticationFixture);
const confirmedAuthentication = agent.authentication();
assert.equal(confirmedAuthentication.origin, 'http://127.0.0.1:41739');
assert.equal(confirmedAuthentication.detection, 'confirmed');
assert.match(confirmedAuthentication.accountTarget, /^@e\d+$/);
assert.match(confirmedAuthentication.passwordTarget, /^@e\d+$/);
assert.match(confirmedAuthentication.submitTarget, /^@e\d+$/);
assert.equal(JSON.stringify(confirmedAuthentication).includes('value'), false);

let credentialInputData = 'not-fired';
authenticationFixture.querySelector('input[type="password"]').addEventListener('input', event => {
  credentialInputData = event.data;
});
authenticationFixture.querySelector('form').addEventListener('submit', event => event.preventDefault());
const credentialFillResult = agent.credentialFill({
  origin: confirmedAuthentication.origin,
  accountTarget: confirmedAuthentication.accountTarget,
  passwordTarget: confirmedAuthentication.passwordTarget,
  submitTarget: confirmedAuthentication.submitTarget,
  account: 'person@example.test',
  password: 'runtime-only-secret',
});
assert.equal(credentialFillResult.submitted, true);
assert.equal(credentialInputData, undefined, 'saved credentials must not enter InputEvent.data');
agent.finishCredentialFill({passwordTarget: confirmedAuthentication.passwordTarget});
assert.equal(authenticationFixture.querySelector('input[type="password"]').value, '');

authenticationFixture.querySelector('form').setAttribute('method', 'get');
assert.equal(agent.authentication().detection, 'hint', 'GET password forms must not trigger autofill');
authenticationFixture.querySelector('form').setAttribute('method', 'post');
authenticationFixture.querySelector('button').setAttribute('formaction', 'https://other.example.test/login');
assert.equal(agent.authentication().detection, 'hint', 'cross-origin submitters must not trigger autofill');

authenticationFixture.innerHTML = `
  <form aria-label="Change security code">
    <input type="password" aria-label="Old code">
    <input type="password" aria-label="New code">
    <button type="submit">Update</button>
  </form>
`;
assert.equal(agent.authentication().detection, 'hint', 'password rotation must not trigger autofill');

authenticationFixture.innerHTML = '<input autocomplete="one-time-code" aria-label="Verification code">';
assert.equal(agent.authentication().detection, 'additional-verification');

authenticationFixture.innerHTML = `
  <form method="post" aria-label="Sign in">
    <input autocomplete="username" aria-label="Email">
    <input type="password" autocomplete="current-password" aria-label="Password">
    <input autocomplete="one-time-code" aria-label="Verification code">
    <button type="submit">Sign in</button>
  </form>
`;
assert.equal(
  agent.authentication().detection,
  'additional-verification',
  'combined password and MFA forms must not trigger saved credential fill',
);

authenticationFixture.innerHTML = '<button data-webauthn="true">Use a passkey</button>';
assert.equal(agent.authentication().detection, 'passkey');

authenticationFixture.innerHTML = '<button type="button">Sign in</button>';
assert.equal(agent.authentication().detection, 'hint', 'username-first login should remain a hint');

authenticationFixture.innerHTML = `
  <iframe src="https://accounts.example.test/login"></iframe>
  <h1>Welcome</h1>
`;
assert.equal(
  agent.authentication().detection,
  'cross-origin',
  'cross-origin authentication frames should return an explicit continuation state',
);
authenticationFixture.remove();

const stationaryTour = await agent.tour({fullPage: false});
assert.equal(stationaryTour.start, stationaryTour.end);
assert.equal(stationaryTour.durationMs, 0);
Object.defineProperty(window.document.documentElement, 'scrollHeight', {
  value: 1000,
  configurable: true,
});
const fullTour = await agent.tour({fullPage: true, pace: 5000});
assert.equal(fullTour.start, 0);
assert.equal(fullTour.end, 240);
assert.equal(fullTour.durationMs, 500);
assert.equal(window.scrollY, 240);

// A very tall page must produce an explicit, end-anchored 80-point cap.
Object.defineProperty(window.document.documentElement, 'scrollHeight', {
  value: 100000,
  configurable: true,
});
window.scrollY = 321;
const viewportPlan = agent.screenshotPlan({mode: 'viewport'});
assert.equal(viewportPlan.initialY, 321);
assert.equal(viewportPlan.points.length, 80);
assert.equal(viewportPlan.truncated, true);
assert(viewportPlan.totalPoints > viewportPlan.points.length);
assert.equal(viewportPlan.points.at(-1).y, 100000 - window.innerHeight);

// Section plans deduplicate points within 96 px and apply the same hard cap.
const sectionRoot = window.document.createElement('main');
for (let index = 0; index < 100; index += 1) {
  const heading = window.document.createElement('h2');
  heading.textContent = `Runtime section ${index + 1}`;
  heading.getBoundingClientRect = () => ({
    x: 24,
    y: index * 200,
    top: index * 200,
    left: 24,
    right: 824,
    bottom: index * 200 + 48,
    width: 800,
    height: 48,
  });
  sectionRoot.append(heading);
}
window.document.body.append(sectionRoot);
window.scrollY = 0;
const sectionPlan = agent.screenshotPlan({mode: 'section'});
assert.equal(sectionPlan.points.length, 80);
assert.equal(sectionPlan.truncated, true);
for (let index = 1; index < sectionPlan.points.length; index += 1) {
  assert(
    sectionPlan.points[index].y - sectionPlan.points[index - 1].y > 96,
    'section capture points within 96 px should be deduplicated',
  );
}

// Once result arrays are exhausted, budget pruning must fall back to chopping
// page text instead of returning an oversized response.
const budgetedText = agent.snapshot(false, true, {context: 'full', limit: 1, budget: 256});
assert(budgetedText.contextStats.encodedBytes <= 1024);
assert(budgetedText.text.length < 30000, 'text fallback should be shortened to fit the budget');
assert.equal(budgetedText.contextStats.budgetApplied, true);
assert.equal(
  new TextEncoder().encode(JSON.stringify(budgetedText)).length,
  budgetedText.contextStats.encodedBytes,
);

const uploadControls = window.document.createElement('section');
uploadControls.innerHTML = `
  <label for="runtime-resume">Resume</label>
  <input id="runtime-resume" type="file">
  <button type="button" aria-label="Not a file">Skip</button>
`;
window.document.body.prepend(uploadControls);
const fileInput = uploadControls.querySelector('input[type="file"]');
fileInput.getBoundingClientRect = () => ({
  x: 20, y: 140, top: 140, left: 20, right: 220, bottom: 180, width: 200, height: 40,
});
window.document.elementFromPoint = () => fileInput;
window.__headlessFileUpload = false;
const webkitFileSnapshot = agent.snapshot(false, false, {context: 'full', limit: 250});
const webkitFileItem = webkitFileSnapshot.elements.find(
  element => element.name === 'Resume' && element.inputType === 'file',
);
assert.equal(webkitFileItem?.inputType, 'file');
assert.equal(webkitFileItem?.actions?.length ?? 0, 0);
assert.ok(!(webkitFileItem?.actions ?? []).includes('upload'));
window.__headlessFileUpload = true;
agent.snapshot(false, false, {context: 'actions', limit: 20});
const fileSnapshot = agent.snapshot(false, false, {context: 'actions', task: 'upload Resume', limit: 20});
const fileItem = fileSnapshot.elements.find(element => element.name === 'Resume');
assert.equal(fileItem?.inputType, 'file');
assert.equal(fileItem?.actions?.length, 1);
assert.equal(fileItem?.actions?.[0], 'upload');
assert.equal(agent.fileInput({role: 'textbox', name: 'Resume'}), fileInput);
assert.equal(agent.fileInputMetadata(fileInput).uploaded, fileItem.ref);
assert.throws(
  () => agent.fileInput({role: 'button', name: 'Not a file'}),
  error => error.headlessCode === 'ELEMENT_NOT_FOUND' && /not a file input/.test(error.message),
);
assert.throws(
  () => agent.fileInput({role: 'button', name: 'Runtime action'}),
  error => error.headlessCode === 'ELEMENT_NOT_FOUND',
);
fileInput.disabled = true;
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'NOT_EDITABLE',
);
fileInput.disabled = false;
fileInput.style.display = 'none';
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
fileInput.style.display = '';
fileInput.style.visibility = 'hidden';
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
fileInput.style.visibility = '';
fileInput.style.opacity = '0';
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
fileInput.style.opacity = '';
uploadControls.style.opacity = '0';
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
uploadControls.style.opacity = '';
fileInput.getBoundingClientRect = () => ({
  x: -220, y: 140, top: 140, left: -220, right: -20, bottom: 180, width: 200, height: 40,
});
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
fileInput.getBoundingClientRect = () => ({
  x: 20, y: 140, top: 140, left: 20, right: 20, bottom: 140, width: 0, height: 0,
});
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
fileInput.getBoundingClientRect = () => ({
  x: 20, y: 140, top: 140, left: 20, right: 220, bottom: 180, width: 200, height: 40,
});
window.document.elementFromPoint = () => uploadControls.querySelector('button');
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_VISIBLE',
);
window.document.elementFromPoint = () => fileInput;
fileInput.remove();
assert.throws(
  () => agent.fileInput({target: fileItem.ref}),
  error => error.headlessCode === 'ELEMENT_NOT_FOUND' && /detached/.test(error.message),
);

console.log(JSON.stringify({
  selectedRegion: targetRegion.ref,
  full: full.contextStats,
  summary: summary.contextStats,
  outline: outline.contextStats,
  scopedText: scopedText.contextStats,
  scopedActions: scopedActions.contextStats,
  budgetedText: budgetedText.contextStats,
}));
