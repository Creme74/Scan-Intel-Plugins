#!/bin/bash
#
# Scan Intel Plugins [Creme] - V2.1
# Lists the audio plug-ins that are a problem on Apple Silicon Macs:
#   - Intel 64-bit only  -> depend on Rosetta
#   - 32-bit / PowerPC   -> cannot load at all anymore
#   - damaged / broken aliases
#
# Formats : AU, VST, VST3, AAX, CLAP
# Folders : /Library (all users) and ~/Library (current user)
#
# Uses only tools present on every Mac (bash 3.2, file, find, PlistBuddy,
# osascript): no Xcode or Command Line Tools needed.
#
# https://github.com/Creme74/Scan-Intel-Plugins

VERSION="V2.1"
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
: > "$WORK/rosetta"; : > "$WORK/dead"; : > "$WORK/unknown"
N_NATIVE=0
IS_MAC=""
[ "$(uname)" = "Darwin" ] && IS_MAC=1

PROGRESS="$WORK/progress"
PROGRESS_PID=""

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  [ -n "$PROGRESS_PID" ] && kill "$PROGRESS_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------- helpers
# These helpers set variables instead of printing a result: every $(...)
# around a function costs an extra process, and over a thousand plug-ins
# that adds up.

plist_get() {   # plist_get <Info.plist> <key>  -> PLIST_VALUE ("" if missing)
  PLIST_VALUE=""
  [ -f "$1" ] || return 1
  PLIST_VALUE=$("$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null)
}

# Main executable of a bundle -> BIN: the file named by CFBundleExecutable,
# otherwise the first Mach-O file found in Contents/MacOS ("" if none).
main_binary() {
  local bundle="$1" f
  BIN=""
  plist_get "$bundle/Contents/Info.plist" CFBundleExecutable
  if [ -n "$PLIST_VALUE" ] && [ -f "$bundle/Contents/MacOS/$PLIST_VALUE" ]; then
    BIN="$bundle/Contents/MacOS/$PLIST_VALUE"
    return
  fi
  for f in "$bundle"/Contents/MacOS/*; do
    [ -f "$f" ] || continue
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) BIN="$f"; return ;;
    esac
  done
}

# Version shown in the report -> VER. Only read for the plug-ins that end up
# in the report: native ones are just counted.
bundle_version() {
  plist_get "$1/Contents/Info.plist" CFBundleShortVersionString
  VER="$PLIST_VALUE"
  if [ -z "$VER" ]; then
    plist_get "$1/Contents/Info.plist" CFBundleVersion
    VER="$PLIST_VALUE"
  fi
}

# `file` description of the main executable -> KIND
# native  : has an arm64 slice          -> runs natively on Apple Silicon
# rosetta : x86_64 but no arm64         -> depends on Rosetta
# dead    : only i386 and/or PowerPC    -> cannot load on any current Mac
classify() {
  case "$1" in
    *Mach-O*) ;;
    *) KIND=unknown; return ;;
  esac
  case "$1" in
    *arm64*)  KIND=native ;;
    *x86_64*) KIND=rosetta ;;
    *i386*|*ppc*) KIND=dead ;;
    *) KIND=unknown ;;
  esac
}

record() {      # record <category> <order> <format> <name> <version> <reason>
  printf '%s\n' "$2$SEP$3$SEP$4$SEP$5$SEP$6" >> "$WORK/$1"
}

scan_bundle() { # scan_bundle <order> <format> <bundle path>
  local order="$1" fmt="$2" bundle="$3" name
  name="${bundle##*/}"; name="${name%.*}"

  if [ ! -d "$bundle" ]; then
    record unknown "$order" "$fmt" "$name" "" "broken alias"
    return
  fi

  main_binary "$bundle"
  if [ -z "$BIN" ]; then
    bundle_version "$bundle"
    record unknown "$order" "$fmt" "$name" "$VER" "no executable inside"
    return
  fi

  classify "$(file -b "$BIN" 2>/dev/null)"
  case "$KIND" in
    native)
      N_NATIVE=$((N_NATIVE + 1)) ;;
    unknown)
      bundle_version "$bundle"
      record unknown "$order" "$fmt" "$name" "$VER" "unreadable executable" ;;
    *)
      bundle_version "$bundle"
      record "$KIND" "$order" "$fmt" "$name" "$VER" "" ;;
  esac
}

# --------------------------------------------------------------- progress
# The scan state goes to $PROGRESS. A small black & white window, drawn by
# osascript (JavaScript + Cocoa), reads it and shows a progress bar. When the
# script runs in a Terminal, a text bar is drawn there too.

BAR_FULL='##############################'
BAR_EMPTY='..............................'

progress() {    # progress <COUNT|SCAN|DONE> <done> <total> [format] [name]
  printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" "$5" 2>/dev/null > "$PROGRESS"
  [ -t 2 ] || return 0
  local fill=0 pct=0
  if [ "$1" = "DONE" ]; then
    fill=30; pct=100
  elif [ "$3" -gt 0 ]; then
    fill=$(($2 * 30 / $3)); pct=$(($2 * 100 / $3))
  fi
  printf '\r[%s%s] %3d%%' "${BAR_FULL:0:fill}" "${BAR_EMPTY:0:30-fill}" "$pct" >&2
  [ "$1" = "DONE" ] && printf '\n' >&2
}

progress_window_start() {
  [ -n "$IS_MAC" ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  progress_window_script > "$WORK/progress.js" || return 0
  osascript -l JavaScript "$WORK/progress.js" "$PROGRESS" "$VERSION" \
    </dev/null >/dev/null 2>&1 &
  PROGRESS_PID=$!
}

# The window closes itself about a second after "DONE"; never wait more than 3 s
progress_window_stop() {
  [ -n "$PROGRESS_PID" ] || return 0
  local i=0
  while kill -0 "$PROGRESS_PID" 2>/dev/null && [ "$i" -lt 30 ]; do
    sleep 0.1; i=$((i + 1))
  done
  kill "$PROGRESS_PID" 2>/dev/null
  PROGRESS_PID=""
}

progress_window_script() {
  cat <<'JS'
// Scan Intel Plugins - progress window (JavaScript for Automation + Cocoa)
// usage: osascript -l JavaScript progress.js <progress file> <version>
ObjC.import('Cocoa');

var COLS = 42;          // characters per line
var CELLS = 36;         // blocks in the bar
var DONE_MS = 900;      // "SCAN COMPLETE" stays on screen this long
var STALE_MS = 60000;   // close if the scan stops reporting

function repeat(ch, n) { var s = ''; while (s.length < n) s += ch; return s; }
function fit(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, n - 3) + '...' : s; }
function pad(s, n) { s = String(s || ''); return s + repeat(' ', n - s.length); }
function spread(left, right) {
  return left + repeat(' ', Math.max(1, COLS - left.length - right.length)) + right;
}

// file: phase / done / total / format / name, one per line
function parse(text) {
  var l = String(text).split('\n');
  if (l.length < 4) return null;                       // still being written
  var st = { phase: l[0], done: parseInt(l[1], 10), total: parseInt(l[2], 10),
             fmt: l[3] || '', name: l[4] || '' };
  if (['COUNT', 'SCAN', 'DONE'].indexOf(st.phase) < 0) return null;
  if (isNaN(st.done) || isNaN(st.total)) return null;
  return st;
}

function render(st, cursorOn) {
  var pct = 0, fill = 0, status, line;
  if (st.phase === 'DONE') {
    pct = 100; fill = CELLS;
  } else if (st.total > 0) {
    pct = Math.floor(st.done * 100 / st.total);
    fill = Math.floor(st.done * CELLS / st.total);
  }
  if (st.phase === 'COUNT') {
    status = 'COUNTING PLUG-INS...';
    line = '> PLEASE WAIT';
  } else if (st.phase === 'SCAN') {
    status = spread('SCANNING PLUG-INS', st.done + '/' + st.total);
    line = '> ' + pad(st.fmt, 5) + fit(st.name, COLS - 8);
  } else {
    status = spread('SCAN COMPLETE', st.total + '/' + st.total);
    line = '> OPENING REPORT';
  }
  var pctText = String(pct) + '%';
  return {
    status: status,
    bar: repeat('█', fill) + repeat('░', CELLS - fill) + repeat(' ', COLS - CELLS - pctText.length) + pctText,
    line: line + (cursorOn ? '_' : ' ')
  };
}

function readText(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, 4, $());   // 4 = UTF-8
  if (!s || s.isNil()) return null;
  return ObjC.unwrap(s);
}

function monoFont(size, bold) {
  var f = $.NSFont.fontWithNameSize(bold ? 'Menlo-Bold' : 'Menlo-Regular', size);
  if (!f || f.isNil()) f = $.NSFont.userFixedPitchFontOfSize(size);
  return f;
}

function box(view, x, y, w, h, fill, border, width) {
  var b = $.NSBox.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
  b.setBoxType(4);                  // custom box
  b.setTitlePosition(0);            // no title
  b.setFillColor(fill);
  b.setBorderColor(border);
  b.setBorderWidth(width);
  b.setCornerRadius(0);
  view.addSubview(b);
  return b;
}

function label(view, x, y, w, h, font, color) {
  var t = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
  t.setBezeled(false);
  t.setBordered(false);
  t.setDrawsBackground(false);
  t.setEditable(false);
  t.setSelectable(false);
  t.setFont(font);
  t.setTextColor(color);
  t.setStringValue('');
  view.addSubview(t);
  return t;
}

function run(argv) {
  var file = argv[0], version = argv[1] || '';
  var win = null;
  try {
    var app = $.NSApplication.sharedApplication;
    app.setActivationPolicy(1);     // accessory: no Dock icon, no menu bar
    app.finishLaunching;

    var W = 400, H = 136, X = 18, TW = W - 2 * X;
    var black = $.NSColor.blackColor, white = $.NSColor.whiteColor;
    var font = monoFont(14, false), bold = monoFont(14, true);

    win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
      $.NSMakeRect(0, 0, W, H), 0, 2, false);   // borderless, buffered
    win.setReleasedWhenClosed(false);
    win.setBackgroundColor(black);
    win.setOpaque(true);
    win.setHasShadow(true);
    win.setLevel(3);                 // floating: stays above other windows
    win.setCollectionBehavior(1);    // shown on every Space
    win.setIgnoresMouseEvents(true); // clicks go through

    var view = win.contentView;
    box(view, 0, 0, W, H, black, white, 2);             // white frame
    box(view, 2, H - 28, W - 4, 26, white, white, 0);   // title bar, reverse video
    label(view, X, H - 24, TW, 18, bold, black).setStringValue(spread('SCAN INTEL PLUGINS', version));
    var status = label(view, X, 74, TW, 20, font, white);
    var bar = label(view, X, 48, TW, 20, font, white);
    var line = label(view, X, 22, TW, 20, font, white);

    win.center;
    win.orderFrontRegardless;

    var state = { phase: 'COUNT', done: 0, total: 0, fmt: '', name: '' };
    var lastText = null, lastChange = Date.now(), doneAt = 0, shown = '';
    while (true) {
      var ev = app.nextEventMatchingMaskUntilDateInModeDequeue(
        0xFFFFFFFF, $.NSDate.dateWithTimeIntervalSinceNow(0.08), 'kCFRunLoopDefaultMode', true);
      if (ev && !ev.isNil()) app.sendEvent(ev);

      var now = Date.now();
      var text = readText(file);
      if (text === null) {
        if (!$.NSFileManager.defaultManager.fileExistsAtPath(file)) break;   // scan ended
      } else if (text !== lastText) {
        lastText = text;
        lastChange = now;
        var st = parse(text);
        if (st) state = st;
      }
      if (state.phase === 'DONE') {
        if (!doneAt) doneAt = now;
        else if (now - doneAt >= DONE_MS) break;
      } else if (now - lastChange >= STALE_MS) {
        break;
      }

      var r = render(state, Math.floor(now / 500) % 2 === 0);
      var key = r.status + '\n' + r.bar + '\n' + r.line;
      if (key !== shown) {
        shown = key;
        status.setStringValue(r.status);
        bar.setStringValue(r.bar);
        line.setStringValue(r.line);
      }
    }
  } catch (e) {
    // never let the window get in the way of the scan
  }
  if (win) win.orderOut(null);
}
JS
}

# ------------------------------------------------------------------- scan

progress COUNT 0 0
progress_window_start

# 1. list every plug-in first, so the progress bar knows the total
: > "$WORK/list"
order=0
for target in "${SCAN_TARGETS[@]}"; do
  order=$((order + 1))
  IFS='|' read -r fmt rel ext <<< "$target"
  for lib in "$SYSTEM_LIB" "$USER_LIB"; do
    dir="$lib/$rel"
    [ -d "$dir" ] || continue
    # -prune: don't look inside a plug-in once found (vendor sub-folders are still searched)
    while IFS= read -r -d '' bundle; do
      printf '%s\0' "$order$SEP$fmt$SEP$bundle"
    done < <(find -H "$dir" -iname "*.$ext" -prune -print0 2>/dev/null) >> "$WORK/list"
  done
done
TOTAL=$(tr -cd '\000' < "$WORK/list" | wc -c | tr -d ' ')

# 2. analyse them
i=0
while IFS= read -r -d '' rec; do
  i=$((i + 1))
  order="${rec%%"$SEP"*}"; rec="${rec#*"$SEP"}"
  fmt="${rec%%"$SEP"*}";   bundle="${rec#*"$SEP"}"
  name="${bundle##*/}"; name="${name%.*}"
  progress SCAN "$i" "$TOTAL" "$fmt" "$name"
  scan_bundle "$order" "$fmt" "$bundle"
done < "$WORK/list"

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
  printf 'Scan Intel Plugins [Creme] %s - %s\n' "$VERSION" "$(date "+%Y-%m-%d %H:%M")"
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

progress DONE "$TOTAL" "$TOTAL"
progress_window_stop

if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$N_ROSETTA need Rosetta, $N_DEAD cannot load ($N_TOTAL scanned)\" with title \"Scan Intel Plugins\"" >/dev/null 2>&1
fi
[ -n "$IS_MAC" ] && open "$REPORT"

echo "Report saved to: $REPORT"
exit 0
