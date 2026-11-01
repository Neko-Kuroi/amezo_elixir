#!/bin/sh
# 過去ログの gzip 圧縮 (Elixir 版)
#   ./archive.sh 板名… | --all [--quiet=秒] [--limit=件数] [--dry-run] [-v]
#   ./archive.sh --restore 板名 oN
#   ./archive.sh --selftest [板名]
# サーバ稼働中は、そのノードの中で (板プロセスと直列化して) 実行する。
# 止まっているときは、その場でノードを起こして実行する。
cd "$(dirname "$0")"
export AMEZO_DIR="$PWD"
REL="$PWD/release"

if [ ! -x "$REL/bin/amezo" ]; then
  sh ./run.sh --build-only || exit 2
fi

# 稼働中ノードへの rpc を試す (cookie があって、応答があればそちら)
if [ -f .amezo_cookie ]; then
  # 引数を Elixir の文字列リストとして埋め込む (" と \ だけエスケープする)
  EXPR="Amezo.CLI.archive_rpc(["
  first=1
  for a in "$@"; do
    esc=$(printf '%s' "$a" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    if [ $first -eq 1 ]; then first=0; else EXPR="$EXPR, "; fi
    EXPR="$EXPR\"$esc\""
  done
  EXPR="$EXPR])"
  NODE_ID=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
  OUT=$(RELEASE_NODE="amezo_${NODE_ID}@127.0.0.1" RELEASE_DISTRIBUTION=name \
        RELEASE_COOKIE="$(cat .amezo_cookie)" \
        "$REL/bin/amezo" rpc "$EXPR" 2>/dev/null)
  CODE=$(printf '%s\n' "$OUT" | sed -n 's/^AMEZO_ARCHIVE_EXIT:\([0-9]*\)$/\1/p' | tail -1)
  if [ -n "$CODE" ]; then
    printf '%s\n' "$OUT" | grep -v '^AMEZO_ARCHIVE_EXIT:' 
    exit "$CODE"
  fi
fi

# サーバが止まっている: その場で実行する (archive コマンドとして CLI に渡す)
AMEZO_ARGV=$(printf '\037%s' archive "$@")
export AMEZO_ARGV
exec "$REL/bin/amezo" eval 'Amezo.CLI.main()'
