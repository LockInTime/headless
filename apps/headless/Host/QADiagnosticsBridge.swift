import HeadlessProtocol
import Foundation
import WebKit

let webKitQAScript = #"""
(() => {
  if (globalThis.__headlessQAInstalled) return;
  Object.defineProperty(globalThis, '__headlessQAInstalled', {value: true});
  const post = payload => {
    try { webkit.messageHandlers.headlessQA.postMessage(payload); } catch (_) {}
  };
  const text = value => {
    try {
      if (typeof value === 'string') return value;
      if (value instanceof Error) return value.stack || value.message;
      return JSON.stringify(value) || String(value);
    } catch (_) { return String(value); }
  };
  let requestNumber = 0;
  const nextRequestId = prefix => `${prefix}-${++requestNumber}`;
  const headers = value => {
    try {
      return Object.fromEntries(new Headers(value || {}).entries());
    } catch (_) { return {}; }
  };
  const responseHeaders = response => {
    try { return Object.fromEntries(response.headers.entries()); } catch (_) { return {}; }
  };
  const xhrHeaders = value => Object.fromEntries(String(value || '').split(/\r?\n/)
    .filter(Boolean).map(line => { const index = line.indexOf(':'); return index < 0 ? null : [line.slice(0, index).trim(), line.slice(index + 1).trim()]; })
    .filter(Boolean));
  for (const level of ['log', 'info', 'debug', 'warn', 'error', 'assert']) {
    const original = console[level]?.bind(console);
    if (!original) continue;
    console[level] = (...args) => {
      post({kind: 'console', level, message: args.slice(0, 20).map(text).join(' ')});
      return original(...args);
    };
  }
  addEventListener('error', event => {
    const target = event.target;
    if (target && target !== globalThis) {
      post({kind: 'request-failed', message: 'Resource failed to load', url: target.src || target.href || ''});
    } else {
      post({kind: 'page-error', message: event.message || 'JavaScript error', url: event.filename || location.href});
    }
  }, true);
  addEventListener('unhandledrejection', event => {
    post({kind: 'unhandled-rejection', message: text(event.reason), url: location.href});
  });
  const nativeFetch = globalThis.fetch?.bind(globalThis);
  if (nativeFetch) globalThis.fetch = async (...args) => {
    const request = args[0];
    const url = typeof request === 'string' ? request : request?.url || String(request);
    const method = args[1]?.method || request?.method || 'GET';
    const requestId = nextRequestId('fetch');
    const requestHeaders = headers(args[1]?.headers || request?.headers);
    try {
      const response = await nativeFetch(...args);
      post({kind: 'response', requestId, url: response.url || url, method, status: response.status,
        requestHeaders, responseHeaders: responseHeaders(response)});
      return response;
    } catch (error) {
      post({kind: 'request-failed', requestId, url, method, message: text(error), requestHeaders});
      throw error;
    }
  };
  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__headlessRequest = {id: nextRequestId('xhr'), method: String(method), url: String(url), headers: {}};
    return nativeOpen.call(this, method, url, ...rest);
  };
  const nativeSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    if (this.__headlessRequest) this.__headlessRequest.headers[String(name)] = String(value);
    return nativeSetRequestHeader.call(this, name, value);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    this.addEventListener('loadend', () => post({
      kind: this.status ? 'response' : 'request-failed',
      requestId: this.__headlessRequest?.id || nextRequestId('xhr'),
      method: this.__headlessRequest?.method || 'GET',
      url: this.responseURL || this.__headlessRequest?.url || '',
      status: this.status,
      message: this.status ? '' : 'XHR failed',
      requestHeaders: this.__headlessRequest?.headers || {},
      responseHeaders: xhrHeaders(this.getAllResponseHeaders())
    }), {once: true});
    return nativeSend.apply(this, args);
  };
})();
"""#

final class WebKitQABridge: NSObject, WKScriptMessageHandler {
    let store = QADiagnosticStore()
    private let lock = NSLock()
    private var acceptedEvents = 0
    private var didRejectEvents = false
    private let maximumEventsPerDocument = 500

    func beginDocument() {
        lock.lock()
        acceptedEvents = 0
        didRejectEvents = false
        lock.unlock()
    }

    func clear() -> JSONValue {
        beginDocument()
        return store.clear()
    }

    private func acceptEvent() -> Bool {
        lock.lock()
        if acceptedEvents < maximumEventsPerDocument {
            acceptedEvents += 1
            lock.unlock()
            return true
        }
        let firstRejection = !didRejectEvents
        didRejectEvents = true
        lock.unlock()
        if firstRejection { store.markTruncated() }
        return false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "headlessQA", let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              ["console", "page-error", "unhandled-rejection", "request-failed", "response"].contains(kind),
              acceptEvent() else {
            return
        }
        store.append(
            kind: kind,
            level: body["level"] as? String,
            message: body["message"] as? String,
            url: body["url"] as? String,
            method: body["method"] as? String,
            status: (body["status"] as? NSNumber)?.doubleValue,
            requestID: body["requestId"] as? String,
            requestHeaders: body["requestHeaders"] as? [String: String],
            responseHeaders: body["responseHeaders"] as? [String: String],
            source: "webkit-page-bridge"
        )
    }
}
