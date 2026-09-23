#!/usr/bin/env bash
# bundle_java.sh - make Processing's exported mockup builds self-contained
# (no Java install needed on the target machines) and zip them for a GitHub release.
#
# Run from any cwd after "Export Application" in Processing (NO "bundle Java
# runtime" - the IDE cannot cross-bundle runtimes, it crashes or copies the
# wrong-arch JVM). Expected layout next to this script:
#
#   macos-aarch64/mockup.app   macos-x86_64/mockup.app
#   windows-amd64/mockup.exe   linux-amd64/mockup
#
# Steps per platform:
#   1. JRE: reuse ./java_runtime/<key> if present, else download Temurin from
#      the Adoptium API into it.
#   2. Copy the JRE into the build:
#        macOS:   mockup.app/Contents/PlugIns/jdk-$MAJOR.jdk + JVMRuntime in Info.plist
#        Windows: windows-amd64/java + regenerate mockup.exe via launch4j so it
#                 searches .\java first, then %PATH% (the stock exe only checks PATH)
#        Linux:   linux-amd64/java + patch the launcher script to prefer it
#   3. Delete Processing's per-distribution source/ folder.
#   4. Zip each build dir: macos-x86_64.zip, macos-aarch64.zip,
#      windows-amd64.zip, linux-amd64.zip
#
# Requires: curl, unzip, a java on PATH (to run launch4j), macOS-only: ditto,
# PlistBuddy, Processing.app (for its bundled launch4j; override via L4J_DIR).

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JRE_MAJOR="${JRE_MAJOR:-17}"          # matches <key>JVMVersion</key> in the exported Info.plist
RUNTIME_DIR="$PWD/java_runtime"
L4J_DIR="${L4J_DIR:-/Applications/Processing.app/Contents/app/resources/modes/java/application/launch4j}"

# target dir      -> adoptium <os>/<arch> pair (subdir name under java_runtime)
TARGETS_MAC="macos-aarch64 macos-x86_64"
TARGETS_WIN="windows-amd64"
TARGETS_LINUX="linux-amd64"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ensure_runtime <cache-key> <adoptium-os> <adoptium-arch>
# leaves a Temurin JRE at $RUNTIME_DIR/<cache-key> with bin/ (or Contents/Home/bin on mac)
ensure_runtime() {
  local key="$1" os="$2" arch="$3"
  local dir="$RUNTIME_DIR/$key"
  local probe
  case "$os" in
    mac) probe="Contents/Home/bin/java" ;;
    windows) probe="bin/java.exe" ;;
    *) probe="bin/java" ;;
  esac

  if [ -x "$dir/$probe" ]; then
    log "JRE '$key': reusing java_runtime/$key"
    return
  fi
  [ -e "$dir" ] && { echo "stale/incomplete '$dir' - re-downloading"; rm -rf "$dir"; }

  local url="https://api.adoptium.net/v3/binary/latest/${JRE_MAJOR}/ga/${os}/${arch}/jre/hotspot/normal/eclipse"
  log "JRE '$key': downloading Temurin ${JRE_MAJOR} (${os}/${arch})"
  mkdir -p "$RUNTIME_DIR"
  local tmp="$RUNTIME_DIR/$key.dl"
  rm -rf "$tmp"; mkdir -p "$tmp"
  curl -fL --retry 3 -o "$tmp/jre-archive" "$url"

  if [ "$os" = "windows" ]; then
    unzip -q "$tmp/jre-archive" -d "$tmp"
  else
    tar xzf "$tmp/jre-archive" -C "$tmp"
  fi
  rm "$tmp/jre-archive"
  # archive contains a single jdk-<ver>-jre top dir: lift its contents to $dir
  local top
  top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$top" ] || die "nothing extracted from $key archive"
  mkdir -p "$dir"
  mv "$top"/* "$top"/.[!.]* "$dir"/ 2>/dev/null || true
  rmdir "$top" 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
  [ -x "$dir/$probe" ] || die "JRE '$key' missing $probe after unpack"
}

# --- macOS: PlugIns/jdk-$MAJOR.jdk + JVMRuntime key (the appbundler stub in
# the exported launcher resolves JVMRuntime relative to Contents/PlugIns) ---
bundle_macos() {
  local dir="$1" key="$2"
  local app="$dir/mockup.app"
  [ -d "$app" ] || { echo "skip $dir (no mockup.app)"; return; }
  ensure_runtime "$key" mac "$([ "$key" = macos-aarch64 ] && echo aarch64 || echo x64)"

  log "bundling JRE into $app"
  local plugins="$app/Contents/PlugIns" jdkname="jdk-${JRE_MAJOR}.jdk"
  rm -rf "$plugins"
  mkdir -p "$plugins"
  cp -R "$RUNTIME_DIR/$key" "$plugins/$jdkname"

  local plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :JVMRuntime $jdkname" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :JVMRuntime string $jdkname" "$plist"
  "$plugins/$jdkname/Contents/Home/bin/java" -version 2>&1 | head -1 \
    || echo "note: bundled $key JRE not runnable here (foreign arch) - OK if not native"
}

# --- Windows: .\java + launch4j-regenerated exe (search order java;%PATH%) ---
bundle_windows() {
  local dir="windows-amd64"
  [ -d "$dir" ] || { echo "skip $dir (not found)"; return; }
  ensure_runtime windows-x64 windows x64
  command -v java >/dev/null || die "need a java on PATH to run launch4j"
  [ -f "$L4J_DIR/launch4j.jar" ] || die "launch4j not found at $L4J_DIR (set L4J_DIR)"

  log "bundling JRE into $dir + regenerating mockup.exe"
  rm -rf "$dir/java"
  cp -R "$RUNTIME_DIR/windows-x64" "$dir/java"

  local cfg="launch4j-bundle.xml"
  {
    echo '<launch4jConfig>'
    echo '  <headerType>gui</headerType>'
    echo '  <dontWrapJar>true</dontWrapJar>'
    echo "  <downloadUrl>https://adoptium.net/temurin/releases/?version=${JRE_MAJOR}</downloadUrl>"
    echo "  <outfile>$dir/mockup.exe</outfile>"
    echo '  <classPath>'
    echo '    <mainClass>mockup</mainClass>'
    local j
    for j in $(ls "$dir/lib" | grep -E '\.jar$'); do
      echo "    <cp>%EXEDIR%/lib/$j</cp>"
    done
    echo '  </classPath>'
    echo '  <jre>'
    echo '    <path>java;%PATH%</path>'
    echo "    <minVersion>${JRE_MAJOR}</minVersion>"
    echo '    <opt>-Djna.nosys=true</opt>'
    echo '    <opt>-Djava.library.path="%EXEDIR%\lib"</opt>'
    echo '  </jre>'
    echo '</launch4jConfig>'
  } > "$cfg"
  java -cp "$L4J_DIR/launch4j.jar:$L4J_DIR/lib/xstream.jar" \
    net.sf.launch4j.Main "$cfg" | grep -v -i "warning\|unsafe" || true
  rm -f "$cfg"
  [ -f "$dir/mockup.exe" ] || die "launch4j did not produce $dir/mockup.exe"
}

# --- Linux: ./java + point the launcher at it ---
bundle_linux() {
  local dir="linux-amd64"
  [ -d "$dir" ] || { echo "skip $dir (not found)"; return; }
  ensure_runtime linux-x64 linux x64

  log "bundling JRE into $dir + patching launcher"
  rm -rf "$dir/java"
  cp -R "$RUNTIME_DIR/linux-x64" "$dir/java"

  local launcher="$dir/mockup"
  if grep -q '^java ' "$launcher"; then
    sed 's|^java |"$APPDIR/java/bin/java" |' "$launcher" > "$launcher.new"
    cat "$launcher.new" > "$launcher" && rm -f "$launcher.new"
  fi
  chmod +x "$launcher" "$dir/java/bin/java"
}

# --- strip source, zip ---
finalize() {
  local dir="$1"
  [ -d "$dir" ] || return
  rm -rf "$dir/source"
  rm -f "$dir.zip"
  log "zipping $dir.zip"
  if [ -d "$dir/mockup.app" ]; then
    ditto -c -k --keepParent "$dir" "$dir.zip"   # keeps perms, symlinks, metadata
  else
    zip -qry "$dir.zip" "$dir" -x '*.DS_Store'
  fi
}

# ---------- main ----------
log "target dir: $PWD"
for t in $TARGETS_MAC; do
  case "$t" in
    macos-aarch64) bundle_macos "$t" macos-aarch64 ;;
    macos-x86_64)  bundle_macos "$t" macos-x86_64 ;;
  esac
done
bundle_windows
bundle_linux
for t in $TARGETS_MAC $TARGETS_WIN $TARGETS_LINUX; do finalize "$t"; done

log "done - upload these to your GitHub release:"
ls -1 ./*.zip
