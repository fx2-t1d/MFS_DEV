#!/bin/sh
# Rebuilds Sources/Resources/oref.bundle.js: openaps/oref0 (MIT) + adapter.js as one script that
# defines the global predict(requestJSON) used by JavaScriptPredictionTransport.
# Needs node and git. Bump OREF0_COMMIT to update oref0.
set -eu
OREF0_COMMIT=88cf032aa74ff25f69464a7d9cd601ee3940c0b3
here=$(cd "$(dirname "$0")" && pwd)
work="$here/.build"
mkdir -p "$work"
if [ ! -d "$work/oref0" ]; then
  git clone -q https://github.com/openaps/oref0 "$work/oref0"
fi
git -C "$work/oref0" checkout -q "$OREF0_COMMIT"
cd "$here"
npm install --no-audit --no-fund --silent
mkdir -p ../../Sources/Resources
# moment-timezone is only used to parse ISO timestamps, which plain moment does too; this avoids its large zone data.
NODE_PATH="$here/node_modules" npx esbuild adapter.js --bundle --minify --format=iife --platform=neutral --main-fields=main \
  --alias:oref0="$work/oref0" --alias:moment-timezone=moment \
  --banner:js='if(typeof console==="undefined"){var console={log:function(){},error:function(){},warn:function(){}}}if(typeof process==="undefined"){var process={env:{},stderr:{write:function(){}},stdout:{write:function(){}}}}' \
  --outfile=../../Sources/Resources/oref.bundle.js
echo "Built Sources/Resources/oref.bundle.js"
