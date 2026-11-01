# amezo-elixir — あめぞう風掲示板 (Elixir 版)

Python 版 (amezo-python) を仕様の正本として移植した、あめぞう風掲示板の Elixir 実装です。データ形式・トリップ・ID・認証キー・delpass のハッシュは他版と互換で、Python 版が作った掲示板フォルダをそのまま読み書きできます (形式互換チェック済み)。

ただし内部設計は他版の 1 対 1 移植ではなく、BEAM/OTP の流儀に合わせて作り直してあります (板ごとの GenServer が唯一の書き手、supervision tree、トンネルやアーカイブもノード内包)。設計の考え方と他版との差分は `DESIGN.md` を見てください。

Elixir 版の特徴は **mix release による自己完結配布** です。ビルド済み release (Erlang ランタイム同梱) があれば、実行環境に Erlang/Elixir は要りません。

## 起動

```sh
sh run.sh --make-delpass 好きなパスワード   # 初回のみ: 管理パスワード (delpass.txt) を作る
sh run.sh                                   # http://127.0.0.1:8000/ で起動
```

`run.sh` は、release が無い/古い場合にだけ `mix release` でビルドします (Elixir 1.14 以降 / Erlang/OTP 24 以降が必要)。ビルド済み release が同梱されていれば、そのまま起動できます。

オプション:

```sh
sh run.sh --port 8080      # ポート変更
sh run.sh --verbose        # アクセスログを出す
sh run.sh --tunnel         # Cloudflare Tunnel で公開 (下記)
sh run.sh --make-hash 合言葉   # delpass.txt 用のハッシュだけを表示
```

## Cloudflare Tunnel で公開する

```sh
sh run.sh --tunnel
```

- `cloudflared` が PATH にもアプリフォルダにも無ければ、公式リリースから自動ダウンロードします (amd64 / arm64)。ダウンロードしたファイルはサイズと ELF マジックで検証し、エラーページなどを掴んだ場合は捨てて取り直します。
- 事前準備だけなら `sh run.sh --setup-tunnel` (用意して版数を表示)。
- トンネルは supervision 配下の GenServer が Port 経由で cloudflared を見守ります。cloudflared が落ちても掲示板本体は動き続けます。

## 過去ログの圧縮 (archive)

```sh
sh archive.sh main --quiet=0        # 板 main の o数字.html を gzip 化
sh archive.sh --all                 # 全板
sh archive.sh --restore main o260101000000   # 平文に戻す
sh archive.sh --selftest main       # この環境で使えるか自己チェック
```

- サーバ稼働中は、稼働中ノードの中で (板プロセスと直列化して) 実行します。止まっているときは、その場でノードを起こして実行します。
- 1 回目の実行で gz を作り (平文は残る)、静穏期間を置いた 2 回目の実行で平文を消します。gz の中身は SHA-256 で照合し、壊れていたら `.bad` に退避します。

## テスト

```sh
mix test                            # 単体テスト (暗号ベクタ・日時・HTML 処理など)
python3 tests/port_test.py          # 結合テスト 27 件 (投稿・jump・鍵・管理・gz 配信)
python3 tests/archive_test.py       # archive テスト 11 件
python3 tests/format_compat_test.py # Python 版との形式互換チェック 8 件
```

## ファイル構成

- `lib/amezo/` — 本体。`board.ex` (板 GenServer)、`post.ex` / `regen.ex` (投稿と再生成)、`server.ex` (:gen_tcp サーバ)、`admin.ex` / `dai.ex` / `jump.ex` (画面)、`archive.ex`、`tunnel.ex`、`crypto.ex` ほか
- `release/` — ビルド済み release (Erlang ランタイム同梱)
- `run.sh` / `archive.sh` — 起動とアーカイブの入口
- `rel/vm.args.eex` — 分散をループバックに閉じる設定 (archive の rpc 用)

設定は `config.sample.ini` を `config.ini` にコピーして編集します (無ければ既定値)。
