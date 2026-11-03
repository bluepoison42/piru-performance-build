#!/bin/zsh
set -e
TOOLS="${0:A:h}"
. "$TOOLS/env.sh"
PROPERTIES="$TOOLS/../app/Android/gradle/wrapper/gradle-wrapper.properties"
URL=$(python3 -c 'import sys; print(next(line.split("=",1)[1].strip().replace("\\:", ":") for line in open(sys.argv[1]) if line.startswith("distributionUrl=")))' "$PROPERTIES")
SHA=$(sed -n 's/^distributionSha256Sum=//p' "$PROPERTIES")
DISTRIBUTION="${${URL:t}%-bin.zip}"
HOME_DIR="$PIRU_ANDROID/tools/$DISTRIBUTION"
if [[ ! -x "$HOME_DIR/bin/gradle" ]]; then
    mkdir -p "$PIRU_ANDROID/tools" "$PIRU_ANDROID/downloads"
    ARCHIVE="$PIRU_ANDROID/downloads/${URL:t}"
    curl -fL --retry 3 "$URL" -o "$ARCHIVE"
    echo "$SHA  $ARCHIVE" | shasum -a 256 -c
    unzip -qo "$ARCHIVE" -d "$PIRU_ANDROID/tools"
fi
exec "$HOME_DIR/bin/gradle" "$@"
