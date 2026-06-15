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
- Typst for `.typ` inputs and image inputs that need center-cropping
- Optional LaTeX tools for `.tex` inputs: `latexmk`, `tectonic`, or `pdflatex`

## Usage

List CUPS queues:

```sh
mise run run -- --list-printers
```

Dry-run a Typst receipt without submitting an `lp` job:

```sh
mise run run -- --dry-run ../Wetterbericht.typ
```

Print one or more files:

```sh
mise run run -- receipt.pdf image.png source.typ paper.tex
```

Build the executable and run it directly:

```sh
mise run build
bin/bon --dry-run ../Wetterbericht.typ
```

## CLI

```text
Usage: bon [options] FILE...
```

Options:

- `-d, --printer NAME` - use a specific CUPS queue.
- `-n, --copies N` - number of copies.
- `-o, --option KEY=VALUE` - add or override a CUPS option; repeatable.
- `--paper-mm N` - physical paper width in millimeters.
- `--printable-width-pt N` - printable width in points.
- `--no-crop` - do not center-crop pages wider than printable width.
- `--dry-run` - show external commands without submitting the final print job.
- `--list-printers` - list discovered CUPS queues.
- `--version` - show the CLI version.
- `--help` - show usage help.

If no files are passed and `--list-printers` is not set, `bon` fails with usage help.

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
name = "EPSON_TM_m30III__USB_"
candidates = ["EPSON_TM_m30III__USB_", "EPSON_TM_m30III"]

[paper]
width_mm = 80.0
printable_width_pt = 204.3
min_media_pt = 72.0
max_media_height_pt = 5669.3

[render]
typst_bin = "typst"
image_ppi = 203
raster_ppi_multiplier = 2
latex_engine = "auto"

[cups]
copies = 1
dry_run = false

[cups.options]
Resolution = "203x203dpi"
TmxPaperCut = "CutPerJob"
TmxPaperReduction = "Off"
```

Local scalar keys override global scalar keys. Local `printer.candidates` replaces the global list. CUPS options are merged by key.

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
