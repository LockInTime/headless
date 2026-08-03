"use client";

import Image from "next/image";
import { useEffect, useMemo, useState } from "react";
import github from "@/public/scan-github.png";

/** Viewport for the capture below — must match scan-github.png pixel size. */
const VIEWPORT = { width: 1152, height: 610 } as const;

type PixelBox = { x: number; y: number; width: number; height: number };

type InspectStep = {
  ref: string;
  role: string;
  name: string;
  bounds: PixelBox;
  tag: { top: number; left: number };
  command: string;
  result: string;
  action?: boolean;
};

/** Pixel bounds from `headless inspect --context actions` on github.com (viewport screenshot). */
const steps: InspectStep[] = [
  {
    ref: "@e8",
    role: "link",
    name: "Pricing",
    bounds: { x: 395, y: 13, width: 40, height: 22 },
    tag: { top: 9.5, left: 27 },
    command: 'headless --session qa inspect --context actions --task "find signup controls"',
    result: "64 elements · refs @e1–@e64",
  },
  {
    ref: "@e12",
    role: "textbox",
    name: "Enter your email",
    bounds: { x: 382, y: 252, width: 152, height: 27 },
    tag: { top: 49.5, left: 8 },
    command: 'headless --session qa fill --ref @e12 --text "you@company.com"',
    result: '✓ filled textbox "Enter your email"',
  },
  {
    ref: "@e13",
    role: "button",
    name: "Sign up for GitHub",
    bounds: { x: 538, y: 251, width: 111, height: 30 },
    tag: { top: 52, left: 43 },
    command: "headless --session qa click --ref @e13",
    result: '✓ clicked button "Sign up for GitHub"',
    action: true,
  },
];

const STEP_MS = 3200;

function toPercent(box: PixelBox) {
  return {
    top: (box.y / VIEWPORT.height) * 100,
    left: (box.x / VIEWPORT.width) * 100,
    width: (box.width / VIEWPORT.width) * 100,
    height: (box.height / VIEWPORT.height) * 100,
  };
}

/** Hero demo: viewport screenshot + inspect bounds from the same Headless session. */
export function ScanFrame() {
  const [active, setActive] = useState(0);
  const [ready, setReady] = useState(false);

  const resolvedSteps = useMemo(
    () => steps.map((step) => ({ ...step, box: toPercent(step.bounds) })),
    [],
  );

  useEffect(() => {
    setReady(true);
    const timer = window.setInterval(() => {
      setActive((index) => (index + 1) % resolvedSteps.length);
    }, STEP_MS);
    return () => window.clearInterval(timer);
  }, [resolvedSteps.length]);

  const step = resolvedSteps[active];

  return (
    <div
      className="scan-frame"
      role="img"
      aria-label="Headless inspecting github.com: semantic refs for a nav link, email field, and sign-up button from a live accessibility tree"
    >
      <div className="scan-frame-head">
        <span className="scan-dot" />
        <span className="scan-dot" />
        <span className="scan-dot" />
        <p>github.com</p>
        <span className="scan-head-status">
          <span className="scan-head-pulse" />
          live inspect
        </span>
      </div>

      <div className={`scan-canvas${ready ? " scan-canvas-ready" : ""}`}>
        <Image
          src={github}
          alt=""
          width={VIEWPORT.width}
          height={VIEWPORT.height}
          sizes="(max-width: 980px) 100vw, 55vw"
          priority
          className="scan-canvas-img"
        />

        <div className="scan-overlay" aria-hidden="true">
          <div className="scan-grid" />
          <div className="scan-vignette" />
          <div className="scan-line" />

          {resolvedSteps.map((item, index) => {
            const isActive = index === active;
            return (
              <div
                key={item.ref}
                className={`scan-target${isActive ? " scan-target-active" : ""}${item.action ? " scan-target-action" : ""}`}
                style={{
                  top: `${item.box.top}%`,
                  left: `${item.box.left}%`,
                  width: `${item.box.width}%`,
                  height: `${item.box.height}%`,
                }}
              >
                <span className="scan-target-corner scan-target-corner-tl" />
                <span className="scan-target-corner scan-target-corner-tr" />
                <span className="scan-target-corner scan-target-corner-bl" />
                <span className="scan-target-corner scan-target-corner-br" />
              </div>
            );
          })}

          {resolvedSteps.map((item, index) => {
            const isActive = index === active;
            return (
              <div
                key={`${item.ref}-tag`}
                className={`scan-tag${isActive ? " scan-tag-active" : ""}${item.action ? " scan-tag-action" : ""}`}
                style={{ top: `${item.tag.top}%`, left: `${item.tag.left}%` }}
              >
                <span className="scan-tag-ref">{item.ref}</span>
                <span className="scan-tag-role">{item.role}</span>
                <span className="scan-tag-name">&ldquo;{item.name}&rdquo;</span>
              </div>
            );
          })}

          <div
            className="scan-cursor"
            style={{
              top: `${step.box.top + step.box.height / 2}%`,
              left: `${step.box.left + step.box.width / 2}%`,
            }}
          />
        </div>
      </div>

      <div className="scan-terminal">
        <div className="scan-terminal-row">
          <span className="scan-terminal-prompt">$</span>
          <code key={step.command}>{step.command}</code>
        </div>
        <div className="scan-terminal-row scan-terminal-result">
          <span className="scan-terminal-prompt">&gt;</span>
          <code key={step.result}>{step.result}</code>
        </div>
        <div className="scan-terminal-steps" aria-hidden="true">
          {resolvedSteps.map((item, index) => (
            <span key={item.ref} className={index === active ? "scan-step-active" : undefined} />
          ))}
        </div>
      </div>
    </div>
  );
}
