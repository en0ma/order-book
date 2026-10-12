# Dead Code and Repository File Audit

Date: 2026-10-11. Scope: default-branch GitHub code-search index, selected source files, package scripts, and current documentation. **This is a targeted static reference audit, not an exhaustive reachability graph.** The repository was not cloned into a local environment; a fresh full-tree compiler/dependency reachability check is a follow-up requirement.

## Removed in this change

| Path | Decision | Evidence |
| --- | --- | --- |
| `docs/REPOSITORY_PROFILE.md` | Remove | Obsolete proposal to edit repository metadata rather than implementation guidance; not part of Mintlify navigation and no indexed references to its filename. The proposal repeats stale "deployment deployment" editorial artifacts. Removing the file does not change GitHub metadata. |

## Keep: positive evidence of use

| Path or family | Evidence | Decision |
| --- | --- | --- |
| `src/ProRataOrderBook.sol` | Referenced from `test/ProRataOrderBook.t.sol`, `test/Gas.t.sol`, `test/BorosParityWorkloads.t.sol`, `test/ExtremaOracleIntegration.t.sol`, plus architectural documentation | Keep as reference/testing implementation, even though not the deployable modular Core |
| `test/mocks/MockMarkOracle.sol` | Imported by numerous deployable, liquidation, solvency and portfolio tests | Keep test fixture |
| `test/mocks/MockExtremaOracle.sol` | Referenced by reference Core and gas test suites | Keep test fixture |
| `test/mocks/MockExternalPriceSource.sol` | Referenced by `test/ValidatedMarkOracleAdapter.t.sol` | Keep test fixture |
| `script/DeployStandalone.s.sol` | Referenced by deployer tests, SDK deployment-spec tests, integration and network deployment guides | Keep supported deployment bootstrap |
| `script/compare_boros.mjs` | Referenced by matched benchmark documentation and dedicated JS tests | Keep benchmark tooling |
| `test/MainnetFork.t.sol` and other fork suites | Mainnet-fork references in CI and release/security documentation | Keep; tests do not constitute deployed contracts |

## Needs deeper reachability analysis before removal

1. **TypeScript exported APIs:** Operator SDK has many exported modules and manually maintained declaration files. A module with no *internal* caller may be a public API; first inventory package exports, declaration symbols, tests, docs, and external compatibility expectations.
2. **Solidity interfaces and library helpers:** External entrypoints can be called by integrated third-party DEXs without any reference within this repository. Use build artifacts, selectors and ABI snapshots; assess legacy compatibility before pruning.
3. **Reference monolith:** Split reference-only targets from the deployable build profile only after checking comparison benchmarks and fixture coverage. This may reduce CI cost without deleting code.
4. **Historical audit and benchmark docs:** Review content freshness and cross-links, then archive or consolidate. No evidence presently justifies deleting security evidence or benchmark reproduction details.
5. **Generated vs checked-in files:** Examine `dist/`, `out/`, `cache/`, snapshot outputs and build manifests from a full tracked-file listing and ignore rules. Do not remove versioned manifests or declaration files simply because a build can regenerate some content.

## Recommended automated checks

- Retrieve the complete tracked file list using `git ls-files`; classify source, tests, fixtures, generated output, docs and workflow inputs.
- Build a Solidity import graph from `src/`, `script/`, and `test/`; mark deployment entrypoints, tests, ABI exports and explicit references as roots.
- Use TypeScript dependency and export analysis against `sdk`, `operator`, `reference/indexer` and package entrypoints. Review results manually because dynamically referenced modules may be misclassified.
- Find docs not present in `docs.json`; check inbound links before deciding whether they are intentionally standalone references.
- Remove one candidate group at a time in a dedicated PR and require Foundry, SDK/operator/indexer tests, fork tests, size checks, gas snapshots, and Mintlify validation.

## Result

**One low-risk obsolete document removed. No Solidity contracts, public APIs, test fixtures, or deployment scripts removed.** Additional removals require repository-wide dependency evidence, not merely zero matches in indexed GitHub search.
