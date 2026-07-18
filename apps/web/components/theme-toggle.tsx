"use client";

import { useEffect, useState } from "react";

type Theme = "light" | "dark";

function readTheme(): Theme {
  return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
}

/** Light/dark switcher. Reflects and writes `data-theme` on <html>, set first by the no-flash inline script in the root layout. */
export function ThemeToggle({ className }: { className?: string }) {
  const [theme, setTheme] = useState<Theme>("dark");

  useEffect(() => {
    setTheme(readTheme());
  }, []);

  function toggle() {
    const next: Theme = theme === "light" ? "dark" : "light";
    document.documentElement.setAttribute("data-theme", next);
    window.localStorage.setItem("theme", next);
    setTheme(next);
  }

  return (
    <button type="button" className={className ? `${className} theme-toggle` : "theme-toggle"} onClick={toggle} aria-label={theme === "light" ? "Switch to dark mode" : "Switch to light mode"} title={theme === "light" ? "Switch to dark mode" : "Switch to light mode"}>
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className="theme-toggle-sun">
        <circle cx="12" cy="12" r="4.2" stroke="currentColor" strokeWidth="1.8" />
        <path d="M12 2.5v2.4M12 19.1v2.4M4.2 4.2l1.7 1.7M18.1 18.1l1.7 1.7M2.5 12h2.4M19.1 12h2.4M4.2 19.8l1.7-1.7M18.1 5.9l1.7-1.7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className="theme-toggle-moon">
        <path d="M20.2 14.7A8.5 8.5 0 1 1 9.3 3.8a7 7 0 0 0 10.9 10.9Z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" />
      </svg>
    </button>
  );
}
