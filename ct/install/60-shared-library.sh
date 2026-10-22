#!/bin/bash
# Optional: pre-register an existing Steam library folder (e.g. a host dir bind-mounted at /mnt/steamlib) with the
# session user's Steam, reusing the library's own contentid. Run as root with the session stopped.
# Usage: 60-shared-library.sh /mnt/steamlib/SteamLibrary
set -euo pipefail
LIB=${1:?usage: $0 <path to an existing SteamLibrary folder>}
[ -r /etc/default/steam-lxc ] && . /etc/default/steam-lxc
U=${STEAM_LXC_USER:-steam}
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
