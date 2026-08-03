import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';

const runtimeSource = await readFile(
  new URL('../Sources/HeadlessProtocol/AgentRuntime.swift', import.meta.url),
  'utf8',
);
const runtimeMatch = runtimeSource.match(/#"""\n([\s\S]*?)\n"""#/);
assert(runtimeMatch, 'embedded agent runtime should be extractable');

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

window.eval(runtimeMatch[1]);
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

assert.throws(
  () => agent.snapshot(false, false, {context: 'text', within: '@r999999'}),
  /REGION_NOT_FOUND/,
);

console.log(JSON.stringify({
  full: full.contextStats,
  summary: summary.contextStats,
  outline: outline.contextStats,
  scopedText: scopedText.contextStats,
  scopedActions: scopedActions.contextStats,
}));
