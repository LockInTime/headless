"use client";

import { CommandBlock } from "@/components/docs-copy-controls";
import { plainText } from "@/lib/markdown";
import { useState } from "react";

type CommandGroup = {
  title: string;
  id: string;
  description: string;
  usage: string;
};

export function CommandDirectory({ groups }: { groups: CommandGroup[] }) {
  const [query, setQuery] = useState("");
  const normalized = query.trim().toLowerCase();
  const visible = normalized
    ? groups.filter((group) =>
        `${group.title} ${group.description} ${group.usage}`
          .toLowerCase()
          .includes(normalized),
      )
    : groups;

  const countLabel =
    visible.length === 0
      ? `No commands match “${query}”.`
      : `${visible.length} of ${groups.length} groups`;

  return (
    <>
      <div className="command-filter">
        <label htmlFor="command-filter">Filter commands</label>
        <input
          id="command-filter"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="visit, inspect, credentials…"
          autoComplete="off"
          spellCheck={false}
        />
        <p role="status" aria-live="polite">
          {countLabel}
        </p>
      </div>
      {visible.length > 0 ? (
        <nav className="docs-toc docs-toc-inline" aria-label="On this page">
          <p>On this page</p>
          {visible.map((group) => (
            <a href={`#${group.id}`} key={group.id}>
              {group.title}
            </a>
          ))}
        </nav>
      ) : null}
      {visible.map((group, index) => (
        <section id={group.id} key={group.id}>
          <p className="docs-label">
            {String(index + 1).padStart(2, "0")} / {group.title}
          </p>
          <h2>{group.title}</h2>
          <p>{plainText(group.description)}</p>
          <CommandBlock>{group.usage}</CommandBlock>
        </section>
      ))}
    </>
  );
}
