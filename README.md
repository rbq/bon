# bon

`bon` is a Crystal CLI for printing receipt-sized documents through CUPS/`lp`. It accepts PDF, PNG, JPEG, Typst, and LaTeX files, converts inputs to a temporary PDF only when needed, applies receipt-printer width handling, and sends the final document to a discovered or configured thermal printer.

## Requirements

Use `mise` so the same tool versions are used each time:

```sh
mise install
```

Pinned development tools:

- Crystal `1.20.2`
- Typst `0.14.2`

Runtime tools:

- CUPS commands: `lpstat` and `lp`
- Ghostscript `gs` when center-cropping/rasterizing to printer dots is needed
- Typst for `.typ` inputs, JPEG simulation, and image inputs that need center-cropping
- Optional LaTeX tools for `.tex` inputs: `latexmk`, `tectonic`, or `pdflatex`

## Usage

List CUPS queues:

```sh
mise run run -- printer list
```

Dry-run a Typst receipt without submitting an `lp` job:

```sh
mise run run -- --dry-run ../Wetterbericht.typ
```

Print one or more files:

```sh
mise run run -- receipt.pdf image.png source.typ paper.tex
```

Validate and inspect configuration:

```sh
mise run run -- config check
mise run run -- config show
mise run run -- config edit
```

Render a receipt mockup:

```sh
mise run run -- simulate receipt.typ image.png
mise run run -- sim receipt.jpg
```

Build the executable and run it directly:

```sh
mise run build
bin/bon --dry-run ../Wetterbericht.typ
```

## CLI

```text
Usage: bon [print] [options] FILE...
       bon simulate [options] [FILE...]
       bon sim [options] [FILE...]
       bon printer [list]
       bon config <check|show|edit>
       bon init [options]
```

Commands:

- `print [options] FILE...` - print one or more files. This is the default command, so `bon FILE...` also works.
- `simulate [options] [FILE...]` - render receipt mockups for `.typ`, `.png`, `.jpg`, and `.jpeg` inputs. If no files are passed, matching inputs in the current directory are used.
- `sim [options] [FILE...]` - short alias for `simulate`.
- `printer [list]` - list discovered CUPS queues. `printer` is an alias for `printer list`.
- `config check` - validate used config files and show source status.
- `config show` - show the effective merged config, including built-in defaults.
- `config edit` - open the local or global config in `$VISUAL`, `$EDITOR`, or `vi`, then validate it.
- `init` - write a default config file.

Print options:

- `-d, --printer NAME` - use a specific CUPS queue.
- `-n, --copies N` - number of copies.
- `-o, --option KEY=VALUE` - add or override a CUPS option; repeatable.
- `--paper-mm N` - physical paper width in millimeters.
- `--printable-width-pt N` - printable width in points.
- `--no-crop` - do not center-crop pages wider than printable width.
- `--dry-run` - show external commands without submitting the final print job.
- `--version` - show the CLI version.
- `--help` - show usage help.

If no files are passed to the print command, `bon` fails with usage help.

Simulate options:

- `-f, --format FORMAT` - output format, for example `png` or `pdf`.
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

## Configuration

Config is merged in this order:

1. Built-in defaults.
2. Global config from `$XDG_CONFIG_HOME/bon/config.toml` or `~/.config/bon/config.toml`.
3. Local `./config.toml` from the current working directory.
4. CLI flags.

While this project still lives inside the Bondrucker workspace, `./bon/config.toml` is also supported as a transition fallback when no local `./config.toml` exists.

Example:

```toml
[printer]
name = ""
candidates = ["EPSON_TM_m30III", "EPSON_TM_m30III__USB_"]

[paper]
width_mm = 80.0
printable_width_pt = 0.0 # auto: 58 mm => 384 dots, 80 mm => 576 dots
min_media_pt = 72.0
max_media_height_pt = 5669.3

[render]
typst_bin = "typst"
typst_mode = "pdf"
image_ppi = 203
raster_ppi_multiplier = 2
latex_engine = "auto"

[simulate]
background_tint = "#f5f1e0"
foreground_color = "#232320"
foreground_fade = 1.0

[cups]
copies = 1
dry_run = false

[cups.options]
Resolution = "203x203dpi"
TmxPaperCut = "CutPerPage"
TmxPaperReduction = "Off"
```

Local scalar keys override global scalar keys. Local `printer.candidates` replaces the global list. `[cups]` contains bon-controlled CUPS behavior (`copies` maps to `lp -n`; `dry_run` suppresses job submission). `[cups.options]` contains arbitrary CUPS job or driver options that are passed as `lp -o KEY=VALUE`; options are merged by key, and setting an option to an empty string removes an inherited/default option. `paper.printable_width_pt = 0.0` automatically selects common thermal printable widths, including 384 dots for 58 mm paper and 576 dots for 80 mm paper at 203 dpi; set a positive point value to override it. `simulate.background_tint` controls mockup paper color and accepts `#RRGGBB` or `RRGGBB`. `simulate.foreground_color` and `simulate.foreground_fade` control the mockup ink color and opacity while preserving the current look at their defaults. `TmxPaperCut = "CutPerPage"` asks supported thermal printers to cut after each page; change it to `CutPerJob` or `NoCut`, or set it to an empty string to omit that driver option. Use an empty `printer.name` for automatic discovery, including to clear a global pinned printer from a local config. During automatic discovery, non-USB queues are preferred because CUPS can keep disconnected USB queues enabled and idle; set `printer.name` or pass `--printer` to force a specific queue.

## Print Pipeline

For each input, `bon`:

1. Resolves and validates the path.
2. Creates a temporary working directory outside the project tree.
3. Converts Typst and LaTeX inputs to PDF.
4. Sends PNG/JPEG inputs directly to CUPS when they fit the printable width, based on `render.image_ppi`.
5. Reads the PDF first page `/CropBox` or `/MediaBox`, or computes image physical size from pixels and PPI.
6. Fails if the document is wider than the physical paper width.
7. Center-crops pages wider than printable width unless `--no-crop` is set. Cropped PDFs are rasterized at `render.image_ppi * render.raster_ppi_multiplier`, then downsampled to a 1-bit PNG at native `render.image_ppi`, with dimensions verified before printing.
8. Adds dynamic `media=Custom.<width>x<height>` unless media is already configured, and adds `ppi=<render.image_ppi>` unless explicitly overridden.
9. Runs `lp` with the configured queue, copies, options, and final document path.

`bon simulate` uses the same effective physical paper width, automatic or configured printable width, image PPI, and crop policy when rendering mockups. PNG inputs are read directly; JPEG inputs are rasterized through a temporary Typst wrapper so the project does not need an additional image-decoding dependency. The mockup paper tint comes from `[simulate] background_tint` or `--background-tint`; foreground color and opacity come from `[simulate] foreground_color` / `[simulate] foreground_fade` or their CLI flags.

## Development

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

The implementation intentionally avoids shard dependencies. Crystal source lives under `src/`, and specs live under `spec/`.
