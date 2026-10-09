# Wiki Schema

Maintained by the rain-skill `project-wiki` skill.

- `sources/` — immutable raw inputs. Never edited.
- `wiki/` — derived pages, cross-linked with [[page]].
- The long-form record of every decision and what was verified is
  `docs/decisions.md`; wiki pages summarise and point there rather than copy it.
- Append-only: `decisions` entries live in `docs/decisions.md`, newest last.
