# Agent Notes

## Project Purpose

This project builds the Crystal `bon` CLI. `bon` prints PDF, image, Typst, or LaTeX inputs through CUPS/`lp` by preparing each input for receipt-printer width handling before printing; temporary PDFs are used only when needed.

## Tooling

- Use `mise` as the entry point for reproducibility.
- Use generated mise bin stubs when available.
- Run `mise generate task-stubs` whenever mise task names are added, removed, or renamed.
- Required and optional development tools are pinned in `.mise.toml`: Crystal `1.20.2`, TinyTeX `2026.06`, and Typst `0.14.2`.
- Main development commands are `mise run spec`, `mise run build`, and `mise run run -- --dry-run <file>`.
- Keep the Crystal implementation dependency-light. Avoid shard dependencies unless there is a concrete reason.

## Workflow Guidance

- Keep temporary intermediates outside the project tree and clean them up.
- `bon` is an independent implementation, attempt to keep it self-contained and don't rely on other tools and data on the host machine unless explicitely requested.
- Preserve the executable name `bon`.
- Preserve default receipt behavior for 80 mm paper and 203 dpi printer options.
- Keep destination input support for `.pdf`, `.png`, `.jpg`, `.jpeg`, `.typ`, and `.tex`.
- Supported print inputs may be provided as filesystem paths or as one stdin stream via `-`.
- Do not add interactive file selection unless explicitly requested.

## Commands

```sh
mise install
mise run spec
mise run build
mise run run -- printer list
mise run run -- --dry-run examples/spec/receipt-80mm.typ
bin/bon --dry-run examples/spec/receipt-80mm.typ
```

## Keeping Things in Sync

When modifying the application, keep all of the following in sync:

- **README.md** — update the CLI section, configuration example, and Print Pipeline description whenever commands, options, config keys, or pipeline behavior change.
- **AGENTS.md** — record new architecture decisions and significant implementation constraints in the Implementation Notes section so future agents have accurate context.
- **Help output** — every command and subcommand must produce useful `--help` output. Check that the banner, subcommand list, and option descriptions in `cli.cr` match what is documented in `README.md`.
- **Specs** — new features and behavior changes must be covered by specs. Prefer unit tests that exercise the changed module directly, and integration-level CLI specs for end-to-end command behavior. Run `mise run spec` and ensure all examples pass before finishing.
- **Examples** — keep `examples/spec/` inputs and `examples/spec/README.md` aligned with supported code paths and project scope. Add, replace, or retire repository-local example fixtures when input formats, conversion paths, width/height policies, simulation behavior, or other representative workflows change.
- **Config schema** — if a config key is added, renamed, or removed, update `Config#overlay`, `Config#validate!`, `Config#build_toml`, the `README.md` config example, and any related specs together.
- **Document support matrix** — if a supported input type is added or dropped, update `Document::SUPPORTED_SUFFIXES`, `README.md` (Requirements, CLI, and Print Pipeline sections), `AGENTS.md` Workflow Guidance, related specs, and repository-local examples.

## Implementation Notes

- Config loads built-in defaults, global config from `$XDG_CONFIG_HOME/bon/config.toml` or `~/.config/bon/config.toml`, then local `./config.toml`.
- While `bon` still lives inside the Bondrucker workspace, `./bon/config.toml` is supported as a transition fallback when the CLI is run from the parent directory.
- The local TOML parser intentionally supports only the subset needed by the config schema: tables, dotted tables, strings, booleans, integers, floats, and string arrays.
- CUPS discovery uses `lpstat -v` and `lpstat -p` only.
- Printing uses `lp -d <queue> -n <copies> -o KEY=VALUE ... <document>`.
- Print stdin uses `-` as a source marker, materializes the stream into the per-job temporary directory, then routes through the same suffix-based `Document.prepare` pipeline as path inputs.
- `--stdin-as=pdf|png|jpg|jpeg|typ|tex` explicitly sets the stdin type; omitted stdin type auto-detects only PDF, PNG, and JPEG binary signatures.
- Typst and LaTeX stdin require explicit `--stdin-as` and are compiled from the temporary directory, so project-relative local assets are not available unless the piped source is self-contained.
- Config `[cups]` is reserved for bon-controlled CUPS behavior such as `copies` and `dry_run`; arbitrary CUPS/driver options live under `[cups.options]` and are passed as `lp -o` values. Empty `[cups.options]` string values remove inherited/default options.
- PDF inputs pass through unchanged before width handling.
- PDF size detection scans discoverable `/CropBox` and `/MediaBox` entries on a best-effort basis, uses maximum discovered width/height for conservative validation, and is not a full parser for compressed/object-stream boxes.
- Multi-page PDFs are split into one temporary PDF per page before printing so dynamic CUPS `media=Custom.<width>x<height>` uses each page's own height.
- Typst inputs run `typst compile --root <root> <source> <temp>.pdf`.
- Image inputs use `render.image_ppi` to determine physical size and are sent directly to CUPS when no center-crop is needed.
- Image inputs that need center-cropping fall back to a temporary Typst wrapper PDF and Ghostscript crop.
- Simulation supports Typst and PNG/JPEG inputs; PNGs are read directly and JPEGs are rasterized through a temporary Typst wrapper.
- Simulation uses configured physical paper width, automatic/configured printable width, crop policy, `render.image_ppi`, and `[simulate] background_tint` when generating mockups.
- Simulated mockups default to foreground color `#232320` and foreground fade `1.0`; keep those defaults to preserve the established mockup look.
- LaTeX `auto` mode tries `latexmk -pdf`, then `tectonic`, then `pdflatex`.
- Width policy: pages wider than physical paper width fail; pages wider than printable width are center-cropped with Ghostscript unless `--no-crop` is set.
- Default PDF/Typst/LaTeX crops use Ghostscript `pdfwrite` and remain PDF; the Typst raster/downsample path is only for `render.typst_mode = "raster"`.
- `render.raster_threshold` and `render.raster_dither` affect only bon-generated 1-bit raster/downsample output, not direct CUPS pass-through or PDF-first `pdfwrite` crops.
- Height policy: pages taller than `paper.max_media_height_pt` fail instead of being clamped to CUPS media height.
- Repository-local example inputs live in `examples/spec/` and cover supported suffixes, 58 mm and 80 mm widths, variable-height multi-page documents, Typst, LaTeX, PDF, PNG, JPG, and JPEG paths. Use these for smoke tests instead of external files.
