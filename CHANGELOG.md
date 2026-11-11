# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

## 1.1.0 — 2026-11-11

**Upgrade:**
Run `bash "$HOME/scripts/harness/claude-code/install.sh"` (idempotent): it un-denies the
artifact tools, adds `create_artifact` to the guard's matcher and the new auto-mode rule.
Effective from the next session. New owner request: **make an artifact**
([docs/capture.md](docs/capture.md) → **Artifacts**) — private by default, shared only
when the owner asks.

## 1.0.1 — 2026-10-22

**Upgrade:**
Nothing — display name only.

## 1.0.0 — 2026-10-22

**Upgrade:**
Nothing — initial version; onboarding records it (`work/VERSION`).
