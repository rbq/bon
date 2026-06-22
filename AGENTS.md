# Agent Notes

## Project Purpose

This project builds the Crystal `bon` CLI. `bon` prints PDF, image, Typst, or LaTeX inputs through CUPS/`lp` by preparing each input for receipt-printer width handling before printing; temporary PDFs are used only when needed.

## Tooling

- Use `mise` as the entry point for reproducibility.
- Use generated mise bin stubs when available.
- Run `mise generate task-stubs` whenever mise task names are added, removed, or renamed.
- Required and optional development tools are pinned in `.mise.toml`: Crystal `1.20.2`, git-cliff, TinyTeX `2026.06`, and Typst `0.14.2`.
- Main development commands are `mise run spec`, `mise run build`, `mise run run -- --dry-run <file>`, `bin/release-check`, and local `bon --dry-run <file>` through the generated mise stub.
- Keep the Crystal implementation dependency-light. Avoid shard dependencies unless there is a concrete reason.

## Workflow Guidance

- Keep temporary intermediates outside the project tree and clean them up.
- `bon` is an independent implementation, attempt to keep it self-contained and don't rely on other tools and data on the host machine unless explicitely requested.
- Preserve the executable name `bon`.
- Preserve default receipt behavior for 80 mm paper and 203 dpi printer options.
- Keep destination input support for `.pdf`, `.png`, `.jpg`, `.jpeg`, `.typ`, and `.tex`.
- Supported print inputs may be provided as filesystem paths, as a newline-delimited stdin path list via `-`, or as one stdin document stream via `-`.
- Do not add interactive file selection unless explicitly requested.

## Commands

```sh
mise install
mise run spec
mise run build
mise run run -- printer list
mise run run -- --dry-run spec/fixtures/examples/receipt-80mm.typ
bon --dry-run spec/fixtures/examples/receipt-80mm.typ
```

## Keeping Things in Sync

When modifying the application, keep all of the following in sync:

- **README.md** — update the CLI section, configuration example, and Print Pipeline description whenever commands, options, config keys, or pipeline behavior change.
- **AGENTS.md** — record new architecture decisions and significant implementation constraints in the Implementation Notes section so future agents have accurate context.
- **Help output** — every command and subcommand must produce useful `--help` output. Check that the banner, subcommand list, and option descriptions in `cli.cr` match what is documented in `README.md`.
- **Specs** — new features and behavior changes must be covered by specs. Prefer unit tests that exercise the changed module directly, and integration-level CLI specs for end-to-end command behavior. Run `mise run spec` and ensure all examples pass before finishing.
- **Examples** — keep `spec/fixtures/examples/` inputs and `spec/fixtures/examples/README.md` aligned with supported code paths and project scope. Add, replace, or retire repository-local example fixtures when input formats, conversion paths, width/height policies, simulation behavior, or other representative workflows change.
- **Config schema** — if a config key is added, renamed, or removed, update `Config#overlay`, `Config#validate!`, `Config#build_toml`, the `README.md` config example, and any related specs together.
- **Document support matrix** — if a supported input type is added or dropped, update `Document::SUPPORTED_SUFFIXES`, `README.md` (Requirements, CLI, and Print Pipeline sections), `AGENTS.md` Workflow Guidance, related specs, and repository-local examples.

## Release Procedure

- Releases are user-directed. Do not choose a release version, changelog wording, or publication timing without explicit user confirmation.
- Start by inspecting the current state with `git status --short --untracked-files=all`, `git log --oneline -10`, `bin/release-version`, and existing tags when relevant.
- Ask the user which version to release unless they already provided an exact version. If the version is ambiguous, present the current `shard.yml` version and recent release tags, then ask for the intended next version.
- Prepare the release only after the user confirms the version: run `bin/release-prepare <version>` from a clean working tree. If the tree is dirty, stop and ask the user whether to commit, stash, or intentionally proceed only if the helper supports it and the user explicitly approves.
- Inspect the generated `CHANGELOG.md` section after `bin/release-prepare <version>`. The generated entry is a flat commit list, not final release notes.
- Involve the user in changelog curation. Ask the user to approve, provide, or review user-facing wording for new or manually edited `CHANGELOG.md` entries before tagging. Do not invent product claims, migration guidance, or breaking-change notes without evidence from the commits or user input.
- Ensure `CHANGELOG.md` contains a heading for the exact release version, either `## [<version>]` or `## [v<version>]`, and that the entry is suitable for GitHub release notes.
- Run `bin/release-check` after changelog curation. This runs specs, builds `bin/bon-release`, checks `bon -v` and `bon --version`, checks changelog coverage, and validates exact tag consistency when on a tag.
- Commit release changes only when the user asks for a commit or when the release task explicitly includes committing. Use a concise release commit such as `Prepare v<version> release`, and inspect staged diff before committing.
- Create the annotated tag only after the release commit is on the intended branch and the user confirms tagging: run `bin/release-tag <version>`. This validates again and creates but does not push `v<version>`.
- After the annotated tag is created, ask the user for final confirmation to publish. If they confirm, push the tag with `git push origin v<version>`; CI publishes the GitHub release from the pushed tag and extracts the matching `CHANGELOG.md` section as the release body.
- If CI fails, diagnose from GitHub Actions logs and do not retag, force-push, or rewrite release history without explicit user approval.

## Implementation Notes

- Config loads built-in defaults, global config from `$XDG_CONFIG_HOME/bon.toml` or `~/.config/bon.toml`, then local `./bon.toml`.
- Do not commit repo-local `bon.toml`; `config.default.toml` is the tracked template for generated configs.
- Unless specified otherwise, generated config files should include every available top-level option as commented-out defaults so users can discover settings without activating overrides.
- Keep `config.default.toml` in sync whenever config options are added, renamed, removed, or default values change.
- `bon init` is rerunnable: it preserves existing config text by default, updates only `[printer] name`, removes obsolete `[printer] candidates`, and uses `--force` to regenerate from the template.
- `printer.candidates` is deprecated, ignored during config overlay, and emitted as a CLI warning when present.
- Printer-specific overrides are stored under `[printer.<queue>.paper]`, `[printer.<queue>.render]` for `image_ppi`, and `[printer.<queue>.cups.options]`; they are applied only after CUPS queue discovery for printing.
- The local TOML parser intentionally supports only the subset needed by the config schema: tables, dotted tables, strings, booleans, integers, floats, and string arrays.
- The CLI version printed by `bon -v` and `bon --version` is embedded at compile time from `shard.yml`; tag releases must use `v<shard.yml version>` and CI verifies the match before publishing GitHub releases.
- Release tooling is intentionally local-first: direct `bin/release-*` scripts use mise-pinned tools internally, `bin/release-prepare <version>` updates `shard.yml` and prepends a flat git-cliff changelog entry, humans rewrite that entry into user-facing notes, `bin/release-check` validates the candidate, and `bin/release-tag <version>` creates but does not push the annotated tag.
- Keep release helpers as direct scripts under `bin/`, not same-named mise tasks, so `mise generate task-stubs` cannot overwrite them.
- Changelog generation does not assume Conventional Commits. Keep `cliff.toml` configured for a flat commit list unless the project explicitly adopts commit classification.
- `.github/workflows/build.yml` is the CI entrypoint for pull requests, `main`, and `v*` tags; tag builds call the reusable `.github/workflows/release.yml`, which publishes the GitHub release and then calls the reusable Homebrew tap workflow.
- `.homebrew/bon.rb.erb` is the authoritative Homebrew formula template; the reusable Homebrew tap workflow renders it and updates `rbq/homebrew-tap` with `HOMEBREW_TAP_TOKEN`, which must authenticate to the private tap repository. It can also be manually dispatched with a release tag when only the tap publication needs to be retried.
- CUPS discovery uses `lpstat -v` and `lpstat -p` only.
- Printing uses `lp -d <queue> -n <copies> -o KEY=VALUE ... <document>`.
- Print stdin uses `-` as a source marker. If `--stdin-format` is omitted and binary document detection fails, stdin is treated as a newline-delimited path list only when every non-empty line exists; those paths are expanded in place alongside CLI file arguments.
- Stdin document data materializes into the per-job temporary directory, then routes through the same suffix-based `Document.prepare` pipeline as path inputs.
- `bon print margins` and `bon simulate margins` both materialize the embedded `src/bon/assets/margins.typ` asset as a temporary `margins.typ`; keep that asset self-contained, defaulting to 80 mm x 80 mm pages, with one 10 mm margin page and one near-edge top/bottom margin page suitable for print and simulation calibration.
- `--stdin-format=pdf|png|jpg|jpeg|typ|tex` explicitly sets stdin document-data type and disables path-list detection; omitted stdin type auto-detects PDF, PNG, and JPEG binary signatures before trying path-list detection.
- Typst and LaTeX stdin require explicit `--stdin-format` and are compiled from the temporary directory, so project-relative local assets are not available unless the piped source is self-contained.
- Config `[cups]` is reserved for bon-controlled CUPS behavior such as `copies` and `dry_run`; arbitrary CUPS/driver options live under `[cups.options]` and are passed as `lp -o` values. Empty `[cups.options]` string values remove inherited/default options.
- PDF inputs pass through unchanged before width handling.
- PDF size detection scans discoverable `/CropBox` and `/MediaBox` entries on a best-effort basis, uses maximum discovered width/height for conservative validation, and is not a full parser for compressed/object-stream boxes.
- Multi-page PDFs are split into one temporary PDF per page before printing so dynamic CUPS `media=Custom.<width>x<height>` uses each page's own height.
- Typst inputs run `typst compile --root <root> <source> <temp>.pdf`.
- Image inputs use `render.image_ppi` to determine physical size and are sent directly to CUPS when no center-crop is needed.
- Image inputs that need center-cropping fall back to a temporary Typst wrapper PDF and Ghostscript crop.
- Simulation supports PDF, Typst, and PNG/JPEG inputs; PDFs are rasterized page-by-page through Ghostscript, PNGs are read directly, and JPEGs are rasterized through a temporary Typst wrapper.
- Simulation uses configured physical paper width, automatic/configured printable width, crop policy, `render.image_ppi`, and `[simulate]` top/bottom paper margins, background tint, foreground color, and foreground fade when generating mockups.
- Default simulation vertical paper margins remain 10 mm before content and 14 mm after content, while separate technical minimum margins clamp mockups to at least 12 mm before content and 2 mm after content. Keep these configurable rather than changing actual print output.
- Simulated mockups default to foreground color `#232320` and foreground fade `1.0`; keep those defaults to preserve the established mockup look.
- LaTeX `auto` mode tries `latexmk -pdf`, then `tectonic`, then `pdflatex`.
- Width policy: pages wider than physical paper width fail; pages wider than printable width are center-cropped with Ghostscript unless `--no-crop` is set.
- Default PDF/Typst/LaTeX crops use Ghostscript `pdfwrite` and remain PDF; the Typst raster/downsample path is only for `render.typst_mode = "raster"`.
- `render.raster_threshold` and `render.raster_dither` affect only bon-generated 1-bit raster/downsample output, not direct CUPS pass-through or PDF-first `pdfwrite` crops.
- Height policy: pages taller than `paper.max_media_height_pt` fail instead of being clamped to CUPS media height.
- Repository-local example inputs live in `spec/fixtures/examples/` and cover supported suffixes, 58 mm and 80 mm widths, variable-height multi-page documents, Typst, LaTeX, PDF, PNG, JPG, and JPEG paths. Use these for smoke tests instead of external files.
- Thermal printers commonly have a non-printable horizontal margin. bon models this with `paper.printable_width_pt`; the automatic defaults map 80 mm paper to 576 dots at 203 dpi (~72.08 mm printable, ~4 mm cropped from each side) and 58 mm paper to 384 dots (~48.05 mm printable, ~5 mm cropped from each side). Cropping is a last-mile centering step for over-wide pages, not a layout substitute; examples and fixtures should keep meaningful content inside the printable width with margins of at least 4 mm for 80 mm paper and 5 mm for 58 mm paper unless they are explicitly testing crop behavior.
