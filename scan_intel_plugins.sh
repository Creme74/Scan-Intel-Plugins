#!/bin/bash
#
# Scan Intel Plugins [Creme] - V2.0
# Lists the audio plug-ins that are a problem on Apple Silicon Macs:
#   - Intel 64-bit only  -> depend on Rosetta
#   - 32-bit / PowerPC   -> cannot load at all anymore
#   - damaged / broken aliases
#
# Formats : AU, VST, VST3, AAX, CLAP
# Folders : /Library (all users) and ~/Library (current user)
#
# Uses only tools present on every Mac (bash 3.2, file, find, PlistBuddy):
# no Xcode or Command Line Tools needed.
#
# https://github.com/Creme74/Scan-Intel-Plugins

SYSTEM_LIB="/Library"
USER_LIB="$HOME/Library"
PLISTBUDDY="/usr/libexec/PlistBuddy"

# label | folder inside Library | bundle extension   (report follows this order)
SCAN_TARGETS=(
  "AU|Audio/Plug-Ins/Components|component"
  "VST|Audio/Plug-Ins/VST|vst"
  "VST3|Audio/Plug-Ins/VST3|vst3"
  "AAX|Application Support/Avid/Audio/Plug-Ins|aaxplugin"
  "CLAP|Audio/Plug-Ins/CLAP|clap"
)

# Field separator for the temp lists. Not a tab: `read` merges consecutive
# tabs, which would shift columns when a plug-in has no version number.
SEP=$(printf '\037')
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pluginscan.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/rosetta"; : > "$WORK/dead"; : > "$WORK/unknown"
N_NATIVE=0

# ---------------------------------------------------------------- helpers

plist_get() {   # plist_get <Info.plist> <key>
  [ -f "$1" ] || return 1
  "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null
}

# Path of the bundle's main executable: the one named by CFBundleExecutable,
# otherwise the first Mach-O file found in Contents/MacOS.
main_binary() {
  local bundle="$1" exe f
  exe=$(plist_get "$bundle/Contents/Info.plist" CFBundleExecutable)
  if [ -n "$exe" ] && [ -f "$bundle/Contents/MacOS/$exe" ]; then
    printf '%s\n' "$bundle/Contents/MacOS/$exe"
    return
  fi
  for f in "$bundle"/Contents/MacOS/*; do
    [ -f "$f" ] || continue
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) printf '%s\n' "$f"; return ;;
    esac
  done
}

# native  : has an arm64 slice          -> runs natively on Apple Silicon
# rosetta : x86_64 but no arm64         -> depends on Rosetta
# dead    : only i386 and/or PowerPC    -> cannot load on any current Mac
classify() {
  case "$1" in
    *Mach-O*) ;;
    *) echo unknown; return ;;
  esac
  case "$1" in
    *arm64*)  echo native ;;
    *x86_64*) echo rosetta ;;
    *i386*|*ppc*) echo dead ;;
    *) echo unknown ;;
  esac
}

record() {      # record <category> <order> <format> <name> <version> <reason>
  printf '%s\n' "$2$SEP$3$SEP$4$SEP$5$SEP$6" >> "$WORK/$1"
}

scan_bundle() { # scan_bundle <order> <format> <bundle path>
  local order="$1" fmt="$2" bundle="$3" name ver bin kind
  name=$(basename "$bundle"); name="${name%.*}"

  if [ ! -d "$bundle" ]; then
    record unknown "$order" "$fmt" "$name" "" "broken alias"
    return
  fi

  ver=$(plist_get "$bundle/Contents/Info.plist" CFBundleShortVersionString)
  [ -z "$ver" ] && ver=$(plist_get "$bundle/Contents/Info.plist" CFBundleVersion)

  bin=$(main_binary "$bundle")
  if [ -z "$bin" ]; then
    record unknown "$order" "$fmt" "$name" "$ver" "no executable inside"
    return
  fi

  kind=$(classify "$(file -b "$bin" 2>/dev/null)")
  case "$kind" in
    native)  N_NATIVE=$((N_NATIVE + 1)) ;;
    unknown) record unknown "$order" "$fmt" "$name" "$ver" "unreadable executable" ;;
    *)       record "$kind" "$order" "$fmt" "$name" "$ver" "" ;;
  esac
}

# ------------------------------------------------------------------- scan

order=0
for target in "${SCAN_TARGETS[@]}"; do
  order=$((order + 1))
  IFS='|' read -r fmt rel ext <<< "$target"
  for lib in "$SYSTEM_LIB" "$USER_LIB"; do
    dir="$lib/$rel"
    [ -d "$dir" ] || continue
    # -prune: don't look inside a plug-in once found (vendor sub-folders are still searched)
    while IFS= read -r -d '' bundle; do
      scan_bundle "$order" "$fmt" "$bundle"
    done < <(find -H "$dir" -iname "*.$ext" -prune -print0 2>/dev/null)
  done
done

# ----------------------------------------------------------------- report

count() { wc -l < "$WORK/$1" | tr -d ' '; }
N_ROSETTA=$(count rosetta); N_DEAD=$(count dead); N_UNKNOWN=$(count unknown)
N_TOTAL=$((N_NATIVE + N_ROSETTA + N_DEAD + N_UNKNOWN))

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  MAC="Apple Silicon"
else
  MAC="Intel (Rosetta is not used on this Mac; the report shows what would need it on Apple Silicon)"
fi
OS=$(sw_vers -productVersion 2>/dev/null)

STAMP=$(date "+%Y-%m-%d %Hh%M")
REPORT_DIR="$HOME/Desktop"
REPORT="$REPORT_DIR/Plugin Rosetta Report $STAMP.txt"
if ! { [ -d "$REPORT_DIR" ] && : > "$REPORT"; } 2>/dev/null; then
  REPORT="$HOME/Plugin Rosetta Report $STAMP.txt"
fi

# Plug-ins of one category, grouped by format, sorted by name
plugin_list() {
  local last=""
  LC_ALL=C sort -t "$SEP" -k1,1n -k3,3f "$WORK/$1" |
  while IFS="$SEP" read -r order fmt name ver reason; do
    if [ "$fmt" != "$last" ]; then
      printf '\n  %s\n' "$fmt"
      last="$fmt"
    fi
    printf '    %s%s%s\n' "$name" "${ver:+  ($ver)}" "${reason:+  - $reason}"
  done
}

title() {       # title <text>
  printf '\n\n%s\n' "$1"
  printf '%s\n' "$1" | sed 's/./=/g'
}

{
  printf 'PLUGIN ROSETTA REPORT\n'
  printf 'Scan Intel Plugins [Creme] V2.0 - %s\n' "$(date "+%Y-%m-%d %H:%M")"
  printf 'Mac: %s%s\n\n' "$MAC" "${OS:+, macOS $OS}"

  printf '%s plug-ins scanned (AU, VST, VST3, AAX, CLAP)\n' "$N_TOTAL"
  printf '  Need Rosetta ............. %s\n' "$N_ROSETTA"
  printf '  Cannot load at all ....... %s\n' "$N_DEAD"
  printf '  Could not be analysed .... %s\n' "$N_UNKNOWN"

  if [ "$N_TOTAL" -eq 0 ]; then
    printf '\nNo plug-ins found in the scanned folders.\n'
  elif [ "$N_ROSETTA" -eq 0 ] && [ "$N_DEAD" -eq 0 ] && [ "$N_UNKNOWN" -eq 0 ]; then
    printf '\nEverything is native. Stop geeking, make some music.\n'
  fi

  if [ -s "$WORK/rosetta" ]; then
    title "NEED ROSETTA - Intel 64-bit only ($N_ROSETTA)"
    plugin_list rosetta
  fi

  if [ -s "$WORK/dead" ]; then
    title "CANNOT LOAD AT ALL - 32-bit Intel or PowerPC ($N_DEAD)"
    cat <<'EOF'
No current Mac or host can load these, Rosetta or not.
Remove them, or replace them with a 64-bit version.
EOF
    plugin_list dead
  fi

  if [ -s "$WORK/unknown" ]; then
    title "COULD NOT BE ANALYSED ($N_UNKNOWN)"
    printf 'Damaged or incomplete plug-ins, or aliases pointing to a missing file.\n'
    plugin_list unknown
  fi
  printf '\n'
} > "$REPORT"

# Tell TextEdit the report is UTF-8 (plug-in names may contain accents)
command -v xattr >/dev/null 2>&1 &&
  xattr -w com.apple.TextEncoding "utf-8;134217984" "$REPORT" 2>/dev/null

if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$N_ROSETTA need Rosetta, $N_DEAD cannot load ($N_TOTAL scanned)\" with title \"Scan Intel Plugins\"" >/dev/null 2>&1
fi
[ "$(uname)" = "Darwin" ] && open "$REPORT"

echo "Report saved to: $REPORT"
exit 0
