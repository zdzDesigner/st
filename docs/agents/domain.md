# Domain Docs

How engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout

This repo uses a single-context layout:

- `CONTEXT.md` at the repo root for project vocabulary and domain context
- `docs/adr/` for architectural decision records
- `docs/zig-architecture.md` and `docs/architecture-flow.md` for the current C/Zig migration architecture

## Before Exploring

Read these files when they are relevant to the task:

- `CONTEXT.md` if it exists
- ADRs under `docs/adr/` if they touch the area being changed
- `docs/zig-architecture.md` before changing C/Zig boundaries
- `docs/architecture-flow.md` before changing major terminal, search, selection, input, CSI, resize, draw, or external pipe flows

If `CONTEXT.md` or `docs/adr/` does not exist yet, proceed without treating the absence as an error. The domain-modeling workflows can create them when domain terms or architectural decisions are actually resolved.

## Vocabulary

When output names a domain concept, issue title, refactor proposal, hypothesis, or test name, use the vocabulary from `CONTEXT.md` when present.

If a needed concept is missing from the glossary, note it for domain-modeling rather than inventing conflicting terms.

## ADR Conflicts

If a proposal or implementation contradicts an existing ADR, surface the conflict explicitly instead of silently overriding the decision.
