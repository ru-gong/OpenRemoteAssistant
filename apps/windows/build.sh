#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Windows Git Bash wrapper; inherit the caller's environment.
set -euo pipefail
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v cygpath >/dev/null; then
  echo 'Run this script in Windows Git Bash, or use build.ps1 on Windows.' >&2
  exit 2
fi
dotnet_cmd="${DOTNET_EXECUTABLE:-dotnet}"
win_root="$(cygpath -w "$source_root")"
case "${1:-build}" in
  build)
    "$dotnet_cmd" build "$win_root\src\OpenRemoteAssistant.Win\OpenRemoteAssistant.Win.csproj" -c "${2:-Debug}" ;;
  test)
    "$dotnet_cmd" test "$win_root\tests\OpenRemoteAssistant.Tests\OpenRemoteAssistant.Tests.csproj" -c "${2:-Debug}" ;;
  publish)
    "$dotnet_cmd" publish "$win_root\src\OpenRemoteAssistant.Win\OpenRemoteAssistant.Win.csproj" \
      -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true \
      -p:PublishTrimmed=false -p:IncludeNativeLibrariesForSelfExtract=true \
      -p:RuntimeFrameworkVersion=9.0.8 -o "$win_root\dist"
    for doc in README.md LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md; do
      cp "$source_root/$doc" "$source_root/dist/$doc"
    done
    cp -R "$source_root/licenses" "$source_root/dist/"
    cp -R "$source_root/docs" "$source_root/dist/"
    ;;
  *) echo 'Usage: ./build.sh [build|test|publish] [configuration]' >&2; exit 2 ;;
esac
