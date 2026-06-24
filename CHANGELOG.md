# Changelog

## [0.1.9] - 2026-06-24

- Added `bon web`, an upload server for printing supported documents from a browser form or JSON client. Uploads use the same print pipeline as the CLI, support optional token authentication, and serialize print batches in-process.
- Improved the web upload UI and routing with Kemal and ECR templates.
- Added Homebrew bottle publication for macOS ARM, macOS x64, and Linux x64 so matching Homebrew installs can use prebuilt packages while retaining source-build fallback.
- Fixed clean CI, local build tasks, and Homebrew source builds by installing Crystal shard dependencies before compiling or testing.
- Fixed Homebrew tap automation issues around formula version audit rules, release archive checksums, and formula build output paths.
- Updated GitHub Actions versions used by CI and release workflows.

## [0.1.8] - 2026-06-24

- Added `bon web`, an upload server for printing supported documents from a browser form or JSON client. Uploads use the same print pipeline as the CLI, support optional token authentication, and serialize print batches in-process.
- Improved the web upload UI and routing with Kemal and ECR templates.
- Added Homebrew bottle publication for macOS ARM, macOS x64, and Linux x64 so matching Homebrew installs can use prebuilt packages while retaining source-build fallback.
- Fixed Homebrew tap automation issues around formula version audit rules, release archive checksums, and formula build output paths.
- Updated GitHub Actions versions used by CI and release workflows.

## [0.1.7] - 2026-06-23

- Fixed Homebrew tap release automation so published releases can update `rbq/tap/bon` reliably.
- Documented Homebrew installation with `brew install rbq/tap/bon`.
- Added a local `mise run uninstall`/`bin/uninstall` helper that asks before removing only `$HOME/.local/bin/bon` and leaves package-manager installs untouched.
- Added confirmation before local `mise run install` overwrites or installs `$HOME/.local/bin/bon`.

## [0.1.6] - 2026-06-22

- Fixed release automation so tag builds publish the GitHub release and then update the Homebrew tap through reusable workflows.

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
