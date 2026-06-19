This directory contains small, repository-local inputs used by specs and manual smoke tests.

- `receipt-80mm.typ` covers the default 80 mm receipt paper path.
- `label-58mm.typ` covers narrower 58 mm paper.
- `variable-pages.typ` and `variable-pages.pdf` cover multiple pages with different heights in one input.
- `receipt.tex` covers LaTeX input conversion.
- `receipt.png`, `receipt.jpg`, and `receipt.jpeg` cover supported image input suffixes.

These files are inputs only. Generated print PDFs, mockups, and temporary intermediates should stay outside the project tree.

Stdin smoke tests can reuse these fixtures without adding generated files:

```sh
cat examples/spec/variable-pages.pdf | mise run run -- --dry-run -
cat examples/spec/receipt-80mm.typ | mise run run -- --dry-run --stdin-as typ -
```
