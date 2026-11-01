# DESIGN.md — Elixir 版の設計と、他版との差分

仕様の正本は Python 版 (amezo-python)。データ形式・ハッシュ/署名アルゴリズム・HTTP の外部挙動は他版と互換に保ち、内部設計は BEAM/OTP に合わせて作り直した。言語研究として「同じ仕様を各言語らしく実装する」ことが目的で、他版との同一フォルダ同時運用は想定していない (形式互換の確認は `tests/format_compat_test.py` で一方向ずつ行う)。

## OTP らしい内部設計

- **板ごとの GenServer が唯一の書き手 (single-writer)**。投稿・再生成・管理操作・archive はすべて板プロセスの中で直列化して実行する。他版の flock(2) は不要になり、NIF も C コードも書いていない。依存は OTP 標準のみ。
- **supervision tree**: Registry / Secrets / Counters / 板 DynamicSupervisor / Listener / Boot / Tunnel を `Amezo.Application` が監督する。板プロセスは必要になった時点で起動する。
- **HTTP は `:gen_tcp`**。Listener がアクセプタプロセス (8 個、リンク付きで再生成) を持ち、アクセプタがそのまま接続を処理する。リクエスト解析は生のテキスト処理で、パス検査は他版と同じ (生の request-target を見るため `//` や `..` を 400 にできる)。
- **早期脱出は throw/catch**。Python の `error()` / Go の panic+recover (`bbsExit`) に相当する `Amezo.Exit.bail/1` をハンドラ境界と板プロセスの境界で受ける。
- **秘密鍵ファイルは Secrets GenServer が一元管理** (load-or-create は他版と同じ作法: 一時ファイル + ハードリンク、600)。
- **揮発性カウンタはメモリ**: 全体制限 (global.mem 相当) は Counters GenServer がメモリに持つ。ただし **admin_fail.mem だけはファイルのまま** (形式も同じ)。理由: (1) 結合テストがファイルの存在と「生 IP が残らないこと」を確認する、(2) 管理画面のロックアウトは再起動をまたいで効くべき。書き込みは Counters が一手に担う。
- **投稿間隔の状態** (lasttime 相当) は板 GenServer の状態に持つ (ファイルには残らない)。
- **cloudflared は Tunnel GenServer が Port で監督**。出力を行単位で読み、公開 URL を拾って表示する。落ちても掲示板は止まらない。
- **archive はノード内で実行**。サーバ稼働中の `archive.sh` は分散 Erlang (ループバック限定、cookie 認証、ノード名はフォルダごとに一意) で稼働中ノードに rpc し、板プロセスの中で処理する。停止中は release の eval でその場実行。終了コードはセンチネル行でシェルに返す。
- **配布は mix release** (ERTS 同梱)。この環境 (共有 FS) では `mix release` のコピーがファイル属性の書き込みで失敗することがあったため、run.sh は一時フォルダにビルドしてから `cp -a` で配置する。

## 意図的な差分 (外部挙動に関わるもの)

- **CGI モードは無い**。単一プロセスサーバ専用 (BEAM に CGI は合わないため。他版にはある)。
- **flock を使わない**。同時運用を想定しないので相互運用テストは対象外にし、代わりに形式互換チェック (Python 生成フォルダの読み書き、トリップ一致、delpass 互換、Python からの再返信) を用意した。
- **投稿時の nlink チェック省略**。他版は「開いたまま unlink されたスレッド」を見分けるため nlink を見るが、Elixir 版は板プロセスが唯一の書き手で、archive の平文削除も同じプロセス内で再確認してから行うため、構造的に不要。
- **管理画面の日時パースは Python 版の正規表現に合わせた**。Go/Lisp 版は「単位の直前の数字」を拾う方式で、`投稿日` の `日` に引っかかって常に失敗し、削除後の mtime がフォールバック値になっていた。Elixir 版は Python の `(\d{4})年(\d{2})月…` で正しく解釈する (仕様の正本に合わせた修正)。
- **二重投稿チェックの prev は Python 版に合わせた**。Go 版はループを抜ける行 (フォーム行) まで prev を進めるため実質チェックが効かなかった。Python は最後のレス行だけを prev とする。Elixir 版は Python に合わせた。
- **linkify / URL 妥当性の文字クラスは Python 版の ASCII 仕様**。Go 版は Unicode の英数字まで広げていた (実害の無い範囲の相違)。Elixir 版は Python に合わせた。
- **全体制限カウンタは再起動でリセットされる** (メモリ保持のため)。global.mem をファイルで共有していた他版との唯一の持続性の差。admin_fail.mem は上記のとおりファイルで残る。
- **archive の自己チェック項目が違う**。Go 版は nlink/flock の POSIX 意味論を検査するが、Elixir 版はそれらに依存しないため、gzip・書き込み可否・utime・rename での mtime 保持・df の 5 項目に絞ってある。

## 実装上の注意 (この環境で踏んだもの)

- **`File.chmod` が mtime を現在時刻に戻す**ことがある (Erlang の write_file_info 経由)。archive の「gz の mtime = 平文の mtime」が崩れて段階 2 が誤作動したため、`Util.chmod_file` は変更前の mtime を保存して復元する。他版の os.chmod は mtime を変えない。
- **ノード名はフォルダごとに一意** (`amezo_<cksum(絶対パス)>@127.0.0.1`)。固定名だと、別の掲示板フォルダのサーバや落ちた前回の残骸と衝突して起動できない。
- **Elixir 1.14 の release スクリプトに `foreground` は無い**。`start` を使う (SIGTERM で VM が落ちるので、テストの terminate と相性がよい)。
- リクエストヘッダの読み取りは `packet: :raw` で自前。Content-Length の上限検査 (413) はルーティングより先、という他版の順序を守っている。
