#!/usr/bin/env bash
#
# Compares the versions deps/build-deps.zsh pins with the latest releases of
# those projects, as a Markdown table. With --updates-only it shows only the
# projects with a newer release, and nothing when everything is current.
# Needs the GitHub CLI (gh), logged in or with GH_TOKEN set.
#
# Updating stays a deliberate change: the new version and its SHA-256 go in
# build-deps.zsh, and CI builds and tests it.

cd "$(dirname "$0")" || exit 1

pinned() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" build-deps.zsh; }
latest_release() { gh api "repos/$1/releases/latest" --jq .tag_name; }
# True when $2 is a higher version than $1.
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]; }

only_updates=0
[[ "$1" == "--updates-only" ]] && only_updates=1
rows=""

# check <name> <pinned> <latest> <where the releases are>
check() {
  if [[ -z "$3" ]]; then
    rows+="| $1 | $2 | ? | could not check | $4 |"$'\n'
  elif newer "$2" "$3"; then
    rows+="| $1 | $2 | $3 | **newer release** | $4 |"$'\n'
  elif (( ! only_updates )); then
    rows+="| $1 | $2 | $3 | current | $4 |"$'\n'
  fi
}

check FreeRDP "$(pinned FREERDP_VERSION)" "$(latest_release FreeRDP/FreeRDP)" \
  https://github.com/FreeRDP/FreeRDP/releases
check OpenSSL "$(pinned OPENSSL_VERSION)" "$(latest_release openssl/openssl | sed 's/^openssl-//')" \
  https://github.com/openssl/openssl/releases
# Security fixes come as patch releases in the same series: 3.6.x for 3.6.5.
openssl_series="$(pinned OPENSSL_VERSION | cut -d. -f1-2)"
check "OpenSSL $openssl_series.x" "$(pinned OPENSSL_VERSION)" \
  "$(git ls-remote --tags --refs https://github.com/openssl/openssl.git "refs/tags/openssl-$openssl_series.*" |
     sed 's|.*refs/tags/openssl-||' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)" \
  https://github.com/openssl/openssl/releases
check SwiftTerm "$(pinned SWIFTTERM_VERSION)" "$(latest_release migueldeicaza/SwiftTerm | sed 's/^v//')" \
  https://github.com/migueldeicaza/SwiftTerm/releases
check CMake "$(pinned CMAKE_VERSION)" "$(latest_release Kitware/CMake | sed 's/^v//')" \
  https://github.com/Kitware/CMake/releases

[[ -z "$rows" ]] && exit 0
echo "| Project | Pinned | Latest | | Releases |"
echo "|---|---|---|---|---|"
printf '%s' "$rows"
