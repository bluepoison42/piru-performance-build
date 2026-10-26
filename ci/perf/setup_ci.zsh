#!/bin/zsh
set -e
export HOMEBREW_NO_AUTO_UPDATE=1
export PIRU_ANDROID="${RUNNER_TEMP:?}/piru-android"
echo "PIRU_ANDROID=$PIRU_ANDROID" >> "$GITHUB_ENV"
export PIRU_CONFIG=release
export PIRU_UNSIGNED=1

xcodebuild -version
"$JAVA_HOME/bin/java" -version
brew install gradle librsvg trash

python3 -m venv "$RUNNER_TEMP/piru-venv"
source "$RUNNER_TEMP/piru-venv/bin/activate"
python -m pip install --disable-pip-version-check 'Pillow==12.0.0'
mkdir -p "$RUNNER_TEMP/piru-skip"
curl -fL --retry 3 'https://github.com/skiptools/skip/releases/download/1.9.13/skip-macos.zip' -o "$RUNNER_TEMP/piru-skip/skip.zip"
echo '8a0242c19a65e3cb0c1af0cbceb79a7294bd545b47748c007c0a69dc41c9bfdc  '"$RUNNER_TEMP/piru-skip/skip.zip" | shasum -a 256 -c
unzip -qo "$RUNNER_TEMP/piru-skip/skip.zip" -d "$RUNNER_TEMP/piru-skip/bin"
SKIP_BIN=$(find "$RUNNER_TEMP/piru-skip/bin" -type f -name skip -print -quit)
[[ -n "$SKIP_BIN" ]]
chmod +x "$SKIP_BIN"
export PATH="${SKIP_BIN:h}:$PATH"
echo "${SKIP_BIN:h}" >> "$GITHUB_PATH"
echo "$RUNNER_TEMP/piru-venv/bin" >> "$GITHUB_PATH"
skip version

# Keep the upstream pinned toolchain installer; omit its emulator because this job only builds.
python3 - <<'PY'
from pathlib import Path
p = Path('android/tools/setup.sh')
s = p.read_text()
old = 'platform-tools emulator "system-images;android-36;google_apis;arm64-v8a"'
assert old in s
s = s.replace(old, 'platform-tools "platforms;android-36" "build-tools;36.0.0"')
marker = 'echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"'
assert marker in s
s = s.split(marker)[0] + '\necho "CI build toolchain ready"\n'
p.write_text(s)
PY
zsh android/tools/setup.sh
df -h "$RUNNER_TEMP"

