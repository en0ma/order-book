# Documentation Site

This directory supports a Mintlify documentation site. The canonical content remains in repository Markdown. Use `docs.json` at the repository root for navigation. Run the Mintlify CLI preview from the repository root after installing the CLI according to Mintlify's current instructions.

## Editorial rules

- Use direct, short sentences and imperative steps where appropriate.
- Prefer the exact deployed contract, function, role and field names.
- Explain each parameter's unit, allowed values, mutability and authority.
- Distinguish Core custody and matching from team-hosted API, indexer and operator services.
- Every guide must link to the next task and contain a command or acceptance criterion when applicable.
- State explicitly when an action needs an alternative deployment or migration instead of inventing admin APIs.
- Do not use repeated readiness labels or marketing claims.
- Mark code and configuration examples as examples. Never ship placeholder addresses as usable deployment inputs.

## Diagram convention

Source-editable diagrams belong in `docs/assets/diagrams/source/`; exported SVGs belong in `docs/assets/diagrams/`. SVGs are suitable for Mintlify images. Keep labels legible in light and dark backgrounds. Retain Mermaid in internal conceptual pages until each is replaced by an edited, reviewed SVG. A diagram must never imply that the repository hosts the user's RPC or keeper services.

## Validation

Run `forge test -vvv`, `npm test` from the SDK and operator package directories, and the mainnet-fork CI. Review each linked function and configuration field against the selected release commit. Preview navigation and asset paths with the Mintlify CLI. Treat published docs changes as part of each protocol release.
