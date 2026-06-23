# Homebrew Tap Automation Notes

This project publishes `bon` through the private tap repository `rbq/homebrew-tap`. The release flow renders `.homebrew/bon.rb.erb` from `.github/workflows/homebrew-tap.yml`, commits the generated formula to `Formula/bon.rb` in the tap, and then downstream tap validation runs `brew style`, `brew readall`, and `brew audit`.

These notes capture the release issues found during `v0.1.7` so the same mistakes can be avoided in future projects.

## Formula Version

Do not add an explicit `version` line when the stable source URL already contains a version-like tag.

Homebrew can infer `0.1.7` from a URL such as:

```ruby
url "https://github.com/rbq/bon/archive/refs/tags/v0.1.7.tar.gz"
```

Adding this line is redundant and fails tap audit:

```ruby
version "0.1.7"
```

Observed failure:

```text
Stable: `version 0.1.7` is redundant with version scanned from URL
```

It can also trigger component-order style failures if placed after `sha256`:

```text
FormulaAudit/ComponentsOrder: version should be put before sha256
```

Preferred formula header:

```ruby
class Bon < Formula
  desc "Receipt-printer CLI for PDFs, images, Typst, and LaTeX"
  homepage "https://github.com/rbq/bon"
  url "https://github.com/rbq/bon/archive/refs/tags/v0.1.7.tar.gz"
  sha256 "..."
  license "MIT"
end
```

## Archive Checksums

Hash exactly the same URL that the formula publishes.

The `v0.1.7` workflow originally wrote this URL into the formula:

```text
https://github.com/rbq/bon/archive/refs/tags/v0.1.7.tar.gz
```

But it computed the SHA-256 from this API endpoint:

```text
https://api.github.com/repos/rbq/bon/tarball/v0.1.7
```

Those endpoints produce different tar streams, so Homebrew rejected installation with a checksum mismatch.

Observed failure:

```text
Error: Formula reports different checksum:  a658a84727e83115ff2c07ba7b6db81405cd0001ac52489cec02c39bc4aaeb53
       SHA-256 checksum of downloaded file: c6a6e16fe1359b04a4d4786654a0aba7c7e8290b34bb3df38d8e44a02e658089
```

Correct pattern:

```sh
archive_url="https://github.com/${GITHUB_REPOSITORY}/archive/refs/tags/${tag}.tar.gz"
curl --fail --location --silent --show-error --retry 5 --retry-delay 2 --retry-all-errors \
  "$archive_url" \
  --output dist/source.tar.gz
sha256="$(shasum -a 256 dist/source.tar.gz | cut -d ' ' -f 1)"
```

Then render both `url` and `sha256` from those exact values.

## Token And Repository Access

The tap workflow needs a token that can read and write the tap repository. Validate access before rendering or checking out the tap so missing or under-scoped credentials fail early.

Current pattern:

```sh
if [[ -z "${HOMEBREW_TAP_TOKEN}" ]]; then
  echo "HOMEBREW_TAP_TOKEN is not configured."
  exit 1
fi

curl \
  --fail \
  --silent \
  --show-error \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${HOMEBREW_TAP_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${HOMEBREW_TAP_REPOSITORY}" \
  >/dev/null
```

## Build Output Directory

Create the formula `bin` directory before compiling directly to `bin/"bon"`.

Crystal passes the `-o` path through to the linker, and the linker does not create missing parent directories. Homebrew can therefore fail during `brew install` with:

```text
ld: open() failed, errno=2 (No such file or directory) for '/opt/homebrew/Cellar/bon/0.1.7/bin/bon'
```

Correct pattern:

```ruby
def install
  bin.mkpath
  system "crystal", "build", "src/bon.cr", "--release", "--no-debug", "-o", bin/"bon"
end
```

## Reusable Workflow Shape

Keep tap publication manually retryable. The `homebrew-tap.yml` workflow should support both:

- `workflow_call` from the release workflow, with a required `tag` input.
- `workflow_dispatch`, with the same required `tag` input.

This allows a failed tap update to be fixed on `main` and retried for an already-published release tag without retagging or rewriting release history.

## Retry Procedure

When tap publication fails after a GitHub release is already published:

1. Fix the formula template or tap workflow on `main`.
2. Commit and push the fix to `main`.
3. Rerun the tap workflow manually with the existing release tag, for example `v0.1.7`.
4. Do not recreate, move, or force-push the release tag.
5. Verify the tap formula from `https://raw.githubusercontent.com/<owner>/homebrew-tap/main/Formula/<name>.rb`.
6. If possible, run `brew install <owner>/tap/<name>` or `brew fetch <owner>/tap/<name>` to confirm the published checksum.

## Validation Checklist

Before relying on tap automation in a new project:

1. Render the formula locally from the same template and environment variables used by CI.
2. Run `ruby -c` on the rendered formula.
3. Confirm there is no explicit `version` line if the URL contains a tag version.
4. Download the exact formula `url` and compute `shasum -a 256` from that file.
5. Confirm the rendered `sha256` matches that file.
6. Run the tap validation used by the tap repository, especially `brew style`, `brew readall --aliases --os=all --arch=all <owner>/tap`, and `brew audit --except=installed --tap=<owner>/tap`.
7. Keep the tap workflow manually dispatchable for retries.

## Current Project Reference

For `bon`, the authoritative pieces are:

- `.homebrew/bon.rb.erb` - formula template.
- `.github/workflows/homebrew-tap.yml` - reusable and manually dispatchable tap publisher.
- `.github/workflows/release.yml` - GitHub release publisher that calls the tap workflow after release publication.
- `HOMEBREW_TAP_TOKEN` - secret used to access `rbq/homebrew-tap`.

The `v0.1.7` corrected formula used:

```ruby
url "https://github.com/rbq/bon/archive/refs/tags/v0.1.7.tar.gz"
sha256 "c6a6e16fe1359b04a4d4786654a0aba7c7e8290b34bb3df38d8e44a02e658089"
```
