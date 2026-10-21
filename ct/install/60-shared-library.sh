#!/bin/bash
# Pre-register the shared Steam library (bind-mounted at /mnt/steamlib/SteamLibrary) with the session user's Steam,
# reusing the library's own contentid so Steam treats it as the same library. Run as root with the session stopped.
set -euo pipefail
U=${STEAM_LXC_USER:-steam}; LIB=${1:-/mnt/steamlib/SteamLibrary}
H=$(getent passwd "$U" | cut -d: -f6); S="$H/.local/share/Steam"
cid=$(awk -F'"' '/contentid/{print $4}' "$LIB/libraryfolder.vdf")
apps=$(for m in "$LIB"/steamapps/appmanifest_*.acf; do id=${m##*_}; id=${id%.acf}; echo "			\"$id\"		\"0\""; done)
for f in "$S/steamapps/libraryfolders.vdf" "$S/config/libraryfolders.vdf"; do
  install -d -o "$U" -g "$U" "$(dirname "$f")"
  cat > "$f" <<V
"libraryfolders"
{
	"0"
	{
		"path"		"$S"
		"label"		""
		"contentid"		"$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')"
		"totalsize"		"0"
		"apps"
		{
		}
	}
	"1"
	{
		"path"		"$LIB"
		"label"		""
		"contentid"		"$cid"
		"totalsize"		"0"
		"apps"
		{
$apps
		}
	}
}
V
  chown "$U:$U" "$f"
done
echo "registered $LIB"
