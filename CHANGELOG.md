# Changelog

## [0.1.5] - 2026-06-22

- Added PDF input support to `bon simulate`, including page-by-page rasterization for multi-page PDFs.
- Added shorter aliases for common commands and flags.
- Updated configuration lookup paths and related CLI/docs behavior.
- Added release automation for publishing the Homebrew formula when GitHub releases are published.

## [0.1.4] - 2026-06-22

- Improved the README for installed users with a clearer installation note, first-run configuration flow, printer selection guidance, simulation examples, and printing examples that use user-owned files instead of repository fixtures.

## [0.1.3] - 2026-06-22

- Added file path input support through both CLI arguments and newline-delimited stdin path lists.
- Documented the final release publishing confirmation step after creating an annotated tag.


## [0.1.2] - 2026-06-22

- Added stdin print input support, including explicit stdin type handling for document pipelines.
- Added margin calibration commands for printing and simulating receipt-printer margin test pages.
- Improved configuration initialization, printer discovery, generated config defaults, and the tracked default config template.
- Refined example fixtures so repository-local smoke inputs better match supported printable-width behavior.
- Added local release helper scripts and GitHub release publishing workflow support.

## [0.1.0] - 2026-06-21

- Initial receipt-printer CLI release with PDF, image, Typst, and LaTeX print preparation through CUPS.
