#!/usr/bin/env bash
#
# Build a signed release APK inside a GitHub Codespace and copy it back to this machine.
#
# The Actions release job needs the repo owner's signing secrets, so in a fork it stops at
# "Verify signing secrets are configured" by design. This script skips CI: it builds the
# commit checked out locally in a codespace, signing with a throwaway keystore, and pulls
# the APK down over SSH. Nothing is pushed and no repo secrets are touched.
#
# Requirements: gh (authenticated, with the `codespace` scope), git, base64, md5sum.
#
# Usage:
#   scripts/build-apk-codespace.sh                # build, then stop the codespace
#   scripts/build-apk-codespace.sh --keep         # leave it running (faster next time)
#   scripts/build-apk-codespace.sh --delete       # delete it when done
#   scripts/build-apk-codespace.sh -m basicLinux32gb
#   scripts/build-apk-codespace.sh -c <codespace-name>
#   scripts/build-apk-codespace.sh -o ~/Downloads
#
# The APK lands in ./build-out (or -o) and the signing key is kept in the codespace's
# $HOME/.swiftslate-keystore so repeated builds stay update-compatible. Pass
# --keystore-file <path> to reuse a keystore you already own; it is uploaded and its
# password must match --keystore-password (default: "swiftslate").

set -euo pipefail

MACHINE="standardLinux32gb"
CODESPACE=""
OUT_DIR="build-out"
CLEANUP="stop"          # stop | keep | delete
TIMEOUT_MIN=45
KEY_ALIAS="swiftslate"
KS_PASS="swiftslate"
LOCAL_KS=""
DISPLAY_NAME="swiftslate-build"
CMDTOOLS="commandlinetools-linux-13114758_latest.zip"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--machine)          MACHINE="$2"; shift 2 ;;
    -c|--codespace)        CODESPACE="$2"; shift 2 ;;
    -o|--out)              OUT_DIR="$2"; shift 2 ;;
    --keystore-file)       LOCAL_KS="$2"; shift 2 ;;
    --keystore-password)   KS_PASS="$2"; shift 2 ;;
    --key-alias)           KEY_ALIAS="$2"; shift 2 ;;
    --timeout)             TIMEOUT_MIN="$2"; shift 2 ;;
    --keep)                CLEANUP="keep"; shift ;;
    --delete)              CLEANUP="delete"; shift ;;
    -h|--help)             usage 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- local checks
command -v gh >/dev/null || die "gh is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this from inside the repo"

SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BRANCH="$(git symbolic-ref --short -q HEAD || echo master)"
SHA="$(git rev-parse HEAD)"
VERSION_CODE="$(git rev-list --count HEAD)"
VERSION_NAME="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION_NAME" ] || VERSION_NAME="$(sed -n 's/.*val baseVersion *= *"\(.*\)".*/\1/p' app/build.gradle.kts | head -1)"
[ -n "$VERSION_NAME" ] || die "could not determine versionName"
[ -n "$KEY_ALIAS" ] || die "key alias must not be empty"

APK_NAME="SwiftSlate-${VERSION_NAME}-${VERSION_CODE}.apk"
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"

# Reuse the key we saved on a previous run, so signing stays stable if the codespace is
# ever deleted or recreated. Without this every new codespace would mint a new key and
# the APKs would refuse to update each other.
if [ -z "$LOCAL_KS" ] && [ -f "$OUT_DIR/release.keystore" ]; then
  LOCAL_KS="$OUT_DIR/release.keystore"
fi

log "repo      $SLUG"
log "commit    $(git rev-parse --short HEAD) on $BRANCH"
log "version   $VERSION_NAME ($VERSION_CODE)"

# ------------------------------------------------------- codespace lifecycle
if [ -z "$CODESPACE" ]; then
  CODESPACE="$(gh codespace list --repo "$SLUG" \
    --json name,displayName,state \
    --jq ".[] | select(.displayName == \"$DISPLAY_NAME\") | .name" | head -1)"
fi

if [ -n "$CODESPACE" ]; then
  log "reusing codespace $CODESPACE"
else
  log "creating codespace ($MACHINE, this takes ~1-2 min)"
  CODESPACE="$(gh codespace create --repo "$SLUG" --branch "$BRANCH" \
    --machine "$MACHINE" --display-name "$DISPLAY_NAME" \
    --idle-timeout 30m --retention-period 24h | tail -1)"
  [ -n "$CODESPACE" ] || die "codespace creation returned no name"
  log "created $CODESPACE"
fi

state="$(gh codespace list --repo "$SLUG" --json name,state \
  --jq ".[] | select(.name == \"$CODESPACE\") | .state")"
if [ "$state" != "Available" ]; then
  log "starting codespace (state: $state)"
  # There is no `gh codespace start`: an ssh connection is what wakes a stopped VM,
  # and it blocks until the codespace is reachable.
  gh codespace ssh -c "$CODESPACE" -- 'true' >/dev/null 2>&1 \
    || warn "wake-up ssh returned non-zero; continuing anyway"
fi

# ------------------------------------------------------------- build payload
# Values are baked in here rather than sent as env vars: one self-contained file is
# easier to inspect in $HOME/.build-apk.sh when something goes wrong.
PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
cat > "$PAYLOAD" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail

export JAVA_HOME="\$HOME/.swiftslate-jdk"
if [ ! -x "\$JAVA_HOME/bin/java" ]; then
  for cand in /usr/local/sdkman/candidates/java/21* /usr/lib/jvm/*21* /usr/lib/jvm/*17*; do
    [ -x "\$cand/bin/java" ] && { JAVA_HOME="\$cand"; break; }
  done
fi
export ANDROID_HOME="\$HOME/android-sdk"
export ANDROID_SDK_ROOT="\$ANDROID_HOME"
export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"

echo "== java: \$("\$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

if [ ! -x "\$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "== installing Android commandline-tools"
  mkdir -p "\$ANDROID_HOME/cmdline-tools"
  curl -sSLo /tmp/cmdtools.zip "https://dl.google.com/android/repository/${CMDTOOLS}"
  rm -rf /tmp/cmdtools && mkdir -p /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  mv /tmp/cmdtools/cmdline-tools "\$ANDROID_HOME/cmdline-tools/latest"
fi

# Accepting licenses lets AGP fetch the exact platform/build-tools it wants, so this
# script does not have to hardcode android-37 or a build-tools revision.
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install "platform-tools" >/dev/null

REPO_DIR="\$(ls -d /workspaces/${REPO_NAME} 2>/dev/null || true)"
[ -n "\$REPO_DIR" ] || { echo "BUILD FAILED: /workspaces/${REPO_NAME} not found"; exit 1; }
cd "\$REPO_DIR"

git fetch -q origin
if git cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  git checkout -qf "${SHA}"
else
  echo "== WARNING: ${SHA} is not on origin (unpushed commit?) - building origin/${BRANCH}"
  git checkout -qf "origin/${BRANCH}"
fi
echo "== building \$(git rev-parse --short HEAD): ${VERSION_NAME} (${VERSION_CODE})"

KS="\$HOME/.swiftslate-keystore/release.keystore"
if [ ! -f "\$KS" ]; then
  echo "== generating throwaway release keystore"
  mkdir -p "\$(dirname "\$KS")"
  keytool -genkeypair -keystore "\$KS" -alias "${KEY_ALIAS}" -keyalg RSA -keysize 2048 \\
    -validity 10000 -storepass "${KS_PASS}" -keypass "${KS_PASS}" \\
    -dname "CN=SwiftSlate,O=SwiftSlate,L=Dhaka,S=Dhaka,C=BD" 2>&1 | tail -1
fi

export KEYSTORE_FILE="\$KS"
export KEYSTORE_PASSWORD="${KS_PASS}"
export KEY_ALIAS="${KEY_ALIAS}"
export KEY_PASSWORD="${KS_PASS}"

./gradlew --no-daemon assembleRelease \\
  -PversionCode="${VERSION_CODE}" -PversionName="${VERSION_NAME}"

SRC=app/build/outputs/apk/release/app-release.apk
[ -f "\$SRC" ] || { echo "BUILD FAILED: \$SRC missing"; exit 1; }
cp -f "\$SRC" "\$HOME/${APK_NAME}"
echo "APK_MD5=\$(md5sum "\$HOME/${APK_NAME}" | cut -d' ' -f1)"
echo "BUILD_OK"
REMOTE

log "uploading build script"
b64="$(base64 -w0 "$PAYLOAD")"
gh codespace ssh -c "$CODESPACE" -- \
  "echo $b64 | base64 -d > \$HOME/.build-apk.sh && chmod +x \$HOME/.build-apk.sh"

if [ -n "$LOCAL_KS" ]; then
  [ -f "$LOCAL_KS" ] || die "keystore not found: $LOCAL_KS"
  log "uploading keystore $LOCAL_KS"
  ks64="$(base64 -w0 "$LOCAL_KS")"
  gh codespace ssh -c "$CODESPACE" -- \
    "mkdir -p \$HOME/.swiftslate-keystore && echo $ks64 | base64 -d > \$HOME/.swiftslate-keystore/release.keystore && chmod 600 \$HOME/.swiftslate-keystore/release.keystore"
fi

# ------------------------------------------------------------------- launch
# Detached on purpose: the build outlives a dropped SSH connection, and a run that
# hangs the channel (nohup does that on some gh builds) cannot stall this script.
log "starting build (log: ~/build.log on $CODESPACE)"
timeout 90 gh codespace ssh -c "$CODESPACE" -- "
  rm -f \$HOME/build.log
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t apk 2>/dev/null || true
    tmux new-session -d -s apk 'bash \$HOME/.build-apk.sh > \$HOME/build.log 2>&1'
  else
    nohup setsid bash \$HOME/.build-apk.sh > \$HOME/build.log 2>&1 < /dev/null &
  fi
  echo launched" >/dev/null 2>&1 || warn "launch call did not return cleanly; polling the log anyway"

# --------------------------------------------------------------------- poll
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
last=""
while :; do
  sleep 15
  probe="$(gh codespace ssh -c "$CODESPACE" -- '
    if grep -q BUILD_OK $HOME/build.log 2>/dev/null; then echo "DONE";
    elif grep -q "BUILD FAILED" $HOME/build.log 2>/dev/null; then echo "FAILED";
    elif pgrep -f .build-apk.sh >/dev/null 2>&1; then echo "RUNNING";
    else echo "GONE"; fi
    tail -n 1 $HOME/build.log 2>/dev/null | cut -c1-100' 2>/dev/null || echo "RUNNING")"
  status="${probe%%$'\n'*}"
  line="$(printf '%s' "$probe" | tail -n 1)"
  [ "$line" != "$last" ] && [ -n "$line" ] && { printf '    %s\n' "$line" >&2; last="$line"; }

  case "$status" in
    DONE) break ;;
    FAILED|GONE)
      gh codespace ssh -c "$CODESPACE" -- 'tail -n 40 $HOME/build.log' >&2 || true
      die "build failed on the codespace (full log: ~/build.log)" ;;
  esac

  if [ "$(date +%s)" -gt "$deadline" ]; then
    die "timed out after ${TIMEOUT_MIN}m; the build may still be running — check with:
  gh codespace ssh -c $CODESPACE -- 'tail -f \$HOME/build.log'"
  fi
done

# ---------------------------------------------------------------- download
mkdir -p "$OUT_DIR"
TMP_DL="$(mktemp)"
remote_md5="$(gh codespace ssh -c "$CODESPACE" -- \
  "md5sum \$HOME/${APK_NAME} | cut -d' ' -f1" | tr -d '\r\n')"
log "downloading ${APK_NAME} ($remote_md5)"
gh codespace ssh -c "$CODESPACE" -- "base64 -w0 \$HOME/${APK_NAME}" > "$TMP_DL"
tr -d '\r\n' < "$TMP_DL" | base64 -d > "$OUT_DIR/$APK_NAME"
rm -f "$TMP_DL"

local_md5="$(md5sum "$OUT_DIR/$APK_NAME" | cut -d' ' -f1)"
if [ "$remote_md5" != "$local_md5" ]; then
  rm -f "$OUT_DIR/$APK_NAME"
  die "checksum mismatch (remote $remote_md5, local $local_md5) — APK discarded"
fi
chmod 644 "$OUT_DIR/$APK_NAME"

# Keep the signing key consistent across codespace rebuilds: adopt the generated one
# locally if we do not already have it.
if [ -z "$LOCAL_KS" ] && [ ! -f "$OUT_DIR/release.keystore" ]; then
  if gh codespace ssh -c "$CODESPACE" -- 'test -f $HOME/.swiftslate-keystore/release.keystore'; then
    gh codespace ssh -c "$CODESPACE" -- 'base64 -w0 $HOME/.swiftslate-keystore/release.keystore' \
      | tr -d '\r\n' | base64 -d > "$OUT_DIR/release.keystore"
    chmod 600 "$OUT_DIR/release.keystore"
    log "saved signing key to $OUT_DIR/release.keystore (alias $KEY_ALIAS, password \`$KS_PASS\`)"
  fi
fi

# ------------------------------------------------------------------ cleanup
case "$CLEANUP" in
  delete) gh codespace delete -c "$CODESPACE" --force >/dev/null && log "deleted $CODESPACE" ;;
  keep)   log "codespace left running: $CODESPACE" ;;
  *)      gh codespace stop -c "$CODESPACE" >/dev/null && log "stopped $CODESPACE (--keep to leave it running)" ;;
esac

size="$(du -h "$OUT_DIR/$APK_NAME" | cut -f1)"
printf '\n\033[1;32mAPK ready\033[0m\n  %s\n  %s  md5 %s\n' \
  "$(cd "$OUT_DIR" && pwd)/$APK_NAME" "$size" "$local_md5"
printf '  install: termux-open "%s"\n' "$(cd "$OUT_DIR" && pwd)/$APK_NAME"
