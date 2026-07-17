public let agentRuntimeJavaScript = #"""
if (!globalThis.__headlessAgent) {
  globalThis.__headlessAgent = (() => {
    let nextRef = 1;
    const refs = new WeakMap();
    let current = new Map();
    let lastMutation = performance.now();
    new MutationObserver(() => { lastMutation = performance.now(); })
      .observe(document, {subtree: true, childList: true, attributes: true, characterData: true});

    const normalize = value => String(value || '').replace(/\s+/g, ' ').trim();
    const clipped = (value, maximum) => normalize(value).slice(0, maximum);
    const clippedURL = value => String(value || '').slice(0, 512);
    const blockedResourceExtensions = new Set([
      'apk','app','bat','cmd','com','deb','dll','dmg','dylib','exe','img','iso','jar',
      'msi','msp','pif','pkg','ps1','psm1','scr','sh','so','vbe','vbs','wsf','zsh'
    ]);
    const cautionResourceExtensions = new Set(['7z','bz2','gz','rar','rpm','tar','tgz','xz','zip']);
    const defaultStyleProperties = [
      'display','visibility','opacity','position','z-index','overflow','box-sizing',
      'width','height','min-width','min-height','max-width','max-height',
      'margin-top','margin-right','margin-bottom','margin-left',
      'padding-top','padding-right','padding-bottom','padding-left',
      'color','background-color','border-top-width','border-top-style','border-top-color',
      'font-family','font-size','font-weight','line-height','text-align',
      'flex-direction','justify-content','align-items','gap','transform'
    ];
    const resourceSafety = value => {
      try {
        const parsed = new URL(value, document.baseURI);
        const extension = parsed.pathname.split('.').pop().toLowerCase();
        if (blockedResourceExtensions.has(extension)) return {level: 'blocked', extension};
        if (cautionResourceExtensions.has(extension)) return {level: 'caution', extension};
      } catch (_) { return {level: 'unknown'}; }
      return {level: 'allowed'};
    };
    const visible = element => {
      if (!(element instanceof Element) || !element.isConnected) return false;
      const style = getComputedStyle(element);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const role = element => {
      const explicit = element.getAttribute('role');
      if (explicit) return explicit.split(/\s+/)[0].toLowerCase().slice(0, 64);
      const tag = element.tagName.toLowerCase();
      if (tag === 'a' && element.hasAttribute('href')) return 'link';
      if (tag === 'button') return 'button';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'select') return 'combobox';
      if (tag === 'img') return 'img';
      if (/^h[1-6]$/.test(tag)) return 'heading';
      if (tag === 'input') {
        const type = (element.getAttribute('type') || 'text').toLowerCase();
        if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        return 'textbox';
      }
      return tag;
    };
    const name = element => {
      const labelledBy = element.getAttribute('aria-labelledby');
      if (labelledBy) {
        const labelled = labelledBy.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
        if (normalize(labelled)) return clipped(labelled, 256);
      }
      if (normalize(element.getAttribute('aria-label'))) return clipped(element.getAttribute('aria-label'), 256);
      if (element.labels?.length) return clipped(Array.from(element.labels).map(label => label.innerText).join(' '), 256);
      if (normalize(element.getAttribute('alt'))) return clipped(element.getAttribute('alt'), 256);
      if (normalize(element.getAttribute('placeholder'))) return clipped(element.getAttribute('placeholder'), 256);
      if (normalize(element.getAttribute('title'))) return clipped(element.getAttribute('title'), 256);
      if (normalize(element.value) && ['button', 'submit', 'reset'].includes((element.type || '').toLowerCase())) {
        return clipped(element.value, 256);
      }
      return clipped(element.innerText || element.textContent, 256);
    };
    const refFor = element => {
      let ref = refs.get(element);
      if (!ref) { ref = `@e${nextRef++}`; refs.set(element, ref); }
      current.set(ref, element);
      return ref;
    };
    const candidates = () => Array.from(document.querySelectorAll(
      'a[href],button,input,textarea,select,summary,[role],[contenteditable="true"],[tabindex],img,video,audio,canvas,svg'
    )).filter(visible);
    const describe = element => {
      const rect = element.getBoundingClientRect();
      const item = {
        ref: refFor(element), role: role(element), name: name(element),
        disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
        bounds: {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)}
      };
      if ('value' in element && typeof element.value === 'string' && element.type !== 'password') item.value = element.value.slice(0, 500);
      if (element.tagName === 'A') {
        item.href = clippedURL(element.href);
        item.resourceSafety = resourceSafety(element.href);
      }
      if (element.tagName === 'IMG') {
        item.src = clippedURL(element.currentSrc || element.src);
        item.media = {
          kind: 'image', loaded: Boolean(element.complete && element.naturalWidth > 0),
          width: element.naturalWidth || null, height: element.naturalHeight || null
        };
        item.resourceSafety = resourceSafety(element.currentSrc || element.src);
      }
      if (element instanceof HTMLMediaElement) {
        item.src = clippedURL(element.currentSrc || element.src || element.querySelector('source')?.src);
        item.media = {
          kind: element instanceof HTMLVideoElement ? 'video' : 'audio',
          loaded: element.readyState >= HTMLMediaElement.HAVE_METADATA,
          readyState: element.readyState,
          paused: element.paused,
          muted: element.muted,
          currentTime: Number.isFinite(element.currentTime) ? element.currentTime : null,
          duration: Number.isFinite(element.duration) ? element.duration : null,
          width: element instanceof HTMLVideoElement ? element.videoWidth || null : null,
          height: element instanceof HTMLVideoElement ? element.videoHeight || null : null
        };
        item.resourceSafety = resourceSafety(element.currentSrc || element.src || element.querySelector('source')?.src);
        if (element instanceof HTMLVideoElement && element.poster) item.poster = clippedURL(element.poster);
      }
      return item;
    };
    const snapshot = (interactiveOnly, includeText) => {
      current = new Map();
      let elements = candidates();
      if (interactiveOnly) {
        elements = elements.filter(element => ['link','button','textbox','checkbox','radio','combobox','slider'].includes(role(element)) || element.tabIndex >= 0);
      }
      const limited = elements.slice(0, 250).map(describe);
      const result = {
        url: String(location.href).slice(0, 8192), title: String(document.title).slice(0, 512),
        viewport: {width: innerWidth, height: innerHeight, scrollX, scrollY,
          contentWidth: document.documentElement.scrollWidth, contentHeight: document.documentElement.scrollHeight},
        elements: limited, truncated: elements.length > limited.length
      };
      if (includeText) result.text = normalize(document.body?.innerText).slice(0, 30000);
      return result;
    };
    const resolve = target => {
      const element = current.get(target);
      if (!element || !element.isConnected) throw new Error(`ELEMENT_NOT_FOUND:${target}`);
      return element;
    };
    const find = (wantedRole, wantedName) => {
      const normalizedRole = normalize(wantedRole).toLowerCase();
      const normalizedName = normalize(wantedName).toLowerCase();
      const matches = candidates().filter(element =>
        (!normalizedRole || role(element) === normalizedRole) &&
        (!normalizedName || name(element).toLowerCase() === normalizedName)
      );
      if (matches.length === 0) throw new Error(`ELEMENT_NOT_FOUND:${wantedRole || ''}/${wantedName || ''}`);
      if (matches.length > 1) throw new Error(`ELEMENT_AMBIGUOUS:${matches.length}`);
      refFor(matches[0]);
      return matches[0];
    };
    const target = args => args.target ? resolve(args.target) : find(args.role, args.name);
    const rectangle = args => {
      const element = target(args);
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) throw new Error('ELEMENT_NOT_VISIBLE');
      return {
        viewport: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
        document: {x: rect.x + scrollX, y: rect.y + scrollY, width: rect.width, height: rect.height}
      };
    };
    const styles = args => {
      const element = target(args);
      const computed = getComputedStyle(element);
      const requested = Array.isArray(args.properties) && args.properties.length > 0
        ? args.properties : defaultStyleProperties;
      const values = {};
      for (const property of requested.slice(0, 64)) {
        const propertyName = String(property || '').slice(0, 128);
        if (propertyName) values[propertyName] = String(computed.getPropertyValue(propertyName) || '').slice(0, 2048);
      }
      const rect = element.getBoundingClientRect();
      return {
        ref: refFor(element), role: role(element), name: name(element),
        box: {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)},
        styles: values
      };
    };
    const storage = args => {
      const includeValues = Boolean(args.includeValues);
      const describe = (store, scope) => {
        const entries = [];
        for (let index = 0; index < store.length && index < 200; index++) {
          const key = String(store.key(index) || '').slice(0, 512);
          const value = String(store.getItem(key) || '');
          entries.push(includeValues
            ? {key, value: value.slice(0, 16384), bytes: value.length}
            : {key, bytes: value.length});
        }
        return {scope, count: store.length, entries, truncated: store.length > entries.length};
      };
      const scope = args.scope || 'all';
      const stores = [];
      try {
        if (scope === 'local' || scope === 'all') stores.push(describe(localStorage, 'local'));
        if (scope === 'session' || scope === 'all') stores.push(describe(sessionStorage, 'session'));
      } catch (error) {
        return {origin: String(location.origin), stores, error: String(error).slice(0, 512)};
      }
      return {origin: String(location.origin).slice(0, 2048), stores};
    };
    const click = args => {
      const element = target(args);
      if (element instanceof HTMLAnchorElement && element.href) {
        const destination = new URL(element.href, document.baseURI);
        const scheme = destination.protocol.toLowerCase();
        if (!['http:', 'https:'].includes(scheme) || destination.username || destination.password) {
          throw new Error(`UNSAFE_NAVIGATION:${scheme}`);
        }
        const safety = resourceSafety(destination.href);
        if (safety.level === 'blocked') throw new Error(`UNSAFE_RESOURCE_TYPE:${safety.extension}`);
      }
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      element.focus({preventScroll: true});
      element.click();
      return {clicked: refFor(element), role: role(element), name: name(element)};
    };
    const fill = args => {
      const element = target(args);
      if (!(element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element.isContentEditable)) {
        throw new Error('NOT_EDITABLE');
      }
      element.focus({preventScroll: false});
      if (element.isContentEditable) {
        element.textContent = args.value;
      } else {
        const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, args.value);
      }
      element.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: args.value}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
      return {filled: refFor(element), valueLength: String(args.value).length};
    };
    const press = key => {
      const element = document.activeElement || document.body;
      const options = {key, code: key, bubbles: true, cancelable: true};
      element.dispatchEvent(new KeyboardEvent('keydown', options));
      if (key === 'Enter') {
        const form = element.form || element.closest?.('form');
        if (form?.requestSubmit) form.requestSubmit();
        else if (element.tagName === 'BUTTON') element.click();
      } else if (key === ' ' && element.tagName === 'BUTTON') {
        element.click();
      }
      element.dispatchEvent(new KeyboardEvent('keyup', options));
      return {pressed: key};
    };
    const scroll = args => {
      const amount = Number(args.amount || Math.max(240, innerHeight * 0.8));
      if (args.direction === 'top') scrollTo({top: 0, behavior: 'smooth'});
      else if (args.direction === 'bottom') scrollTo({top: document.documentElement.scrollHeight, behavior: 'smooth'});
      else scrollBy({top: args.direction === 'up' ? -amount : amount, behavior: 'smooth'});
      return {direction: args.direction, amount};
    };
    const state = () => ({
      url: String(location.href).slice(0, 8192), title: String(document.title).slice(0, 512), readyState: document.readyState,
      text: normalize(document.body?.innerText).slice(0, 30000),
      runningAnimations: document.getAnimations().filter(animation => animation.playState === 'running').length,
      mutationQuietMs: Math.round(performance.now() - lastMutation),
      scrollY, contentHeight: document.documentElement.scrollHeight
    });
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const tour = async args => {
      const pace = Math.min(5000, Math.max(100, Number(args.pace || 800)));
      if (args.fullPage === false) {
        return {start: scrollY, end: scrollY, durationMs: 0};
      }
      const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      scrollTo({top: 0, behavior: 'instant'});
      await sleep(250);
      const desiredDuration = maximum / pace;
      const duration = Math.min(60, Math.max(0.5, desiredDuration));
      const steps = Math.max(1, Math.ceil(duration * 20));
      for (let index = 1; index <= steps; index++) {
        scrollTo({top: maximum * index / steps, behavior: 'instant'});
        await sleep(duration * 1000 / steps);
      }
      return {start: 0, end: maximum, durationMs: Math.round(duration * 1000)};
    };
    const performanceSummary = () => {
      const navigation = performance.getEntriesByType('navigation')[0];
      const paint = performance.getEntriesByType('paint');
      const resources = performance.getEntriesByType('resource');
      const byName = name => paint.find(entry => entry.name === name)?.startTime ?? null;
      let lcp = null;
      let cls = 0;
      try {
        for (const entry of performance.getEntriesByType('largest-contentful-paint')) lcp = Math.max(lcp || 0, entry.startTime);
        for (const entry of performance.getEntriesByType('layout-shift')) if (!entry.hadRecentInput) cls += entry.value || 0;
      } catch (_) {}
      const failedResources = resources.filter(item => item.transferSize === 0 && item.duration > 0).length;
      return {
        url: String(location.href).slice(0, 8192),
        timing: navigation ? {
          dnsMs: Math.max(0, navigation.domainLookupEnd - navigation.domainLookupStart),
          connectMs: Math.max(0, navigation.connectEnd - navigation.connectStart),
          ttfbMs: Math.max(0, navigation.responseStart - navigation.requestStart),
          domContentLoadedMs: navigation.domContentLoadedEventEnd,
          loadMs: navigation.loadEventEnd || null,
          transferBytes: navigation.transferSize, encodedBytes: navigation.encodedBodySize, decodedBytes: navigation.decodedBodySize
        } : null,
        webVitals: {fcpMs: byName('first-contentful-paint'), lcpMs: lcp, cls: Number(cls.toFixed(4))},
        resources: {count: resources.length, transferBytes: resources.reduce((sum, item) => sum + (item.transferSize || 0), 0), zeroTransferTimedEntries: failedResources},
        caveat: 'Values are browser timing data for the current document; cross-origin resources may be subject to timing privacy limits.'
      };
    };
    const animations = () => {
      const all = document.getAnimations().slice(0, 100).map(animation => {
        const effect = animation.effect;
        const timing = effect?.getComputedTiming?.() || {};
        const target = effect?.target;
        return {
          target: target instanceof Element ? {ref: refFor(target), role: role(target), name: name(target)} : null,
          playState: animation.playState, currentTime: typeof animation.currentTime === 'number' ? Math.round(animation.currentTime) : null,
          playbackRate: animation.playbackRate,
          durationMs: typeof timing.duration === 'number' ? timing.duration : null,
          delayMs: typeof timing.delay === 'number' ? timing.delay : null,
          progress: typeof timing.progress === 'number' ? Number(timing.progress.toFixed(4)) : null,
          iterations: typeof timing.iterations === 'number' ? timing.iterations : null
        };
      });
      return {count: document.getAnimations().length, animations: all, truncated: document.getAnimations().length > all.length};
    };
    return {snapshot, click, fill, press, scroll, state, tour, rectangle, styles, storage, performance: performanceSummary, animations};
  })();
}
"""#
