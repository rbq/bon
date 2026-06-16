# Plan: `bon simulate` Image Mockups and Help/Docs

## Goal

Make `bon simulate` visible in CLI help and README, add `bon sim` as a shorter alias, support mockup generation for supported image inputs (`.png`, `.jpg`, `.jpeg`) as well as Typst documents, and make mockups better reflect effective paper width, automatic printable width, crop behavior, and configurable paper/background tint.

## Current State

- `src/bon/cli.cr` dispatches `simulate`, but root help only documents `print`, `printer`, and `config`.
- `simulate` has its own help banner, but no `sim` alias.
- `src/bon/simulate.cr` only accepts `.typ`, defaults to `*.typ`, and errors with Typst-specific messages.
- Simulation already uses config-derived `paper.width_mm`, `render.image_ppi`, and `render.typst_bin`.
- Simulation does not use `paper.printable_width_pt` and therefore does not mirror automatic/configured printable-width cropping.
- PNG read/write code exists in both `Image` and `Simulate`; JPEG dimensions exist, but JPEG pixels are not decoded without Typst.
- Config currently has no simulation-specific table or color/tint option.

## Implementation Steps

1. Update CLI dispatch and root help in `src/bon/cli.cr`.
   - Treat `sim` as an alias for `simulate` in `dispatch`.
   - Update the root usage banner to include `bon simulate [options] [FILE...]` and `bon sim [options] [FILE...]`.
   - Add `simulate` and `sim` to the root command list.
   - While touching root help, include existing `init` since it is an implemented command and AGENTS.md requires help for every command.
   - Update simulate help banner to show the alias, e.g. `Usage: bon simulate|sim [options] [FILE...]`.

2. Extend simulation options and validation.
   - Add effective `printable_width_pt` or `printable_width_mm` to `Simulate::Options`, initialized from `config.printable_width_pt` in `run_simulate`.
   - Add `no_crop : Bool` to `Simulate::Options` and expose `--no-crop` for parity with printing.
   - Keep `--content-mm` as an explicit override, but make the default path use effective printable width when cropping applies.
   - Add `background_tint : String` or parsed RGB to `Simulate::Options`, populated from config and overridden by a new `--background-tint=HEX` CLI flag.
   - Validate positive dimensions and validate the tint as `#RRGGBB` or `RRGGBB`.

3. Add simulation config schema.
   - Add `Config#simulate_background_tint`, defaulting to the existing `Simulate::PAPER_RGB` equivalent `#f5f1e0`.
   - Add `[simulate] background_tint = "#f5f1e0"` to `Config#build_toml`.
   - Add `simulate.background_tint` support to `Config#overlay`.
   - Add validation for hex RGB values in `Config#validate!`.
   - Keep the TOML parser unchanged by using a string value rather than adding integer-array support.

4. Generalize `src/bon/simulate.cr` input handling.
   - Change `render_sources` error from `No Typst sources found` to `No simulation inputs found`.
   - Change `default_sources` to include `*.typ`, `*.png`, `*.jpg`, and `*.jpeg`, sorted.
   - Change source validation to accept Typst and supported image suffixes, reusing the same suffix set or equivalent image predicate.
   - Change `output_path` to strip the actual extension instead of always `.typ`.

5. Make image simulation accurate enough for print behavior.
   - For PNG inputs, read the raster directly.
   - For JPEG inputs, create a temporary Typst wrapper using existing image physical-size logic and render it to PNG with `typst compile -f png --ppi <render.image_ppi>`; this avoids adding image-decoding dependencies.
   - Determine source physical width:
     - Typst: existing page-width extraction fallback to physical paper width.
     - Image: `Image.page_size(source, config.image_ppi).width` converted from points to mm.
   - Enforce the same physical-paper check used by print prep: source width must not exceed `paper.width_mm`.
   - Determine printed content width:
     - If `--content-mm` is provided, use it after validation.
     - Else if `--no-crop` or source width fits printable width, use source width.
     - Else use configured/automatic printable width.
   - Update `simulate_png` to center-crop the source raster when printed content width is smaller than source width, instead of scaling the whole image down horizontally.
   - Preserve current top/bottom paper margin behavior and noise/thermal rendering effect.

6. Make background tint configurable in rendering.
   - Replace hardcoded `PAPER_RGB` use in `paper_pixel` with an RGB passed through from options.
   - Parse tint once before rendering each source or on options construction.
   - Keep edge shadow/fiber/noise behavior but apply it relative to the configured base tint.

7. Update docs and agent notes.
   - README CLI usage block: include `simulate`, `sim`, `config edit`, and `init` so it matches actual help.
   - README commands: document `simulate [options] [FILE...]` and `sim` alias, including supported `.typ`, `.png`, `.jpg`, `.jpeg` inputs.
   - README simulate options: document `--format`, `--paper-mm`, `--content-mm`, `--ppi`, `--mockup-ppi`, `--top-mm`, `--bottom-mm`, `--out-dir`, `--typst-bin`, `--no-crop`, and `--background-tint`.
   - README config example: add `[simulate] background_tint = "#f5f1e0"`.
   - README Print Pipeline: add a short simulation pipeline note explaining that mockups use effective paper width, automatic/configured printable width, image PPI, and crop policy.
   - AGENTS.md Implementation Notes: record that simulation supports Typst and PNG/JPEG, uses Typst for JPEG rasterization, and applies configured paper/printable width/crop/tint settings.

8. Add or update specs.
   - `spec/cli_spec.cr`: root help includes `simulate`, `sim`, and `init`.
   - `spec/simulate_spec.cr`: `bon sim` invokes simulation and writes output.
   - `spec/simulate_spec.cr`: PNG input can be simulated without Typst.
   - `spec/simulate_spec.cr`: default source discovery includes images.
   - `spec/simulate_spec.cr`: configured `paper.width_mm` and automatic `paper.printable_width_pt` affect output dimensions/cropping.
   - `spec/simulate_spec.cr` or `spec/config_spec.cr`: `simulate.background_tint` is accepted, emitted by config show/default TOML, and invalid values are rejected.
   - Optional: JPEG simulation test using a fake Typst binary and wrapper output, focused on command path rather than full JPEG decoding.

9. Verification.
   - Run `mise run spec`.
   - Run `mise run build`.
   - Run focused manual help checks:
     - `mise run run -- --help`
     - `mise run run -- simulate --help`
     - `mise run run -- sim --help`
   - Run a dry simulation for a small PNG fixture if available or generated by a spec/helper outside the repo temp tree.

## Notes and Tradeoffs

- Scope image support to project-supported image inputs (`.png`, `.jpg`, `.jpeg`) rather than arbitrary image formats, matching `Document::SUPPORTED_SUFFIXES` and README requirements.
- Use a string hex color for tint to avoid expanding the custom TOML parser beyond the existing scalar needs.
- Use Typst for JPEG rasterization because the project already depends on Typst for Typst inputs and image center-crop fallback; adding a JPEG decoder or ImageMagick dependency would violate the dependency-light guidance.
- The simulation will approximate CUPS/thermal output, not reproduce a printer driver byte-for-byte. The important behavior to align is physical paper width, printable-width cropping, image PPI, and paper tint.
