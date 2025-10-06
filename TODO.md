# MeasurementBrowser TODO

This document tracks prioritized bug fixes and architectural improvements. Priorities:
- P0: correctness or user-facing issues to fix ASAP
- P1: architectural cleanup and performance
- P2: quality-of-life and longer-term improvements

## P0 — Correctness and user-facing fixes

- [ ] Use .txt consistently for device metadata file in the UI copy
  - Files:
    - `src/Gui.jl` (modal text currently says `device_info.csv`)
  - Decision: Keep `device_info.txt` (CSV-formatted text) as the canonical filename.
  - Acceptance: The modal/help text only mentions `.txt` and matches the loader behavior.

- [ ] Fix `DeviceInfo` constructor to match field type
  - Files: `src/DeviceParser.jl`
  - Change: `DeviceInfo(location::Vector{String}) = DeviceInfo(location, Dict{Symbol,Any}())`
  - Acceptance: No method errors or type instability when merging device metadata.

- [ ] Fix timestamp sort sentinel
  - Files: `src/DeviceParser.jl`
  - Change: Replace invalid `DateTime(typemax(Date).year)` with `DateTime(9999,12,31)` when `timestamp === nothing`.
  - Acceptance: Sorting works with files that lack timestamps.

- [ ] Eliminate file I/O in `meas_id` during rendering
  - Files: `src/DeviceParser.jl`, `src/Gui.jl`
  - Change: Precompute display fields during scan:
    - Cache wakeup pulse count (int) from file read once in `scan_directory`
    - Cache PUND voltage (string) extracted from filename
    - Provide a stable, cached `display_label` (or reuse `meas_id` but backed by cached fields)
  - Acceptance: No file reads occur from inside per-frame rendering paths.

- [ ] Make device metadata filename handling consistent
  - Files: `src/DeviceParser.jl`, `src/Gui.jl`
  - Keep loader checking `device_info.txt` (already implemented)
  - Ensure all user-facing text and examples mention `device_info.txt` (not `.csv`).

## P1 — Architectural and performance work

- [ ] Centralize measurement type detection
  - Files: `src/DeviceParser.jl`, `src/PlotGenerator.jl`
  - Change: Introduce `detect_measurement_type(filename)::Symbol` in one place and reuse.
  - Acceptance: Parser, plotter, and tests use the same detection logic.

- [ ] Unify parameter key types
  - Files: `src/DeviceParser.jl`, `src/Gui.jl` (+ any consumers)
  - Change: Standardize on `Symbol` keys for both device-level and measurement-level parameters.
  - Acceptance: UI renders without special-casing `String` vs `Symbol` keys.

- [ ] Provide a single display API
  - Files: `src/DeviceParser.jl`
  - Change: Add `display_label(::MeasurementInfo)::String` (or refactor `meas_id`) to rely on cached fields only.
  - Acceptance: UI uses the single API everywhere.

- [ ] Module/layout refactor (incremental)
  - Proposal:
    - Device (parsing, hierarchy)
    - Data (loaders + analysis)
    - Plotting (plots)
    - UI (ImGui + Makie integration)
  - Acceptance: Clear dependency direction: UI -> Plotting -> Data; UI -> Device.

- [ ] Logging consistency
  - Files: `src/DataLoader.jl`, `src/DeviceParser.jl`, `src/Gui.jl`
  - Change: Replace `println` with `@info/@warn/@error` consistently; include `filepath` in messages.
  - Acceptance: Logs are structured and consistent across modules.

- [ ] Improve file dialog portability
  - Files: `src/Gui.jl`
  - Change: Add fallback if `kdialog` is unavailable (e.g., try `zenity`, or a cross-platform picker).
  - Acceptance: Opening folders works on non-KDE systems.

## P1 — Robustness and small correctness fixes

- [ ] `get_measurements_stats` numeric range detection
  - Files: `src/DeviceParser.jl`
  - Change: Use runtime numeric filtering: `numeric_values = [v for v in values if v isa Number]`.
  - Acceptance: Ranges computed when values are `Vector{Any}` but numeric inside.

- [ ] `read_iv_sweep` header validation and guards
  - Files: `src/DataLoader.jl`
  - Change: Validate that both V and I indices exist (error if either missing). Guard `data_start == 1`.
  - Acceptance: Graceful error paths and fewer silent mis-parses.

## P2 — Packaging, tests, and docs

- [ ] Project.toml cleanups
  - Files: `Project.toml`
  - Change:
    - Replace placeholder UUID with a real one.
    - Remove stdlibs from `[deps]`/`[compat]` (Dates, Printf, Statistics).
    - Add compat for `CSV`, `DataFrames`, etc., consistent with target Julia version.
  - Acceptance: `Pkg.resolve` is clean; CI passes with locked compat.

- [ ] Test through the package API
  - Files: `test/`
  - Change: Prefer `using MeasurementBrowser` over direct `include` of `src` files; add tests:
    - `scan_directory` on `test/` folder
    - device metadata loading/merging from `device_info.txt`
    - `detect_measurement_type` unit tests
    - plot generator fallback behavior
  - Acceptance: Tests exercise real module boundaries.

- [ ] TLM naming consistency
  - Files: `src/DeviceParser.jl`, `src/PlotGenerator.jl`, tests
  - Change: Ensure classification and display use a single naming scheme (e.g., “TLM 4-Point”).
  - Acceptance: Tests cover expected titles for TLM.

- [ ] Document device metadata file format
  - Files: `TODO.md` or a new `README.md`
  - Change: Provide an example `device_info.txt` with comments and precedence rules (full path overrides leaf).
  - Acceptance: Users can author the file without guesswork.

## P2 — Performance/UX polish

- [ ] Cache-heavy computations at scan time
  - Files: `src/DeviceParser.jl`
  - Change: Precompute/carry any heavy derived values needed by the UI.
  - Acceptance: Scrolling large lists remains smooth.

- [ ] GL/Makie integration hardening
  - Files: `src/MakieIntegration.jl`
  - Change: Keep the integration surface small; verify against current GLMakie/CImGui versions.
  - Acceptance: No regressions across upgrades within compat bounds.

- [ ] Precompile workloads target hot paths
  - Files: `src/PlotGenerator.jl`, `src/MakieIntegration.jl`
  - Change: Ensure precompile blocks don’t hit filesystem and do cover typical render paths.
  - Acceptance: Faster first-plot latency without side effects.

## Cleanup / dead code

- [ ] `get_file_patterns` usage
  - Files: `src/DataLoader.jl`
  - Change: Wire it into scanning or remove it.
  - Acceptance: No unused APIs.

- [ ] Start script return semantics
  - Files: `start.jl`
  - Change: `start_browser` currently returns nothing; clarify or remove `app =`.
  - Acceptance: Start script intent is clear.

---

## Milestone 1 (P0)

- [ ] Modal text switch to `.txt`
- [ ] `DeviceInfo` constructor fix
- [ ] Timestamp sort sentinel
- [ ] Cache wakeup pulse count and PUND voltage; stop file I/O in `meas_id`
- [ ] Confirm loader and UI copy both use `device_info.txt`

## Milestone 2 (P1)

- [ ] Centralized type detection utility
- [ ] Unify parameter key types
- [ ] Display label API
- [ ] Logging consistency
- [ ] File dialog portability

## Milestone 3 (P1/P2)

- [ ] Packaging compat + UUID cleanup
- [ ] Test via package API
- [ ] TLM naming consistency
- [ ] README for `device_info.txt`
- [ ] Precompile coverage for hot paths