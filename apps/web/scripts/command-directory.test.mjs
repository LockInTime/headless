import assert from "node:assert/strict";
import * as nodeModule from "node:module";
import test from "node:test";
import { JSDOM } from "jsdom";
import * as componentTestLoader from "./component-test-loader.mjs";
import { loadProductDocsContent } from "../lib/repository-content.mjs";

if (typeof nodeModule.registerHooks === "function") {
  nodeModule.registerHooks(componentTestLoader);
} else {
  nodeModule.register("./component-test-loader.mjs", import.meta.url);
}

const { groups } = loadProductDocsContent().commands;

async function renderDirectory() {
  const dom = new JSDOM('<div id="root"></div>', {
    pretendToBeVisual: true,
    url: "https://headless.test/docs/commands",
  });

  const previousGlobals = new Map();
  for (const name of [
    "document",
    "Event",
    "HTMLElement",
    "HTMLInputElement",
    "InputEvent",
    "KeyboardEvent",
    "Node",
    "navigator",
    "window",
  ]) {
    previousGlobals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, {
      configurable: true,
      value: dom.window[name],
      writable: true,
    });
  }
  previousGlobals.set(
    "IS_REACT_ACT_ENVIRONMENT",
    Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT"),
  );
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    configurable: true,
    value: true,
    writable: true,
  });

  const [{ act, createElement }, { createRoot }, { CommandDirectory }] =
    await Promise.all([
      import("react"),
      import("react-dom/client"),
      import("@/components/command-directory"),
    ]);
  const container = dom.window.document.querySelector("#root");
  const root = createRoot(container);
  await act(() => root.render(createElement(CommandDirectory, { groups })));

  return {
    act,
    document: dom.window.document,
    input: dom.window.document.querySelector("input[type=search]"),
    async cleanup() {
      await act(() => root.unmount());
      dom.window.close();
      for (const [name, descriptor] of previousGlobals) {
        if (descriptor === undefined) delete globalThis[name];
        else Object.defineProperty(globalThis, name, descriptor);
      }
    },
  };
}

async function typeWithKeyboard(view, value) {
  const valueSetter = Object.getOwnPropertyDescriptor(
    view.input.ownerDocument.defaultView.HTMLInputElement.prototype,
    "value",
  ).set;

  view.input.focus();
  await view.act(() => {
    for (let index = 0; index < value.length; index += 1) {
      const key = value[index];
      view.input.dispatchEvent(
        new KeyboardEvent("keydown", { bubbles: true, key }),
      );
      valueSetter.call(view.input, value.slice(0, index + 1));
      view.input.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          data: key,
          inputType: "insertText",
        }),
      );
      view.input.dispatchEvent(
        new KeyboardEvent("keyup", { bubbles: true, key }),
      );
    }
  });
}

async function replaceSearch(view, value) {
  const valueSetter = Object.getOwnPropertyDescriptor(
    view.input.ownerDocument.defaultView.HTMLInputElement.prototype,
    "value",
  ).set;
  await view.act(() => {
    valueSetter.call(view.input, value);
    view.input.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        data: value,
        inputType: "insertReplacementText",
      }),
    );
  });
}

function assertTocTargetsExist(document) {
  for (const link of document.querySelectorAll("nav[aria-label='On this page'] a")) {
    assert.ok(
      document.querySelector(link.hash),
      `table-of-contents target ${link.hash} must exist`,
    );
  }
}

test("filters real command groups from keyboard input and updates accessible status", async () => {
  const view = await renderDirectory();
  try {
    const label = view.document.querySelector("label[for=command-filter]");
    const status = view.document.querySelector("[role=status]");

    assert.equal(label.control, view.input);
    assert.equal(view.input.tabIndex, 0);
    assert.equal(status.getAttribute("aria-live"), "polite");
    assert.equal(status.textContent, `${groups.length} of ${groups.length} groups`);
    assertTocTargetsExist(view.document);

    await typeWithKeyboard(view, "auth login");

    assert.equal(view.document.activeElement, view.input);
    assert.equal(status.textContent, `1 of ${groups.length} groups`);
    assert.deepEqual(
      [...view.document.querySelectorAll("section h2")].map(
        (heading) => heading.textContent,
      ),
      ["Credential vault"],
    );
    assert.deepEqual(
      [...view.document.querySelectorAll("nav[aria-label='On this page'] a")].map(
        (link) => link.textContent,
      ),
      ["Credential vault"],
    );
    assertTocTargetsExist(view.document);
  } finally {
    await view.cleanup();
  }
});

test("handles normalized queries, no matches, and clearing without stale links", async () => {
  const view = await renderDirectory();
  try {
    const status = view.document.querySelector("[role=status]");

    await replaceSearch(view, "  SCREENSHOT  ");
    assert.equal(status.textContent, `1 of ${groups.length} groups`);
    assert.equal(
      view.document.querySelector("section")?.id,
      "capture-and-evidence",
    );
    assertTocTargetsExist(view.document);

    await replaceSearch(view, "not-a-command");
    assert.equal(status.textContent, "No commands match “not-a-command”.");
    assert.equal(view.document.querySelector("section"), null);
    assert.equal(view.document.querySelector("nav[aria-label='On this page']"), null);

    await replaceSearch(view, "");
    assert.equal(status.textContent, `${groups.length} of ${groups.length} groups`);
    assert.equal(view.document.querySelectorAll("section").length, groups.length);
    assertTocTargetsExist(view.document);
  } finally {
    await view.cleanup();
  }
});
