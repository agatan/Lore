# Lore repository instructions

## Outcome

Keep Lore's implementation, external specification, and internal design aligned while preserving user data and observable behavior.

## Sources of truth

- `docs/spec.md` and `docs/spec.html`: user-visible behavior and supported automation interfaces.
- `docs/design.md` and `docs/design.html`: current targets, modules, runtime flows, persistence, and extension points.
- `PRIVACY.md`: data storage and transmission boundaries.
- Tests and production code: executable evidence. If they disagree with the documents, report the mismatch and align all affected artifacts in the same change.

## Change contract

- For review, explanation, or diagnosis requests, inspect and report; do not edit unless the user also asks for a change.
- For implementation or refactoring requests, make the smallest coherent change, preserve external behavior unless explicitly changed, and validate in proportion to risk.
- Before changing external behavior, module boundaries, persistence models, deletion semantics, or data transmission, update the relevant Markdown and HTML documents first. Treat the updated design and specification as automatically approved and continue to implementation unless the user explicitly requests pair review or an approval pause.
- Do not commit, push, publish, open a pull request, install software, or change external systems unless explicitly requested.
- Ask before destructive or hard-to-recover actions whose exact target is not already explicit.

## Implementation constraints

- Prefer KISS, YAGNI, and small explicit abstractions. Remove unreachable prototype paths and compatibility shims that are not required by the current specification or persisted user data.
- Do not swallow errors. Handle them, surface them, or rethrow them with clear intent.
- Keep domain decisions out of SwiftUI, GRDB records, and provider adapters.
- Preserve these recovery contracts: save finalized dictation text before formatting; use raw text when formatting fails; leave the result on the clipboard when insertion fails; commit life-log audio before processing; resume pending chunks; back up an existing database before migration and daily; retain seven database backups; remove backups when the user chooses full data deletion.
- Cloud processing is opt-in. Never send recorded audio, API keys, unrelated history, or frontmost-application metadata.
- Add a GRDB migration only for a persisted schema change. Do not add migrations or fallback decoding for unreleased, unreachable states.

## Validation

- Documentation-only changes: verify local links, headings, and Markdown/HTML parity.
- Domain, persistence, engine, or automation changes: run `swift test`.
- User-visible UI or workflow changes: also run `make ui-test` against the signed app.
- Persistence, migration, backup, or deletion changes: add focused regression tests for both success and failure behavior.

## Completion report

Describe only the final state. Include changed behavior or structure, validation performed, and any remaining blocker or uncertainty.
