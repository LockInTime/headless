"use client";

import { useEffect, useRef, useState } from "react";
import { siClaude, siCursor, siPerplexity } from "simple-icons/icons";
import { cursorMcpConfig, pageMarkdown } from "@/components/docs-markdown";

const openaiBlossomPath = "M11.248 18.25q-.825 0-1.568-.314a4.3 4.3 0 0 1-1.32-.874 4 4 0 0 1-1.304.214 4 4 0 0 1-2.046-.544 4.27 4.27 0 0 1-1.518-1.485 4 4 0 0 1-.56-2.095q0-.48.131-1.04A4.4 4.4 0 0 1 2.04 10.71a4.07 4.07 0 0 1 .017-3.4 4.2 4.2 0 0 1 1.056-1.418 3.8 3.8 0 0 1 1.6-.842 3.9 3.9 0 0 1 .76-1.683q.593-.759 1.451-1.188a4.04 4.04 0 0 1 1.832-.429q.825 0 1.567.313.742.314 1.32.875a4 4 0 0 1 1.304-.215q1.106 0 2.046.545a4.14 4.14 0 0 1 1.501 1.485q.578.941.578 2.095 0 .48-.132 1.04.66.61 1.023 1.419.363.792.363 1.666 0 .892-.38 1.717a4.3 4.3 0 0 1-1.072 1.435 3.8 3.8 0 0 1-1.584.825 3.8 3.8 0 0 1-.775 1.683 4.06 4.06 0 0 1-1.436 1.188 4.04 4.04 0 0 1-1.832.429m-4.076-2.062q.825 0 1.435-.347l3.103-1.782a.36.36 0 0 0 .164-.313v-1.42L7.881 14.62a.67.67 0 0 1-.726 0l-3.118-1.798a.5.5 0 0 1-.017.115v.198q0 .841.396 1.551.413.693 1.139 1.089a3.2 3.2 0 0 0 1.617.412m.165-2.69a.4.4 0 0 0 .181.05q.083 0 .165-.05l1.238-.71-3.977-2.31a.7.7 0 0 1-.363-.643v-3.58q-.825.362-1.32 1.122a2.9 2.9 0 0 0-.495 1.65q0 .809.413 1.55.412.743 1.072 1.123zm3.91 3.663q.875 0 1.585-.396a2.96 2.96 0 0 0 1.534-2.64v-3.564a.32.32 0 0 0-.165-.297l-1.254-.726v4.604a.7.7 0 0 1-.363.643l-3.119 1.799a3 3 0 0 0 1.783.577m.627-6.039V8.878L10.01 7.822 8.129 8.878v2.244l1.881 1.056zM7.057 5.859a.7.7 0 0 1 .363-.644l3.119-1.798a3 3 0 0 0-1.782-.578q-.874 0-1.584.396A2.96 2.96 0 0 0 6.05 4.324a3.07 3.07 0 0 0-.396 1.551v3.547q0 .199.165.314l1.237.726zm8.383 7.887q.825-.364 1.303-1.123.495-.758.495-1.65a3.15 3.15 0 0 0-.412-1.55q-.413-.743-1.073-1.123l-3.086-1.782q-.099-.065-.181-.049a.3.3 0 0 0-.165.05l-1.238.692 3.993 2.327a.6.6 0 0 1 .264.264.64.64 0 0 1 .1.363zm-3.317-8.382a.63.63 0 0 1 .726 0l3.135 1.831v-.297q0-.792-.396-1.501a2.86 2.86 0 0 0-1.105-1.155q-.71-.43-1.65-.43-.825 0-1.436.347L8.294 5.941a.36.36 0 0 0-.165.314v1.418z";

function BrandIcon({ name, path, viewBox = "0 0 24 24" }: { name: string; path: string; viewBox?: string }) {
  return <svg className={`brand-icon brand-icon-${name}`} aria-hidden="true" viewBox={viewBox} fill="currentColor"><path d={path} /></svg>;
}

function CopyIcon() {
  return <svg aria-hidden="true" viewBox="0 0 20 20" fill="none"><rect x="7" y="6" width="10" height="11" rx="1.5" stroke="currentColor" strokeWidth="1.6" /><path d="M13 6V4.5A1.5 1.5 0 0 0 11.5 3h-7A1.5 1.5 0 0 0 3 4.5v8A1.5 1.5 0 0 0 4.5 14H7" stroke="currentColor" strokeWidth="1.6" /></svg>;
}

function useCopy(text: string) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  }

  return { copied, copy };
}

export function CopyPageButton() {
  const { copied, copy } = useCopy(pageMarkdown);
  const [open, setOpen] = useState(false);
  const [mcpCopied, setMcpCopied] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function closeOnOutsideClick(event: MouseEvent) {
      if (!menuRef.current?.contains(event.target as Node)) setOpen(false);
    }
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", closeOnOutsideClick);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("mousedown", closeOnOutsideClick);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, []);

  function openAssistant(baseUrl: string) {
    const pageUrl = `${window.location.origin}/docs`;
    const prompt = `Read and answer questions about this documentation: ${pageUrl}`;
    window.open(`${baseUrl}${encodeURIComponent(prompt)}`, "_blank", "noopener,noreferrer");
    setOpen(false);
  }

  async function copyMcpConfig() {
    try {
      await navigator.clipboard.writeText(cursorMcpConfig);
      setMcpCopied(true);
      window.setTimeout(() => setMcpCopied(false), 1800);
    } catch {
      setMcpCopied(false);
    }
  }

  return <div className="copy-page-menu" ref={menuRef}>
    <button className="copy-page-button" type="button" onClick={() => setOpen(!open)} aria-expanded={open} aria-haspopup="menu">
      <CopyIcon /><span>{copied ? "Copied" : "Copy page"}</span><span className="copy-page-chevron">⌄</span>
    </button>
    {open && <div className="copy-page-popover" role="menu" aria-label="Documentation actions">
      <button className="copy-menu-item" type="button" role="menuitem" onClick={() => { copy(); setOpen(false); }}><span className="copy-menu-icon"><CopyIcon /></span><span><b>{copied ? "Copied" : "Copy page"}</b><small>Copy this page as Markdown</small></span></button>
      <a className="copy-menu-item" role="menuitem" href="/docs/markdown"><span className="copy-menu-icon">M↓</span><span><b>View as Markdown ↗</b><small>Read the plain-text version</small></span></a>
      <button className="copy-menu-item" type="button" role="menuitem" onClick={() => openAssistant("https://chatgpt.com/?q=")}><span className="copy-menu-icon"><BrandIcon name="openai" path={openaiBlossomPath} viewBox="0 0 20 20" /></span><span><b>Open in ChatGPT ↗</b><small>Ask about this page</small></span></button>
      <button className="copy-menu-item" type="button" role="menuitem" onClick={() => openAssistant("https://claude.ai/new?q=")}><span className="copy-menu-icon"><BrandIcon name="claude" path={siClaude.path} /></span><span><b>Open in Claude ↗</b><small>Ask about this page</small></span></button>
      <button className="copy-menu-item" type="button" role="menuitem" onClick={() => openAssistant("https://www.perplexity.ai/search/new?q=")}><span className="copy-menu-icon"><BrandIcon name="perplexity" path={siPerplexity.path} /></span><span><b>Open in Perplexity ↗</b><small>Ask about this page</small></span></button>
      <button className="copy-menu-item" type="button" role="menuitem" onClick={copyMcpConfig}><span className="copy-menu-icon"><BrandIcon name="cursor" path={siCursor.path} /></span><span><b>{mcpCopied ? "MCP setup copied" : "Connect to Cursor ↗"}</b><small>Copy the Headless MCP setup</small></span></button>
    </div>}
  </div>;
}

export function CommandBlock({ children }: { children: string }) {
  const { copied, copy } = useCopy(children);

  return <div className="command-block">
    <pre><code>{children}</code></pre>
    <button className="copy-command-button" type="button" onClick={copy} aria-label="Copy command">
      <CopyIcon />
      <span>{copied ? "Copied" : "Copy"}</span>
    </button>
  </div>;
}
