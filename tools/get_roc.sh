#!/bin/sh
# **THE PINNED ROC, INSTALLED** (README, "Before you build"): the nightly
# roc-version names, from roc-lang/nightlies' release of that tag, into
# ~/roc-<pin>/, and ~/.local/bin/roc linked to it (put ~/.local/bin on the
# PATH). Already there and answering the pin, it is only linked again.
#
#     tools/get_roc.sh
#
# roc-markdown, the sibling the app imports, is built by the same Roc: its
# pin moves with this one.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(tr -d '[:space:]' < "$here/roc-version")

case "$(uname -s) $(uname -m)" in
    "Linux x86_64") platform=linux_x86_64 ;;
    *) echo "get_roc: roc-chat builds on x86-64 Linux only, not $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

dest="$HOME/roc-$pin"
says() { "$dest/roc" version 2>/dev/null | awk '{print $NF}'; }
if [ ! -x "$dest/roc" ] || [ "$(says)" != "$pin" ]; then
    asset="roc_nightly-$platform-${pin#nightly-}.tar.gz"
    url="https://github.com/roc-lang/nightlies/releases/download/$pin/$asset"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    echo "get_roc: $url"
    curl -fL --retry 3 -o "$work/$asset" "$url"
    tar -xzf "$work/$asset" -C "$work"
    found=$(find "$work" -type f -name roc -perm -u+x | head -n 1)
    [ -n "$found" ] || { echo "get_roc: no roc executable in $asset" >&2; exit 1; }
    rm -rf "$dest"
    mv "$(dirname "$found")" "$dest"
    [ "$(says)" = "$pin" ] || { echo "get_roc: $dest/roc says $("$dest/roc" version), not $pin" >&2; exit 1; }
fi

mkdir -p "$HOME/.local/bin"
ln -sfn "$dest/roc" "$HOME/.local/bin/roc"
echo "get_roc: ~/.local/bin/roc -> $dest/roc ($pin)"
