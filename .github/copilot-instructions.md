# Copilot / AI Agent Instructions (starter)

Purpose
- Provide concise, actionable steps an AI coding agent should take when exploring and modifying this repository.

Repository state
- This repository currently has no source files committed (only .git). Treat this file as a starter template for future code.

Quick discovery checklist
- List tracked files: `git ls-files` (or `Get-ChildItem -Recurse -Force` on PowerShell).
- Search for common manifest files: `package.json`, `pyproject.toml`, `requirements.txt`, `pom.xml`, `build.gradle`, `go.mod`, `Cargo.toml`, `Dockerfile`, `Makefile`, and `README.md`.
- Look for GitHub Actions: check `.github/workflows/` for CI flows and common scripts.

How to reason about architecture (what to inspect)
- Entry points: find top-level `src/`, `cmd/`, `app/`, or language-specific main files (e.g. `index.js`, `main.go`, `src/main.py`).
- Service boundaries: locate directories named `api`, `worker`, `services`, or `internal` to infer separation of concerns.
- Data flows: inspect `config`, `migrations`, `db` or `schema` folders and any ORM models or DTO types to understand persistence.
- Runtime: read `Dockerfile`, `Procfile`, or CI workflows to learn how the project is run and deployed.

Build / test / debug commands (discover at runtime)
- JavaScript/Node: if `package.json` exists, use `npm run build`, `npm test`, or the `scripts` section for commands.
- Python: when `pyproject.toml`/`requirements.txt`/`setup.py` present, prefer `pytest` for tests and `python -m <module>` for running.
- Go: if `go.mod` present, use `go test ./...` and `go run ./cmd/<name>`.
- Docker: inspect `docker build`/`docker-compose.yml` for multi-service runs.
- CI: follow commands found in `.github/workflows/*.yml` to replicate CI-local steps.

Project-specific conventions (apply when files appear)
- Typical layout to look for: top-level `src/` or language-rooted layout (e.g. `cmd/`, `pkg/` for Go, `app/`/`lib/` for Python/JS).
- Tests layout: prefer `tests/`, `__tests__/`, or `*_test.go`. Mirror existing test patterns when adding new tests.
- Configuration: prefer environment variables read from `.env` or files under `config/`; do not hardcode secrets.

Integration points & dependencies
- Check `Dockerfile`, `docker-compose.yml`, or `.github/workflows` to find external services (databases, caches, queues). Record hostnames/ports and required env vars.
- Check `requirements.txt`, `package.json`, `go.mod`, or `pom.xml` to enumerate third-party libraries.

Editing guidance
- Keep changes focused and minimal. Add high-level notes in PR descriptions to justify structural changes.
- If adding commands or scripts, also update `README.md` with concise reproduction steps.

When you cannot find expected files
- Report what you searched for and propose a minimal actionable change (e.g., add a README describing intended language and basic run steps).

Where to update these instructions
- Maintain this file when repository layout or CI changes. Prefer concrete examples (file paths, script names) rather than generic rules.

If anything here is unclear or you need repo-specific examples, ask a human for the intended language/runtime and main entrypoint.
