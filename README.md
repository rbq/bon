# bon

`bon` is a Crystal CLI for printing receipt-sized documents through CUPS/`lp`. It accepts PDF, PNG, JPEG, Typst, and LaTeX files, converts inputs to a temporary PDF only when needed, applies receipt-printer width handling, and sends the final document to a discovered or configured thermal printer.

## Installation

Download or build the `bon` executable and place it somewhere on your `PATH`, for example `$HOME/.local/bin/bon`.

```sh
install -m 755 bon "$HOME/.local/bin/bon"
bon --version
```

A Homebrew formula is planned. Once it exists, installation will look like:

```sh
brew install <tap>/bon
```

## Requirements

Runtime tools:

- CUPS commands: `lpstat` and `lp`
- Optional CUPS command: `lpoptions` for driver option validation
- Ghostscript `gs` when center-cropping/rasterizing to printer dots is needed
- Typst for `.typ` inputs, JPEG simulation, and image inputs that need center-cropping
- Optional LaTeX tools for `.tex` inputs: `latexmk`, `tectonic`, or `pdflatex`

## Usage

Create a config file from discovered printers:

```sh
bon init
```

Use `--global` to write `~/.config/bon.toml` instead of a local `./bon.toml`:

```sh
bon init --global
```

Inspect or edit the effective configuration:

```sh
bon config show
bon config edit
bon config check
```

List CUPS queues and select one explicitly when printing. To make a queue the default, set `printer.name` in the config opened by `bon config edit`:

```sh
bon printer list
bon --printer EPSON_TM_m30III receipt.pdf
```

Render a mockup before printing. Simulation supports Typst, PNG, and JPEG inputs:

```sh
bon simulate receipt.typ
bon simulate --paper-mm 58 --out-dir preview receipt.png
```

Print one or more files. Supported print inputs are PDF, PNG, JPEG, Typst, and LaTeX:

```sh
bon receipt.pdf
bon receipt.png receipt.typ invoice.tex
```

Dry-run a print to inspect the external commands without submitting an `lp` job:

```sh
bon --dry-run receipt.pdf
```

Print one document from stdin. Binary PDF, PNG, and JPEG input is auto-detected; Typst and LaTeX stdin must be typed explicitly:

```sh
cat receipt.pdf | bon --dry-run -
cat receipt.typ | bon --dry-run --stdin-as typ -
```

Print paths from stdin, one path per line. Stdin paths can be combined with normal CLI file arguments:

```sh
printf '%s\n' receipt.typ invoice.tex | bon --dry-run -
printf '%s\n' invoice.tex | bon --dry-run receipt.pdf -
```

## CLI

```text
Usage: bon [print] [options] FILE...|-
       bon print margins [options]
       bon simulate [options] [FILE...]
       bon simulate margins [options]
       bon sim [options] [FILE...]
       bon printer [list]
       bon config <check|show|edit>
       bon init [options]
```

Commands:

- `print [options] FILE...|-` - print one or more files, one supported document from stdin, or newline-delimited paths from stdin with `-`. This is the default command, so `bon FILE...` also works.
- `print margins [options]` - print the built-in 80 mm x 80 mm two-page margin calibration sheet embedded from `src/bon/assets/margins.typ`.
- `simulate [options] [FILE...]` - render receipt mockups for `.typ`, `.png`, `.jpg`, and `.jpeg` inputs. If no files are passed, matching inputs in the current directory are used.
- `simulate margins [options]` - render the same built-in margin calibration sheet into the current directory unless `--out-dir` is set.
- `sim [options] [FILE...]` - short alias for `simulate`.
- `printer [list]` - list discovered CUPS queues. `printer` is an alias for `printer list`.
- `config check` - validate used config files and show source status.
- `config show` - show the effective merged config, including built-in defaults.
- `config edit` - open the local or global config in `$VISUAL`, `$EDITOR`, or `vi`, then validate it.
- `init` - create or refresh a config file from printer discovery.

Print options:

- `-d, --printer NAME` - use a specific CUPS queue.
- `-n, --copies N` - number of copies.
- `-o, --option KEY=VALUE` - add or override a CUPS option; repeatable.
- `--paper-mm N` - physical paper width in millimeters.
- `--printable-width-pt N` - printable width in points.
- `--stdin-as TYPE` - type for stdin document data: `pdf`, `png`, `jpg`, `jpeg`, `typ`, or `tex`.
- `--no-crop` - do not center-crop pages wider than printable width.
- `--dry-run` - show external commands without submitting the final print job.
- `-v, --version` - show the CLI version from `shard.yml`.
- `--help` - show usage help.

If no files are passed to the print command, `bon` fails with usage help. Use `-` to read from stdin. PDF, PNG, and JPEG stdin are auto-detected from binary signatures; pass `--stdin-as typ` or `--stdin-as tex` for Typst or LaTeX text stdin. When stdin is not typed and is not detected as binary document data, `bon` treats it as newline-delimited file paths if every non-empty line names an existing path. Stdin path lists are expanded in place, so they can be combined with normal CLI file arguments. Piped Typst document data is materialized in a temporary directory, so project-relative local assets are not available unless the input is self-contained; piped Typst paths keep their original location and asset access. Use `bon print margins` or `bon simulate margins` to calibrate visible margins with a shared Typst sheet that draws 1 mm ticks on a 10 mm margin page and a near-edge top/bottom margin page.

Simulate options:

- `-f, --format FORMAT` - output format, `png` or `pdf`.
- `--paper-mm N` - simulated physical paper width in millimeters.
- `--content-mm N` - override printed content width in millimeters.
- `--ppi N` - content render PPI and image physical-size PPI.
- `--mockup-ppi N` - final mockup image PPI.
- `--top-mm N` - paper shown above the printed content.
- `--bottom-mm N` - paper shown below the printed content.
- `--out-dir DIR` - directory for generated outputs.
- `--typst-bin PATH` - Typst executable to use.
- `--no-crop` - do not center-crop content wider than printable width.
- `--background-tint HEX` - paper background tint as `#RRGGBB` or `RRGGBB`.
- `--foreground-color HEX` - mockup foreground color as `#RRGGBB` or `RRGGBB`.
- `--foreground-fade N` - mockup foreground opacity from `0.0` to `1.0`.

Config options:

- `-g, --global` - with `config edit`, edit the global config instead of local `./bon.toml`.

Init options:

- `--global` - write the global config instead of local `./bon.toml`.
- `--force` - regenerate the config from the default template.
- `--no-interactive` - avoid prompting and use deterministic printer selection.

## Configuration

Config is merged in this order:

1. Built-in defaults.
2. Global config from `$XDG_CONFIG_HOME/bon.toml` or `~/.config/bon.toml`.
3. Local `./bon.toml` from the current working directory.
4. CLI flags.

The repository ships `config.default.toml` as the user-facing template; machine-specific `bon.toml` files should remain untracked.

Example generated config. Uncomment settings to override the built-in defaults:

```toml
[printer]
# Optional selected CUPS queue. Leave commented for automatic usable thermal discovery.
# name = "EPSON_TM_m30III"

[paper]
# width_mm = 80.0
# printable_width_pt = 0.0 # auto: 58 mm => 384 dots, 80 mm => 576 dots
# min_media_pt = 72.0
# max_media_height_pt = 5669.3

[render]
# typst_bin = "typst"
# typst_mode = "pdf"
# image_ppi = 203
# raster_ppi_multiplier = 2
# raster_threshold = 0.125
# raster_dither = "none"
# latex_engine = "auto"

[simulate]
# top_mm = 10.0
# bottom_mm = 14.0
# min_top_mm = 12.0
# min_bottom_mm = 2.0
# background_tint = "#f5f1e0"
# foreground_color = "#232320"
# foreground_fade = 1.0

[cups]
# copies = 1
# dry_run = false

[cups.options]
# Resolution = "203x203dpi"
# TmxPaperCut = "CutPerPage"
# TmxPaperReduction = "Top"

# Optional printer-scoped hardware overrides. Quote queue names containing dots.
# [printer.EPSON_TM_m30III.paper]
# width_mm = 80.0

# [printer."Queue.Name".render]
# image_ppi = 180

# [printer.EPSON_TM_m30III.cups.options]
# TmxPaperCut = "CutPerPage"
```

Local scalar keys override global scalar keys. `[cups]` contains bon-controlled CUPS behavior (`copies` maps to `lp -n`; `dry_run` suppresses job submission). `[cups.options]` contains arbitrary CUPS job or driver options that are passed as `lp -o KEY=VALUE`; options are merged by key, and setting an option to an empty string removes an inherited/default option. `paper.printable_width_pt = 0.0` automatically selects common thermal printable widths, including 384 dots for 58 mm paper and 576 dots for 80 mm paper at 203 dpi; set a positive point value to override it. Use an empty `printer.name` for automatic discovery, including to clear a global pinned printer from a local config.

`printer.candidates` is deprecated. Existing configs that contain it still load, but the key is ignored and CLI commands print a warning. Run `bon init` to remove it from `[printer]` while preserving unrelated config text.

Printer-scoped overrides apply only after a print queue has been selected. Supported override blocks are `[printer.<queue>.paper]`, `[printer.<queue>.render]` for `image_ppi`, and `[printer.<queue>.cups.options]`. Quote queue names that contain dots or other TOML punctuation, for example `[printer."Queue.Name".paper]`. `config show` remains offline-safe and displays the merged config without resolving CUPS queues or applying printer-scoped overrides.

`bon init` is safe to rerun. Without `--force`, it preserves comments, ordering, and unrelated settings, updates only `[printer] name`, and removes obsolete `[printer] candidates`. With `--force`, it regenerates from the default template. Non-interactive mode keeps an existing selected printer only if it is a usable thermal CUPS queue; otherwise it selects the first usable thermal queue, or leaves `printer.name` unset with a warning if none is found.

`render.typst_mode` is `pdf` by default, keeping Typst/LaTeX crop output as PDF; `raster` uses the Ghostscript raster/downsample path for Typst inputs that need cropping. Raster controls affect bon-generated raster/downsample paths, not direct CUPS pass-through files or PDF-first `pdfwrite` crops. Simulation vertical paper margins, color, and foreground settings live under `[simulate]`. The default simulated paper margins are `top_mm = 10.0` and `bottom_mm = 14.0`; the printer's technical minimum non-printable feed is modeled separately with `min_top_mm = 12.0` and `min_bottom_mm = 2.0`, so smaller configured margins are clamped in generated mockups.

## Print Pipeline

For each input, `bon`:

1. Creates a temporary working directory outside the project tree.
2. Resolves and validates path inputs, expands stdin `-` into newline-delimited paths when applicable, or materializes stdin document data into a typed temporary file before validation.
3. Converts Typst and LaTeX inputs to PDF.
4. Sends PNG/JPEG inputs directly to CUPS when they fit the printable width, based on `render.image_ppi`.
5. Scans discoverable PDF `/CropBox` and `/MediaBox` entries on a best-effort basis, or computes image physical size from pixels and PPI. This is not a full PDF parser, so compressed/object-stream page boxes may not be visible.
6. Fails if the document is wider than the physical paper width.
7. Center-crops pages wider than printable width unless `--no-crop` is set. Default PDF/Typst/LaTeX cropping uses Ghostscript `pdfwrite` and keeps the print artifact as PDF; `render.typst_mode = "raster"` uses the raster/downsample path for Typst crops, applying `render.raster_threshold` and `render.raster_dither`.
8. Splits multi-page PDFs into one temporary PDF per page so each page gets its own dynamic CUPS media height.
9. Fails if any final page height exceeds `paper.max_media_height_pt`.
10. Adds dynamic `media=Custom.<width>x<height>` unless media is already configured, and adds `ppi=<render.image_ppi>` unless explicitly overridden.
11. Runs `lp` with the configured queue, copies, options, and final page path.

`bon simulate` uses the same effective physical paper width, automatic or configured printable width, image PPI, and crop policy when rendering mockups. PNG inputs are read directly; JPEG inputs are rasterized through a temporary Typst wrapper so the project does not need an additional image-decoding dependency. The paper shown before and after the content comes from `[simulate] top_mm` / `[simulate] bottom_mm` or `--top-mm` / `--bottom-mm`, clamped by `[simulate] min_top_mm` / `[simulate] min_bottom_mm` to reflect the printer's physical minimum margins. The mockup paper tint comes from `[simulate] background_tint` or `--background-tint`; foreground color and opacity come from `[simulate] foreground_color` / `[simulate] foreground_fade` or their CLI flags. Multi-page Typst simulations write one mockup per page, for example `margins-page-001_<paper>mm-printout.<format>` and `margins-page-002_<paper>mm-printout.<format>` for `bon simulate margins`.

## Development

Repository-local example inputs live in `spec/fixtures/examples/`. They accompany the specs and cover supported input suffixes, 58 mm and 80 mm paper widths, variable-height multi-page documents, Typst, LaTeX, PDF, PNG, JPG, and JPEG paths.

Use `mise` so the same tool versions are used each time:

```sh
mise install
```

Pinned development tools:

- Crystal `1.20.2`
- git-cliff `latest`
- TinyTeX `2026.06`
- Typst `0.14.2`

Inside the project, mise prepends `./bin` to `PATH`, so `bon ...` resolves to the generated mise stub `bin/bon` and runs `crystal run src/bon.cr -- ...` from source. Production builds are written to `bin/bon-release`; `mise run install` copies that executable to `$HOME/.local/bin/bon`.

Smoke-test repository-local fixtures without submitting an `lp` job:

```sh
mise run run -- --dry-run spec/fixtures/examples/receipt-80mm.typ
mise run run -- simulate spec/fixtures/examples/receipt-80mm.typ spec/fixtures/examples/receipt.png
```

Exercise stdin handling with repository-local fixtures:

```sh
cat spec/fixtures/examples/variable-pages.pdf | mise run run -- --dry-run -
cat spec/fixtures/examples/receipt-80mm.typ | mise run run -- --dry-run --stdin-as typ -
printf '%s\n' spec/fixtures/examples/receipt-80mm.typ spec/fixtures/examples/receipt.tex | mise run run -- --dry-run -
```

Run specs:

```sh
mise run spec
```

Build the executable:

```sh
mise run build
```

Regenerate mise stubs after task changes:

```sh
mise generate task-stubs
```

## Release Process

`shard.yml` is the single version source. Release helpers live in `bin/release-*`, use mise-pinned tools internally, and publish through CI after an annotated `v<version>` tag is pushed.

Prepare a release from a clean working tree:

```sh
bin/release-prepare 0.2.0
```

This updates `shard.yml` and prepends a generated `CHANGELOG.md` section. The changelog generator uses `git-cliff` without Conventional Commit parsing, so it emits a flat commit list that must be rewritten into user-facing release notes before tagging.

Validate the release candidate:

```sh
bin/release-check
```

Commit the release files, merge them to `main`, then create the release tag from the release commit:

```sh
bin/release-tag 0.2.0
git push origin v0.2.0
```

CI verifies that the pushed tag matches `shard.yml`, builds release archives, includes `CHANGELOG.md` in each archive, and publishes the matching changelog section as the GitHub release body.

The implementation intentionally avoids shard dependencies. Crystal source lives under `src/`, and specs live under `spec/`.
