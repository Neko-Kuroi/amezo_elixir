#!/bin/sh
# あめぞう風掲示板 (Elixir 版) の起動スクリプト
#   ./run.sh [--port N] [--tunnel] [--verbose]   サーバを起動 (既定: ポート 8000、トンネルなし)
#   ./run.sh --make-hash 合言葉                  delpass.txt 用のハッシュを表示
#   ./run.sh --make-delpass 合言葉               delpass.txt を作る
#   ./run.sh --setup-tunnel                      cloudflared を用意して版数を表示
cd "$(dirname "$0")"
export AMEZO_DIR="$PWD"
REL="$PWD/release"

need_build() {
  [ ! -x "$REL/bin/amezo" ] && return 0
  [ -n "$(find lib mix.exs -newer "$REL/bin/amezo" -print -quit 2>/dev/null)" ] && return 0
  return 1
}

build() {
  if ! command -v mix >/dev/null 2>&1; then
    echo "❌ ビルド済みの release が無く、ビルドに必要な Elixir (mix) も見つかりません。" >&2
    exit 1
  fi
  echo "🔨 ビルドしています (mix release)..."
  tmp=$(mktemp -d)
  if MIX_ENV=prod mix release --path "$tmp/rel" >"$tmp/build.log" 2>&1; then
    rm -rf "$REL"
    cp -a "$tmp/rel" "$REL"
    rm -rf "$tmp"
  else
    cat "$tmp/build.log" >&2
    rm -rf "$tmp"
    echo "❌ ビルドに失敗しました。" >&2
    exit 1
  fi
}

case "$1" in
  --build-only)
    if need_build; then build; fi
    exit 0
    ;;
  --make-hash|--make-delpass|--setup-tunnel|archive|--archive)
    if need_build; then build; fi
    AMEZO_ARGV=$(printf '\037%s' "$@")
    export AMEZO_ARGV
    exec "$REL/bin/amezo" eval 'Amezo.CLI.main()'
    ;;
esac

PORT=8000
TUNNEL=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2 ;;
    --tunnel) TUNNEL=1; shift ;;
    --no-tunnel) TUNNEL=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "不明な引数: $1" >&2; shift ;;
  esac
done

if need_build; then build; fi

# 分散 (archive.sh の rpc 用) の cookie。無ければ作る
if [ ! -f .amezo_cookie ]; then
  (umask 077; od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > .amezo_cookie)
fi
RELEASE_COOKIE=$(cat .amezo_cookie)
export RELEASE_COOKIE
# ノード名はフォルダごとに変える (別の掲示板フォルダのサーバと衝突しないため)
NODE_ID=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
export RELEASE_NODE="amezo_${NODE_ID}@127.0.0.1"
export RELEASE_DISTRIBUTION=name
export AMEZO_MODE=serve
export AMEZO_PORT="$PORT"
export AMEZO_TUNNEL="$TUNNEL"
export AMEZO_VERBOSE="$VERBOSE"
exec "$REL/bin/amezo" start
