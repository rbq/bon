# Agent Notes

## Project Purpose

This project builds the Crystal `bon` CLI. `bon` prints PDF, image, Typst, or LaTeX inputs through CUPS/`lp` by preparing each input for receipt-printer width handling before printing; temporary PDFs are used only when needed.

## Tooling

- Use `mise` as the entry point for reproducibility.
- Use generated mise bin stubs when available.
- Run `mise generate task-stubs` whenever mise task names are added, removed, or renamed.
- Required tools are pinned in `.mise.toml`: Crystal `1.20.2` and Typst `0.14.2`.
- Main development commands are `mise run spec`, `mise run build`, and `mise run run -- --dry-run <file>`.
- Keep the Crystal implementation dependency-light. Avoid shard dependencies unless there is a concrete reason.

## Workflow Guidance

- Keep temporary intermediates outside the project tree and clean them up.
- Do not use the parent Bondrucker Python scripts from this project; `bon` is the independent implementation.
- Preserve the executable name `bon`.
- Preserve default receipt behavior for 80 mm paper and 203 dpi printer options.
- Keep destination input support for `.pdf`, `.png`, `.jpg`, `.jpeg`, `.typ`, and `.tex`.
- Do not add interactive file selection unless explicitly requested.

## Commands

```sh
mise install
mise run spec
mise run build
mise run run -- printer list
mise run run -- --dry-run ../Wetterbericht.typ
bin/bon --dry-run ../Wetterbericht.typ
```

## Implementation Notes

- Config loads built-in defaults, global config from `$XDG_CONFIG_HOME/bon/config.toml` or `~/.config/bon/config.toml`, then local `./config.toml`.
- While `bon` still lives inside the Bondrucker workspace, `./bon/config.toml` is supported as a transition fallback when the CLI is run from the parent directory.
- The local TOML parser intentionally supports only the subset needed by the config schema: tables, dotted tables, strings, booleans, integers, floats, and string arrays.
- CUPS discovery uses `lpstat -v` and `lpstat -p` only.
- Printing uses `lp -d <queue> -n <copies> -o KEY=VALUE ... <document>`.
- PDF inputs pass through unchanged before width handling.
- Typst inputs run `typst compile --root <root> <source> <temp>.pdf`.
- Image inputs use `render.image_ppi` to determine physical size and are sent directly to CUPS when no center-crop is needed.
- Image inputs that need center-cropping fall back to a temporary Typst wrapper PDF and Ghostscript crop.
- LaTeX `auto` mode tries `latexmk -pdf`, then `tectonic`, then `pdflatex`.
- Width policy: pages wider than physical paper width fail; pages wider than printable width are center-cropped with Ghostscript unless `--no-crop` is set.
