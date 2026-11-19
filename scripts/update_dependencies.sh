#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Select at least one dependency." >&2
  exit 1
fi

for dependency in "$@"; do
  case "$dependency" in
    LoopKit|G7SensorKit|OmnipodKit|RileyLinkKit)
      git -C "$dependency" fetch origin HEAD
      git -C "$dependency" checkout --detach FETCH_HEAD
      git -C "$dependency" submodule update --init --recursive
      ;;
    fastlane)
      latest=$(curl -fsS https://rubygems.org/api/v1/versions/fastlane/latest.json | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("version")')
      ruby - "$latest" <<'RUBY'
version = ARGV.fetch(0)
abort "Invalid fastlane version" unless version.match?(/\A\d+(?:\.\d+)+\z/)
contents = File.read("Gemfile")
pattern = /^([ \t]*gem[ \t]+["']fastlane["'][ \t]*,[ \t]*)["'][^"']+["'][ \t]*$/
abort "Expected exactly one pinned fastlane entry in Gemfile" unless contents.scan(pattern).length == 1
updated = contents.gsub(pattern, "\\1\"#{version}\"")
File.write("Gemfile", updated)
RUBY
      ;;
    *)
      echo "Unsupported dependency: $dependency" >&2
      exit 1
      ;;
  esac
done
