This directory contains small, repository-local inputs used by specs and manual smoke tests.

Text fixtures keep their own content inside bon's default thermal printable widths so smoke-test prints do not lose content to the mandatory side crop. Use at least `4mm` horizontal margins for 80 mm paper and `5mm` horizontal margins for 58 mm paper unless the fixture is intentionally testing crop behavior.

- `receipt-80mm.typ` covers the default 80 mm receipt paper path.
- `label-58mm.typ` covers narrower 58 mm paper.
- `variable-pages.typ` and `variable-pages.pdf` cover multiple pages with different heights in one input.
- `receipt.tex` covers LaTeX input conversion.
- `receipt.png`, `receipt.jpg`, and `receipt.jpeg` cover supported image input suffixes.

These files are inputs only. Generated print PDFs, mockups, and temporary intermediates should stay outside the project tree.

Stdin smoke tests can reuse these fixtures without adding generated files:

```sh
cat spec/fixtures/examples/variable-pages.pdf | mise run run -- --dry-run -
cat spec/fixtures/examples/receipt-80mm.typ | mise run run -- --dry-run --stdin-format typ -
printf '%s\n' spec/fixtures/examples/receipt-80mm.typ spec/fixtures/examples/receipt.tex | mise run run -- --dry-run -
```
