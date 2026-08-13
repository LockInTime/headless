if (!globalThis.__headlessAgent) {
  globalThis.__headlessAgent = (() => {
    let nextRef = 1;
    let nextRegionRef = 1;
    const refs = new WeakMap();
    const regionRefs = new WeakMap();
    let current = new Map();
    let currentRegions = new Map();
    // Every reference ever handed out, so a failed lookup can say whether the
    // reference expired or was never issued at all.
    const issuedRefs = new Set();
    const issuedRegionRefs = new Set();
    const maximumTrackedRegions = 256;
    let lastMutation = performance.now();
    new MutationObserver(() => { lastMutation = performance.now(); })
      .observe(document, {subtree: true, childList: true, attributes: true, characterData: true});

    const normalize = value => String(value || '').replace(/\s+/g, ' ').trim();
    const clipped = (value, maximum) => normalize(value).slice(0, maximum);
    const clippedURL = value => String(value || '').slice(0, 512);
    const fail = (code, message) => {
      const error = new Error(message);
      error.headlessCode = code;
      throw error;
    };
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
    const actionHints = element => {
      const hints = [];
      const tag = element.tagName.toLowerCase();
      const elementRole = role(element);
      if (tag === 'a' && element.hasAttribute('href')) hints.push('click');
      if (tag === 'button' || elementRole === 'button') hints.push('click');
      if (tag === 'summary' || elementRole === 'tab' || elementRole === 'menuitem') hints.push('click');
      // Only advertise verbs implemented by the public Headless protocol.
      // Unsupported controls can still appear for context, but must not route
      // an agent toward nonexistent select/upload/slide commands.
      if (element instanceof HTMLTextAreaElement || element.isContentEditable) hints.push('fill');
      if (element instanceof HTMLInputElement) {
        const type = (element.getAttribute('type') || 'text').toLowerCase();
        if (type === 'file') return hints;
        else if (['checkbox', 'radio'].includes(type)) hints.push('click');
        else if (type === 'range') hints.push('fill');
        else if (['button', 'submit', 'reset', 'image'].includes(type)) hints.push('click');
        else hints.push('fill');
      }
      if (element.tabIndex >= 0 && hints.length === 0) hints.push('click');
      return Array.from(new Set(hints));
    };
    const isInteractive = element => actionHints(element).length > 0
      || ['link','button','textbox','checkbox','radio','combobox','slider'].includes(role(element));
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
      issuedRefs.add(ref);
      current.set(ref, element);
      return ref;
    };
    const elementSelector = 'a[href],button,input,textarea,select,summary,[role],[contenteditable="true"],[tabindex],img,video,audio,canvas,svg';
    const regionSelector = 'main,nav,aside,header,footer,section,article,form,dialog,[role="main"],[role="navigation"],[role="region"],[role="dialog"],[role="form"],[role="search"],[role="complementary"],h1,h2,h3,h4,h5,h6';
    const headingLevel = element => {
      const match = element?.tagName?.match(/^H([1-6])$/i);
      return match ? Number(match[1]) : null;
    };
    const scopeRoots = scope => {
      if (!scope || scope === document || scope === document.documentElement) return [document.documentElement];
      const level = headingLevel(scope);
      if (!level) return [scope];
      const roots = [scope];
      for (let sibling = scope.nextElementSibling; sibling; sibling = sibling.nextElementSibling) {
        const siblingLevel = headingLevel(sibling);
        if (siblingLevel && siblingLevel <= level) break;
        roots.push(sibling);
      }
      return roots;
    };
    const scopedQuery = (scope, selector) => {
      const result = [];
      const seen = new Set();
      for (const root of scopeRoots(scope)) {
        if (!root) continue;
        const add = element => {
          if (!seen.has(element)) { seen.add(element); result.push(element); }
        };
        if (root.matches?.(selector)) add(root);
        for (const element of root.querySelectorAll?.(selector) || []) add(element);
      }
      return result;
    };
    const candidates = (scope = document) => scopedQuery(scope, elementSelector).filter(visible);
    const regionCandidates = (scope = document) => scopedQuery(scope, regionSelector).filter(visible);
    const taskTerms = task => normalize(task).toLowerCase().split(/[^a-z0-9]+/).filter(term => term.length > 1).slice(0, 24);
    const rankingText = element => [
      role(element), name(element), element.getAttribute('placeholder'), element.getAttribute('aria-label'),
      element.getAttribute('title'), element.getAttribute('type'), element.getAttribute('name'),
      element.getAttribute('id'), element.href
    ].map(normalize).join(' ').toLowerCase();
    const rank = (element, terms, phrase) => {
      const rect = element.getBoundingClientRect();
      const text = rankingText(element);
      const hints = actionHints(element);
      let score = 0;
      const reasons = [];
      if (hints.length > 0) { score += 50; reasons.push('interactive'); }
      if (rect.top >= 0 && rect.top <= innerHeight && rect.left < innerWidth && rect.right > 0) {
        score += 12; reasons.push('in viewport');
      }
      if (phrase && text.includes(phrase)) { score += 35; reasons.push('task phrase match'); }
      for (const term of terms) {
        if (text.includes(term)) score += 14;
      }
      const termSet = new Set(terms);
      const elementRole = role(element);
      const inputType = element instanceof HTMLInputElement ? (element.getAttribute('type') || 'text').toLowerCase() : '';
      if (termSet.has('search')) {
        if (inputType === 'search' || text.includes('search')) { score += 60; reasons.push('search control'); }
        else if (hints.includes('fill')) score += 20;
      }
      if (termSet.has('login') || termSet.has('signin') || termSet.has('sign') || termSet.has('account')) {
        if (inputType === 'password' || text.includes('password')) { score += 50; reasons.push('credential field'); }
        if (hints.includes('fill')) score += 20;
        if (elementRole === 'button' || elementRole === 'link') score += 12;
      }
      if (termSet.has('click') && (hints.includes('click') || elementRole === 'button' || elementRole === 'link')) score += 20;
      score += Math.max(0, 8 - Math.floor(Math.max(0, rect.top) / 300));
      return {element, score, reasons: Array.from(new Set(reasons)).slice(0, 4)};
    };
    const rankedElements = (elements, task) => {
      const terms = taskTerms(task);
      if (terms.length === 0) return elements.map(element => ({element, score: 0, reasons: []}));
      const phrase = normalize(task).toLowerCase().slice(0, 128);
      return elements.map(element => rank(element, terms, phrase))
        .sort((left, right) => right.score - left.score);
    };
    const regionRole = element => {
      const explicit = element.getAttribute('role');
      if (explicit) return explicit.split(/\s+/)[0].toLowerCase().slice(0, 64);
      const tag = element.tagName.toLowerCase();
      return ({main: 'main', nav: 'navigation', aside: 'complementary', header: 'banner',
        footer: 'contentinfo', section: 'region', article: 'article', form: 'form', dialog: 'dialog'}[tag]
        || (/^h[1-6]$/.test(tag) ? 'heading' : tag));
    };
    const regionName = element => {
      const labelledBy = element.getAttribute('aria-labelledby');
      if (labelledBy) {
        const labelled = labelledBy.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
        if (normalize(labelled)) return clipped(labelled, 160);
      }
      if (normalize(element.getAttribute('aria-label'))) return clipped(element.getAttribute('aria-label'), 160);
      if (headingLevel(element)) return clipped(element.innerText || element.textContent, 160);
      const heading = element.querySelector('h1,h2,h3,h4,h5,h6');
      if (heading && normalize(heading.innerText || heading.textContent)) {
        return clipped(heading.innerText || heading.textContent, 160);
      }
      return clipped(element.getAttribute('title') || element.getAttribute('id') || regionRole(element), 160);
    };
    const regionRefFor = element => {
      let ref = regionRefs.get(element);
      if (!ref) { ref = `@r${nextRegionRef++}`; regionRefs.set(element, ref); }
      issuedRegionRefs.add(ref);
      currentRegions.set(ref, element);
      // Region references stay resolvable across inspections so a scoped
      // `--within @rN` workflow keeps working, but this map holds elements
      // strongly. Drop the oldest so a long-lived page cannot grow it without
      // bound, and never drop the reference just issued.
      while (currentRegions.size > maximumTrackedRegions) {
        const oldest = currentRegions.keys().next().value;
        if (oldest === undefined || oldest === ref) break;
        currentRegions.delete(oldest);
      }
      return ref;
    };
    const resolveRegion = reference => {
      if (!reference) return document;
      const element = currentRegions.get(reference);
      if (!element) {
        fail('REGION_NOT_FOUND', issuedRegionRefs.has(reference)
          ? `REGION_NOT_FOUND:${reference} (expired: inspect again to refresh region references)`
          : `REGION_NOT_FOUND:${reference} (unknown: no inspection has issued this reference)`);
      }
      if (!element.isConnected || !visible(element)) {
        currentRegions.delete(reference);
        fail('REGION_NOT_FOUND', `REGION_NOT_FOUND:${reference} (detached: the region is no longer visible on this page)`);
      }
      return element;
    };
    const regionDepth = (element, scope) => {
      if (headingLevel(element)) return Math.max(0, headingLevel(element) - 1);
      let depth = 0;
      for (let parent = element.parentElement; parent && parent !== scope && parent !== document.body; parent = parent.parentElement) {
        if (parent.matches?.(regionSelector) && !headingLevel(parent)) depth += 1;
      }
      return depth;
    };
    const rankRegion = (element, task) => {
      const terms = taskTerms(task);
      const phrase = normalize(task).toLowerCase().slice(0, 128);
      const sample = normalize(`${regionRole(element)} ${regionName(element)} ${element.innerText || ''}`).toLowerCase().slice(0, 2000);
      let score = 0;
      const reasons = [];
      if (phrase && sample.includes(phrase)) { score += 40; reasons.push('task phrase match'); }
      for (const term of terms) if (sample.includes(term)) score += 14;
      const rect = element.getBoundingClientRect();
      if (rect.top >= 0 && rect.top <= innerHeight) { score += 10; reasons.push('in viewport'); }
      if (regionRole(element) === 'main') score += 4;
      return {element, score, reasons: Array.from(new Set(reasons)).slice(0, 4)};
    };
    const describeRegion = (entry, scope, includeRelevance) => {
      const element = entry.element || entry;
      const rect = element.getBoundingClientRect();
      const actions = candidates(element).filter(isInteractive).length;
      const text = normalize(scopeRoots(element).map(root => root.innerText || '').join(' '));
      const item = {
        ref: regionRefFor(element), role: regionRole(element), name: regionName(element),
        depth: regionDepth(element, scope), actions, textChars: text.length,
        bounds: {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)}
      };
      const level = headingLevel(element);
      if (level) item.headingLevel = level;
      if (includeRelevance) item.relevance = {score: Math.round(entry.score), reasons: entry.reasons};
      return item;
    };
    const textCandidates = scope => {
      const selector = 'h1,h2,h3,h4,h5,h6,p,li,dt,dd,blockquote,pre,code,caption,th,td';
      const seen = new Set();
      return scopedQuery(scope, selector).filter(visible).flatMap(element => {
        const text = clipped(element.innerText || element.textContent, 600);
        const key = text.toLowerCase();
        if (!text || seen.has(key)) return [];
        seen.add(key);
        return [{element, text}];
      });
    };
    const rankText = (entry, task) => {
      const terms = taskTerms(task);
      const phrase = normalize(task).toLowerCase().slice(0, 128);
      const value = entry.text.toLowerCase();
      let score = 0;
      const reasons = [];
      if (phrase && value.includes(phrase)) { score += 40; reasons.push('task phrase match'); }
      for (const term of terms) if (value.includes(term)) score += 16;
      if (headingLevel(entry.element)) { score += 8; reasons.push('heading'); }
      const rect = entry.element.getBoundingClientRect();
      if (rect.top >= 0 && rect.top <= innerHeight) { score += 6; reasons.push('in viewport'); }
      return {...entry, score, reasons: Array.from(new Set(reasons)).slice(0, 4)};
    };
    const describeText = (entry, includeRelevance) => {
      const item = {ref: refFor(entry.element), role: role(entry.element), text: entry.text};
      if (includeRelevance) item.relevance = {score: Math.round(entry.score), reasons: entry.reasons};
      return item;
    };
    const describe = (entry, includeRelevance) => {
      const element = entry.element || entry;
      const rect = element.getBoundingClientRect();
      const item = {
        ref: refFor(element), role: role(element), name: name(element),
        actions: actionHints(element),
        disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
        bounds: {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)}
      };
      if (element instanceof HTMLInputElement) item.inputType = (element.getAttribute('type') || 'text').toLowerCase().slice(0, 32);
      if (includeRelevance) item.relevance = {score: Math.round(entry.score), reasons: entry.reasons};
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
    const encodedBytes = value => new TextEncoder().encode(JSON.stringify(value)).length;
    const pruneToBudget = (result, available, requestedBudget) => {
      const budget = requestedBudget || null;
      const arrays = ['regions', 'elements', 'snippets'].filter(key => Array.isArray(result[key]));
      const refresh = () => {
        const omitted = {};
        for (const key of arrays) omitted[key] = Math.max(0, (available[key] || 0) - result[key].length);
        result.omitted = omitted;
        result.truncated = Object.values(omitted).some(value => value > 0);
        result.contextStats = {
          encodedBytes: 0,
          estimatedTokens: 0,
          budget,
          budgetApplied: Boolean(budget)
        };
        const baseBytes = encodedBytes(result);
        let bytes = baseBytes;
        let estimatedTokens = Math.ceil(bytes / 4);
        while (true) {
          const measured = baseBytes + String(bytes).length - 1 + String(estimatedTokens).length - 1;
          const measuredTokens = Math.ceil(measured / 4);
          if (measured === bytes && measuredTokens === estimatedTokens) break;
          bytes = measured;
          estimatedTokens = measuredTokens;
        }
        result.contextStats.encodedBytes = bytes;
        result.contextStats.estimatedTokens = estimatedTokens;
        return bytes;
      };
      let currentBytes = refresh();
      if (!budget) return result;

      const maximumBytes = budget * 4;
      if (currentBytes > maximumBytes) {
        const candidates = arrays.flatMap(key => result[key].map((value, index) => ({
          key, index, bytes: encodedBytes(value) + (result[key].length > 1 ? 1 : 0)
        }))).sort((left, right) => right.bytes - left.bytes);
        const removed = new Map(arrays.map(key => [key, new Set()]));
        // Reserve a small allowance for omitted-count digit growth. Each item
        // is encoded once; removal then preserves the order of retained items.
        const targetBytes = Math.max(0, maximumBytes - 32);
        for (const candidate of candidates) {
          if (currentBytes <= targetBytes) break;
          removed.get(candidate.key).add(candidate.index);
          currentBytes -= candidate.bytes;
        }
        for (const key of arrays) {
          const indexes = removed.get(key);
          if (indexes.size > 0) result[key] = result[key].filter((_, index) => !indexes.has(index));
        }
        currentBytes = refresh();
      }

      if (currentBytes > maximumBytes && typeof result.text === 'string' && result.text.length > 0) {
        const textBytes = Math.max(0, encodedBytes(result.text) - 2);
        const targetTextBytes = Math.max(0, textBytes - (currentBytes - maximumBytes) - 32);
        let lower = 0;
        let upper = result.text.length;
        while (lower < upper) {
          const middle = Math.ceil((lower + upper) / 2);
          const prefixBytes = Math.max(0, encodedBytes(result.text.slice(0, middle)) - 2);
          if (prefixBytes <= targetTextBytes) lower = middle;
          else upper = middle - 1;
        }
        result.text = result.text.slice(0, lower);
        currentBytes = refresh();
      }

      // Metadata is deliberately bounded, but keep the budget fail-closed if
      // its final digit widths ever outgrow the allowance above.
      if (currentBytes > maximumBytes) {
        for (const key of arrays) result[key] = [];
        if (typeof result.text === 'string') result.text = '';
        refresh();
      }
      return result;
    };
    const snapshot = (interactiveOnly, includeText, options = {}) => {
      current = new Map();
      const allowedContexts = new Set(['summary', 'outline', 'text', 'actions', 'full']);
      const requestedContext = allowedContexts.has(options.context) ? options.context : 'full';
      const contextMode = interactiveOnly && requestedContext === 'full' ? 'actions' : requestedContext;
      const task = clipped(options.task, 512);
      const scope = resolveRegion(clipped(options.within, 16));
      const defaultLimits = {summary: 12, outline: 40, text: 12, actions: 20, full: 250};
      const defaultBudgets = {summary: 1200, outline: 1600, text: 1500, actions: 1200, full: null};
      const limit = Math.min(250, Math.max(1, Number(options.limit || defaultLimits[contextMode])));
      const budget = options.budget ? Math.min(16000, Math.max(256, Number(options.budget))) : defaultBudgets[contextMode];
      const depth = Math.min(8, Math.max(0, Number(options.depth ?? 3)));
      const root = document.documentElement;
      const result = {
        url: String(location.href).slice(0, 8192), title: String(document.title).slice(0, 512),
        contextMode,
        viewport: {width: innerWidth, height: innerHeight, scrollX, scrollY,
          contentWidth: root ? root.scrollWidth : 0, contentHeight: root ? root.scrollHeight : 0},
        untrustedContent: true
      };
      if (task) result.task = task;
      if (options.within) result.within = options.within;
      const available = {};
      if (contextMode === 'actions' || contextMode === 'full' || contextMode === 'summary') {
        let elements = candidates(scope);
        if (contextMode !== 'full') elements = elements.filter(isInteractive);
        const ranked = rankedElements(elements, task);
        const maximum = contextMode === 'summary' ? Math.min(limit, 8) : limit;
        result.elements = ranked.slice(0, maximum).map(entry => describe(entry, Boolean(task)));
        available.elements = ranked.length;
      }
      if (contextMode === 'outline' || contextMode === 'summary') {
        const ranked = regionCandidates(scope).map(element => rankRegion(element, task))
          .filter(entry => regionDepth(entry.element, scope) <= depth)
          .sort((left, right) => task ? right.score - left.score : left.element.getBoundingClientRect().top - right.element.getBoundingClientRect().top);
        result.regions = ranked.slice(0, limit).map(entry => describeRegion(entry, scope, Boolean(task)));
        available.regions = ranked.length;
      }
      if (contextMode === 'text') {
        const ranked = textCandidates(scope).map(entry => rankText(entry, task))
          .sort((left, right) => task ? right.score - left.score : left.element.getBoundingClientRect().top - right.element.getBoundingClientRect().top);
        result.snippets = ranked.slice(0, limit).map(entry => describeText(entry, Boolean(task)));
        available.snippets = ranked.length;
      }
      if (includeText) {
        result.text = normalize(scopeRoots(scope).map(root => root.innerText || root.textContent || '').join(' ')).slice(0, 30000);
      }
      return pruneToBudget(result, available, budget);
    };
    const resolve = target => {
      const element = current.get(target);
      // Element references describe the most recent inspection only. Saying so
      // is the difference between an agent re-inspecting and an agent retrying
      // the same dead reference.
      if (!element) {
        fail('ELEMENT_NOT_FOUND', issuedRefs.has(target)
          ? `ELEMENT_NOT_FOUND:${target} (expired: element references come from the most recent inspection — inspect again to refresh)`
          : `ELEMENT_NOT_FOUND:${target} (unknown: no inspection has issued this reference)`);
      }
      if (!element.isConnected) {
        current.delete(target);
        fail('ELEMENT_NOT_FOUND', `ELEMENT_NOT_FOUND:${target} (detached: the element is no longer in the page)`);
      }
      return element;
    };
    const find = (wantedRole, wantedName) => {
      const normalizedRole = normalize(wantedRole).toLowerCase();
      const normalizedName = normalize(wantedName).toLowerCase();
      const matches = candidates().filter(element =>
        (!normalizedRole || role(element) === normalizedRole) &&
        (!normalizedName || name(element).toLowerCase() === normalizedName)
      );
      if (matches.length === 0) fail('ELEMENT_NOT_FOUND', `ELEMENT_NOT_FOUND:${wantedRole || ''}/${wantedName || ''}`);
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
    const requireSafeClickTarget = element => {
      if (element instanceof HTMLAnchorElement && element.href) {
        const destination = new URL(element.href, document.baseURI);
        const scheme = destination.protocol.toLowerCase();
        if (!['http:', 'https:'].includes(scheme) || destination.username || destination.password) {
          fail('UNSAFE_NAVIGATION', `UNSAFE_NAVIGATION:${scheme}`);
        }
        const safety = resourceSafety(destination.href);
        if (safety.level === 'blocked') fail('UNSAFE_RESOURCE_TYPE', `UNSAFE_RESOURCE_TYPE:${safety.extension}`);
      }
    };
    const click = args => {
      const element = target(args);
      requireSafeClickTarget(element);
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      element.focus({preventScroll: true});
      element.click();
      return {clicked: refFor(element), role: role(element), name: name(element)};
    };
    // Chromium uses this isolated-world resolver only to select and validate a
    // target. The host performs the action through CDP's trusted input domain.
    // Page-derived coordinates remain bounded to the visible viewport.
    const inputTarget = (args, action) => {
      const element = target(args);
      if (action === 'click') requireSafeClickTarget(element);
      if (action === 'fill') {
        const editable = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element.isContentEditable;
        if (!editable || element.disabled || element.readOnly) throw new Error('NOT_EDITABLE');
      }
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      element.focus({preventScroll: true});
      const rect = element.getBoundingClientRect();
      const left = Math.max(0, rect.left);
      const right = Math.min(innerWidth, rect.right);
      const top = Math.max(0, rect.top);
      const bottom = Math.min(innerHeight, rect.bottom);
      if (right <= left || bottom <= top) throw new Error('ELEMENT_NOT_VISIBLE');
      const x = left + (right - left) / 2;
      const y = top + (bottom - top) / 2;
      const hit = document.elementFromPoint(x, y);
      if (!hit || (hit !== element && !element.contains(hit))) throw new Error('ELEMENT_OBSCURED');
      return {ref: refFor(element), role: role(element), name: name(element), x, y};
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
    const blockingAnimationCount = () => document.getAnimations().filter(animation => {
      if (animation.playState !== 'running') return false;
      const timing = animation.effect?.getComputedTiming?.();
      // Perpetual ambient animation must not prevent a loaded page from ever
      // settling. Finite transitions still block until they finish.
      return Number.isFinite(timing?.endTime);
    }).length;
    const state = () => {
      const root = document.documentElement;
      return {
        url: String(location.href).slice(0, 8192), title: String(document.title).slice(0, 512),
        // A page can be between documents immediately after navigation. Report
        // it as loading so the host retries instead of dereferencing a missing
        // root element and turning a normal navigation race into a failure.
        readyState: root ? document.readyState : 'loading',
        text: normalize(document.body?.innerText).slice(0, 30000),
        runningAnimations: blockingAnimationCount(),
        mutationQuietMs: Math.round(performance.now() - lastMutation),
        scrollY, contentHeight: root ? root.scrollHeight : 0
      };
    };
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
    const capturePoint = (y, label, kind) => ({
      y: Math.round(Math.max(0, y)),
      label: clipped(label || kind || 'viewport', 80),
      kind: clipped(kind || 'viewport', 32)
    });
    const dedupePoints = points => {
      const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      const result = [];
      let truncated = false;
      for (const point of points) {
        const normalizedY = Math.round(Math.min(maximum, Math.max(0, point.y || 0)));
        if (result.some(existing => Math.abs(existing.y - normalizedY) <= 96)) continue;
        if (result.length >= 80) { truncated = true; break; }
        result.push({...point, y: normalizedY});
      }
      if (result.length === 0) result.push(capturePoint(0, 'viewport', 'viewport'));
      return {points: result, truncated, totalPoints: truncated ? points.length : result.length};
    };
    const screenshotPlan = args => {
      const mode = args.mode === 'section' ? 'section' : 'viewport';
      const root = document.documentElement;
      const maximum = Math.max(0, root.scrollHeight - innerHeight);
      const initialY = Math.round(scrollY);
      if (mode === 'viewport') {
        const step = Math.max(1, innerHeight);
        const totalPoints = maximum === 0 ? 1 : Math.ceil(maximum / step) + 1;
        const truncated = totalPoints > 80;
        const points = [];
        const leadingCount = truncated ? 79 : Math.max(0, totalPoints - 1);
        for (let index = 0; index < leadingCount; index += 1) {
          points.push(capturePoint(index * step, `viewport ${index + 1}`, 'viewport'));
        }
        if (points.length === 0 || points[points.length - 1].y !== maximum) {
          points.push(capturePoint(maximum, `viewport ${totalPoints}`, 'viewport'));
        }
        return {mode, initialY, viewportHeight: innerHeight, contentHeight: root.scrollHeight,
          points, truncated, totalPoints};
      }
      const candidates = Array.from(document.querySelectorAll('main h1,main h2,main h3,h1,h2,h3,section,[role="region"]'));
      const points = candidates.filter(visible).map(element => {
        const rect = element.getBoundingClientRect();
        const label = name(element) || element.getAttribute('id') || element.tagName.toLowerCase();
        const kind = /^h[1-6]$/i.test(element.tagName) ? element.tagName.toLowerCase() : (role(element) || element.tagName.toLowerCase());
        return capturePoint(rect.top + scrollY - 16, label, kind);
      }).sort((left, right) => left.y - right.y);
      const deduped = dedupePoints(points);
      return {mode, initialY, viewportHeight: innerHeight, contentHeight: root.scrollHeight,
        points: deduped.points, truncated: deduped.truncated, totalPoints: deduped.totalPoints};
    };
    const scrollToCapturePoint = async args => {
      const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      const requestedY = Math.min(maximum, Math.max(0, Number(args.y || 0)));
      scrollTo({top: requestedY, behavior: 'instant'});
      await sleep(180);
      return {scrollY: Math.round(scrollY), requestedY: Math.round(requestedY)};
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
      const finiteNumber = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
      const all = document.getAnimations().slice(0, 100).map(animation => {
        const effect = animation.effect;
        const timing = effect?.getComputedTiming?.() || {};
        const target = effect?.target;
        return {
          target: target instanceof Element ? {ref: refFor(target), role: role(target), name: name(target)} : null,
          playState: animation.playState,
          currentTime: finiteNumber(animation.currentTime) === null ? null : Math.round(animation.currentTime),
          playbackRate: finiteNumber(animation.playbackRate),
          durationMs: finiteNumber(timing.duration),
          delayMs: finiteNumber(timing.delay),
          progress: finiteNumber(timing.progress) === null ? null : Number(timing.progress.toFixed(4)),
          iterations: finiteNumber(timing.iterations)
        };
      });
      return {count: document.getAnimations().length, animations: all, truncated: document.getAnimations().length > all.length};
    };
    return {
      snapshot, click, fill, press, inputTarget, scroll, state, tour, screenshotPlan,
      scrollToCapturePoint, rectangle, styles, storage,
      performance: performanceSummary, animations
    };
  })();
}
