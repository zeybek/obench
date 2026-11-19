#!/usr/bin/env bash
# Builds the HTML package documentation into build/docs with the generator behind
# pkg.odin-lang.org (https://github.com/odin-lang/pkg.odin-lang.org), which must be on PATH
# as `odin-doc`. The settings are in scripts/odin-doc.json. Used by `make docs` and
# .github/workflows/docs.yml.
set -euo pipefail

# Where the pages are published.
DOCS_URL="${DOCS_URL:-https://zeybek.github.io/obench}"

cd "$(dirname "$0")/.."
rm -rf build/docs build/obench.odin-doc
mkdir -p build/docs

odin doc obench -all-packages -doc-format -out:build/obench.odin-doc

cd build/docs
odin-doc ../obench.odin-doc ../../scripts/odin-doc.json
rm ../obench.odin-doc

# odin-doc writes its pages for pkg.odin-lang.org: the titles name that site, the package at
# the collection root gets an empty name, and the home page describes Odin's own collections.
# robots.txt only counts at the root of a host, so a project site's copy is never read.
rm -f robots.txt
pages=()
while IFS= read -r page; do pages+=("$page"); done < <(find . -name '*.html' | LC_ALL=C sort)
perl -pi -e '
  s/ - pkg\.odin-lang\.org/ - obench docs/g;
  s/package {1,2}- obench docs/package obench - obench docs/g;
  s/Packages - obench docs/obench - allocation-aware micro-benchmarking for Odin/g;
  s/Browse API documentation for the Odin base, core, and vendor library collections\./Allocation-aware micro-benchmarking for Odin./g;
' "${pages[@]}"

# Every page but the 404 and the documentation report gets a canonical link and a sitemap entry.
lastmod="$(date -u +%Y-%m-%d)"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  for page in "${pages[@]}"; do
    case "$page" in ./404.html | ./report/*) continue ;; esac
    path="${page#.}"
    url="$DOCS_URL${path%index.html}"
    # shellcheck disable=SC2016 # $ENV{URL} is Perl, read from the environment.
    URL="$url" perl -pi -e 's{</head>}{<link rel="canonical" href="$ENV{URL}">\n</head>}' "$page"
    printf '\t<url><loc>%s</loc><lastmod>%s</lastmod></url>\n' "$url" "$lastmod"
  done
  echo '</urlset>'
} > sitemap.xml
