# Changelog

Release notes are intentionally curated manually. `bin/release-notes <version>` prepends a flat commit list generated from Git history; rewrite that section into user-facing notes before tagging.

## [0.1.2] - 2026-06-22

- Added stdin print input support, including explicit stdin type handling for document pipelines.
- Added margin calibration commands for printing and simulating receipt-printer margin test pages.
- Improved configuration initialization, printer discovery, generated config defaults, and the tracked default config template.
- Refined example fixtures so repository-local smoke inputs better match supported printable-width behavior.
- Added local release helper scripts and GitHub release publishing workflow support.

## [0.1.0] - 2026-06-21

- Initial receipt-printer CLI release with PDF, image, Typst, and LaTeX print preparation through CUPS.
