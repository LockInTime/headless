"use client";

import { CommandBlock } from "@/components/docs-copy-controls";
import { plainText } from "@/lib/markdown";
import { useMemo, useState } from "react";

type CommandGroup = {
  title: string;
  id: string;
  description: string;
  usage: string;
};

export function CommandDirectory({ groups }: { groups: CommandGroup[] }) {
  const [query, setQuery] = useState("");
  const normalized = query.trim().toLowerCase();
  const visible = useMemo(() => {
    if (!normalized) return groups;
    return groups.filter((group) =>
      `${group.title} ${group.description} ${group.usage}`
        .toLowerCase()
        .includes(normalized),
    );
  }, [groups, normalized]);

  return (
    <>
      <div className="command-filter">
        <label htmlFor="command-filter">Filter commands</label>
        <input
          id="command-filter"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="visit, inspect, record…"
          autoComplete="off"
          spellCheck={false}
        />
        <p>
          {visible.length} of {groups.length} groups
        </p>
      </div>
      {visible.length === 0 ? (
        <p role="status">No commands match “{query}”.</p>
      ) : (
        visible.map((group, index) => (
          <section id={group.id} key={group.id}>
            <p className="docs-label">
              {String(index + 1).padStart(2, "0")} / {group.title}
            </p>
            <h2>{group.title}</h2>
            <p>{plainText(group.description)}</p>
            <CommandBlock>{group.usage}</CommandBlock>
          </section>
        ))
      )}
    </>
  );
}
