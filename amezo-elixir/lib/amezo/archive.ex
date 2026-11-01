defmodule Amezo.Archive do
  @moduledoc """
  過去ログの gzip 圧縮 (Python 版 archive.py / Go 版 archive.go)。
  Elixir 版の違い: flock は使わず、板 GenServer (唯一の書き手) の中で処理する
  ことで投稿と競合しない。自己チェックも nlink/flock 前提の項目は除いてある。
  出力はすべて集めて {終了コード, stdout, stderr} で返す (呼び出し側が表示する)。
  """
  alias Amezo.{Board, Config, Crypto, Store, Sys, Util}

  @tmp_max_age 86_400
  @selftest_mtime 1_700_000_000

  # ---------- 小物 ----------
  def arch_mb(b), do: :io_lib.format("~.2fMB", [b / 1_048_576.0]) |> IO.iodata_to_binary()

  def sha256_file(path) do
    {ctx, n} =
      File.stream!(path, [], 65_536)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {c, cnt} ->
        {:crypto.hash_update(c, chunk), cnt + byte_size(chunk)}
      end)

    {Crypto.hex_encode(:crypto.hash_final(ctx)), n}
  rescue
    _ -> {"", 0}
  end

  # gzip 末尾の ISIZE (展開後サイズ mod 2^32)。取れなければ {:error}
  def gz_isize(gz) do
    with {:ok, f} <- File.open(gz, [:read, :binary]),
         {sz, true} <- Util.file_size(gz),
         true <- sz >= 4,
         {:ok, _} <- :file.position(f, {:eof, -4}),
         <<b0, b1, b2, b3>> <- IO.binread(f, 4) do
      File.close(f)
      {:ok, b0 + b1 * 256 + b2 * 65_536 + b3 * 16_777_216}
    else
      _ -> :error
    end
  end

  # df コマンドで空き容量 (バイト) を取る。取れなければ {:error}
  def disk_free_bytes(dir) do
    case Sys.run_capture("df", ["-P", "-B1", dir]) do
      {out, 0} ->
        lines = String.split(out, "\n")

        if length(lines) < 2 do
          :error
        else
          cols = lines |> Enum.at(1) |> String.split()

          if length(cols) < 4 do
            :error
          else
            case Integer.parse(Enum.at(cols, 3)) do
              {v, _} -> {:ok, v}
              :error -> :error
            end
          end
        end

      _ ->
        :error
    end
  end

  # ---------- 走査 ----------
  # {平文の名前, gz の名前 (o数字.html の形), 一時ファイルのパス} を番号順で返す
  def arch_scan(folder) do
    {plain, gz, tmp} =
      Enum.reduce(Util.list_dir_names(Config.app_path(folder)), {[], [], []}, fn name, {p, g, t} ->
        cond do
          String.starts_with?(name, "o") and String.ends_with?(name, ".html") and
            byte_size(name) > 6 and Util.digits?(binary_part(name, 1, byte_size(name) - 6), 1, -1) ->
            {[name | p], g, t}

          String.starts_with?(name, "o") and String.ends_with?(name, ".html.gz") and
              byte_size(name) > 9 and
              Util.digits?(binary_part(name, 1, byte_size(name) - 9), 1, -1) ->
            {p, [binary_part(name, 0, byte_size(name) - 3) | g], t}

          String.starts_with?(name, "o") and String.contains?(name, ".html.gz.tmp") and
              tmp_digits?(name) ->
            {p, g, [Config.app_path([folder, name]) | t]}

          true ->
            {p, g, t}
        end
      end)

    num = fn n ->
      {d, _, _} = Util.split_once(n, ?.)
      Util.safe_integer(binary_part(d, 1, byte_size(d) - 1), 0)
    end

    {Enum.sort_by(plain, num), Enum.sort_by(gz, num), tmp}
  end

  defp tmp_digits?(name) do
    case :binary.match(name, ".") do
      {dot, 1} when dot > 1 -> Util.digits?(binary_part(name, 1, dot - 1), 1, -1)
      _ -> false
    end
  end

  # ---------- アーカイバ (状態を map で持ち回す) ----------
  defp new_state(quiet, dry, verbose, limit) do
    %{
      quiet: quiet,
      dry: dry,
      verbose: verbose,
      limit_left: if(limit > 0, do: limit, else: nil),
      compressed: 0,
      plain_removed: 0,
      stale_removed: 0,
      quarantined: 0,
      ng: 0,
      in_bytes: 0,
      out_bytes: 0,
      skip: %{},
      skip_order: [],
      out: []
    }
  end

  defp say(st, path, msg) do
    path = if String.starts_with?(path, "./"), do: binary_part(path, 2, byte_size(path) - 2), else: path
    line = String.pad_trailing(path, 34) <> " " <> msg
    %{st | out: [line | st.out]}
  end

  defp skip_it(st, path, reason) do
    st =
      if Map.has_key?(st.skip, reason) do
        %{st | skip: Map.update!(st.skip, reason, &(&1 + 1))}
      else
        %{st | skip: Map.put(st.skip, reason, 1), skip_order: st.skip_order ++ [reason]}
      end

    st = if st.verbose, do: say(st, path, "skip: " <> reason), else: st
    {st, false}
  end

  defp ng_it(st, path, msg) do
    st = %{st | ng: st.ng + 1}
    {say(st, path, "NG: " <> msg), false}
  end

  defp stage1(st, folder, name) do
    plain = Config.app_path([folder, name])
    disp = "./" <> folder <> "/" <> name
    {size, ok_size} = Util.file_size(plain)
    {mtime, _} = Util.file_mtime(plain)

    cond do
      not ok_size ->
        skip_it(st, disp, "ファイルが無い")

      Util.epoch_now() - mtime < st.quiet ->
        skip_it(st, disp, "最後の書き込みから間もない")

      disk_full?(size) ->
        skip_it(st, disp, "ディスクの空きが足りない")

      st.dry ->
        st = say(st, disp, "[dry-run] 圧縮する (#{arch_mb(size)})")
        {%{st | compressed: st.compressed + 1}, true}

      true ->
        stage1_real(st, plain, disp, size, mtime)
    end
  end

  defp disk_full?(size) do
    case disk_free_bytes(Config.app_dir()) do
      {:ok, free} -> free < size + 1_048_576
      :error -> false
    end
  end

  defp stage1_real(st, plain, disp, size, mtime) do
    t0 = System.monotonic_time(:millisecond)
    gzpath = plain <> ".gz"
    tmp = gzpath <> ".tmp" <> to_string(:os.getpid())

    if not Sys.gzip_compress_file(plain, tmp) do
      File.rm(tmp)
      ng_it(st, disp, "開けない (権限・空き容量を確認)")
    else
      {src_hex, src_n} = sha256_file(plain)
      {d_hex, d_n, d_ok} = Sys.gzip_decompress_digest(tmp)

      cond do
        not d_ok or d_hex != src_hex or d_n != src_n ->
          File.rm(tmp)
          ng_it(st, disp, "展開して確かめたら、元と一致しない (一時ファイルを消した)")

        true ->
          {size2, ok2} = Util.file_size(plain)
          {mtime2, _} = Util.file_mtime(plain)

          if not ok2 or size2 != size or mtime2 != mtime or src_n != size do
            File.rm(tmp)
            skip_it(st, disp, "圧縮している間に元が変わった")
          else
            Util.set_file_mtime(tmp, mtime)
            Util.chmod_file(tmp, 0o644)

            if not Util.rename_path(tmp, gzpath) do
              File.rm(tmp)
              ng_it(st, disp, "rename できない")
            else
              {gsize, _} = Util.file_size(gzpath)
              ms = System.monotonic_time(:millisecond) - t0
              denom = max(gsize, 1)
              ratio = :io_lib.format("~.1f", [size / denom]) |> IO.iodata_to_binary()

              st = %{
                st
                | compressed: st.compressed + 1,
                  in_bytes: st.in_bytes + size,
                  out_bytes: st.out_bytes + gsize
              }

              {say(st, disp, "圧縮  #{arch_mb(size)} → #{arch_mb(gsize)} (#{ratio}倍)  #{ms}ms"), true}
            end
          end
      end
    end
  end

  defp stage2(st, folder, name) do
    plain = Config.app_path([folder, name])
    disp = "./" <> folder <> "/" <> name
    gzpath = plain <> ".gz"
    {p_size, ok_size} = Util.file_size(plain)
    {p_mtime, _} = Util.file_mtime(plain)
    {g_mtime, ok_gz} = Util.file_mtime(gzpath)
    {g_ctime, _} = Util.file_ctime(gzpath)

    cond do
      not ok_size or not ok_gz ->
        st

      g_mtime != p_mtime ->
        if st.dry do
          st = say(st, disp, "[dry-run] 古い gz を削除する")
          %{st | stale_removed: st.stale_removed + 1}
        else
          File.rm(gzpath)
          st = %{st | stale_removed: st.stale_removed + 1}
          say(st, disp, "古い gz を削除 (平文が圧縮のあとに更新された。次回に再圧縮する)")
        end

      Util.epoch_now() - g_ctime < st.quiet ->
        elem(skip_it(st, disp, "gz の作成から間もない"), 0)

      p_size >= 4_294_967_296 ->
        elem(skip_it(st, disp, "4GiB 以上は確認できない"), 0)

      true ->
        stage2_verify(st, plain, disp, gzpath, p_size, p_mtime)
    end
  end

  defp stage2_verify(st, plain, disp, gzpath, p_size, p_mtime) do
    isize = gz_isize(gzpath)
    {dp_hex, dp_n} = sha256_file(plain)
    {dg_hex, dg_n, dg_ok} = Sys.gzip_decompress_digest(gzpath)

    bad =
      isize != {:ok, p_size} or dp_hex == "" or not dg_ok or dp_hex != dg_hex or dp_n != dg_n

    cond do
      bad and st.dry ->
        st = say(st, disp, "[dry-run] NG: gz の中身が平文と一致しない → gz を .bad に改名する")
        %{st | ng: st.ng + 1}

      bad ->
        Util.rename_path(gzpath, gzpath <> ".bad")
        st = %{st | quarantined: st.quarantined + 1}
        elem(ng_it(st, disp, "gz の中身が平文と一致しない。どちらも消さず、gz を oN.html.gz.bad に改名した (人が確認する)"), 0)

      true ->
        # 板プロセスの中なので投稿とは競合しない。再確認してから消す
        {size2, ok2} = Util.file_size(plain)
        {mtime2, _} = Util.file_mtime(plain)

        cond do
          not ok2 or size2 != p_size or mtime2 != p_mtime ->
            elem(skip_it(st, disp, "確認のあいだに変わった (次回に判断する)"), 0)

          st.dry ->
            st = say(st, disp, "[dry-run] 平文を削除する")
            %{st | plain_removed: st.plain_removed + 1}

          File.rm(plain) == :ok ->
            st = %{st | plain_removed: st.plain_removed + 1}
            say(st, disp, "平文を削除 (gz に置き換え)")

          true ->
            elem(ng_it(st, disp, "平文を消せない"), 0)
        end
    end
  end

  # ---------- 自己チェック (Elixir 版: nlink/flock 前提の項目は無い) ----------
  def arch_selftest(dirpath) do
    checks = []
    test_gz = dirpath <> "/.arch-gz-test"
    ok_gzip = Sys.gzip_compress_file(Config.app_path("blist.txt"), test_gz)
    File.rm(test_gz)
    checks = checks ++ [{"gzip コマンドが使える", ok_gzip, ""}]

    base = dirpath <> "/.archive-selftest-" <> to_string(:os.getpid())
    a_path = base <> ".a"
    b_path = base <> ".b"

    checks =
      if not Util.write_file_string(a_path, "selftest\n") do
        checks ++ [{"フォルダに書き込める", false, dirpath}]
      else
        checks = checks ++ [{"フォルダに書き込める", true, ""}]
        Util.set_file_mtime(a_path, @selftest_mtime)
        {mt, ok_mt} = Util.file_mtime(a_path)
        checks = checks ++ [{"更新日時 (mtime) を指定できる", ok_mt and mt == @selftest_mtime, ""}]
        {ct0, _} = Util.file_ctime(a_path)
        Util.rename_path(a_path, b_path)
        {mt2, _} = Util.file_mtime(b_path)
        {ct2, _} = Util.file_ctime(b_path)

        checks ++
          [{"rename で ctime が更新され、mtime は保たれる", ct2 >= ct0 and mt2 == @selftest_mtime,
            "ctime #{ct0} → #{ct2}"}]
      end

    File.rm(a_path)
    File.rm(b_path)

    {_free, df_ok} =
      case disk_free_bytes(Config.app_dir()) do
        {:ok, f} -> {f, true}
        :error -> {0, false}
      end

    checks ++ [{"ディスクの空き容量が確認できる", df_ok, ""}]
  end

  # ---------- restore ----------
  def arch_valid_board(b) do
    b != "" and not String.contains?(b, "/") and not String.contains?(b, "..") and
      Store.is_board(b) and Util.dir_exists?(Config.app_path(b))
  end

  def usage_text do
    "使い方:\n" <>
      "  archive 板名… | --all [--quiet=秒] [--limit=件数] [--dry-run] [-v]\n" <>
      "  archive --restore 板名 oN\n" <>
      "  archive --selftest [板名]\n"
  end

  def arch_restore(folder, oname) do
    s = oname
    s = if String.starts_with?(s, "o"), do: binary_part(s, 1, byte_size(s) - 1), else: s
    s = if String.ends_with?(s, ".html"), do: binary_part(s, 0, byte_size(s) - 5), else: s
    num = if Util.digits?(s, 1, -1), do: s, else: ""

    if not arch_valid_board(folder) or num == "" do
      {2, "", usage_text()}
    else
      plain = Config.app_path([folder, "o" <> num <> ".html"])
      gzpath = plain <> ".gz"

      cond do
        not Util.file_regular?(gzpath) ->
          {2, "", "#{gzpath} が無い\n"}

        Util.path_exists?(plain) ->
          {2, "", "#{plain} がすでにある (上書きはしない)\n"}

        true ->
          {g_mtime, _} = Util.file_mtime(gzpath)
          tmp = plain <> ".restore.tmp" <> to_string(:os.getpid())
          Sys.gzip_decompress_to_file(gzpath, tmp)
          {n, n_ok} = Util.file_size(tmp)
          n = if n_ok, do: n, else: -1
          want =
            case gz_isize(gzpath) do
              {:ok, v} -> v
              :error -> -2
            end

          cond do
            n != want ->
              File.rm(tmp)
              {1, "", "展開した長さが、gz の記録と一致しない (gz が壊れている?)\n"}

            true ->
              Util.set_file_mtime(tmp, g_mtime)
              Util.chmod_file(tmp, 0o644)

              if not Util.rename_path(tmp, plain) do
                File.rm(tmp)
                {1, "", "rename できない\n"}
              else
                out =
                  "#{plain} を作った (#{arch_mb(n)})。gz は残してある。\n" <>
                    "  編集すると更新日時が変わり、配信は平文に切り替わる (古い gz は次回の実行で消え、その次に再圧縮される)。\n" <>
                    "  編集しなければ、次回以降の実行で、この平文はまた消える。\n"

                {0, out, ""}
              end
          end
      end
    end
  end

  # ---------- メイン ----------
  # {終了コード, stdout, stderr} を返す
  def main(argv) do
    case parse_args(argv) do
      :usage -> {2, "", usage_text()}
      {:ok, opts} -> dispatch(opts)
    end
  end

  defp parse_args(argv) do
    init = %{
      quiet: Config.archive_quiet_seconds(),
      limit: 0,
      dry: false,
      verbose: false,
      all: false,
      restore: false,
      selftest: false,
      boards: []
    }

    Enum.reduce_while(argv, {:ok, init}, fn a, {:ok, o} ->
      cond do
        a == "--all" -> {:cont, {:ok, %{o | all: true}}}
        a == "--dry-run" -> {:cont, {:ok, %{o | dry: true}}}
        a == "-v" -> {:cont, {:ok, %{o | verbose: true}}}
        a == "--restore" -> {:cont, {:ok, %{o | restore: true}}}
        a == "--selftest" -> {:cont, {:ok, %{o | selftest: true}}}
        String.starts_with?(a, "--quiet=") -> parse_num_opt(o, a, "--quiet=", :quiet, 7, 604_800)
        String.starts_with?(a, "--limit=") -> parse_num_opt(o, a, "--limit=", :limit, 9, nil)
        a != "" and not String.starts_with?(a, "-") -> {:cont, {:ok, %{o | boards: o.boards ++ [a]}}}
        true -> {:halt, :usage}
      end
    end)
  end

  defp parse_num_opt(o, a, prefix, key, max_digits, max_val) do
    v = binary_part(a, byte_size(prefix), byte_size(a) - byte_size(prefix))

    if Util.digits?(v, 1, max_digits) do
      n = Util.safe_integer(v, 0)

      if (max_val && n > max_val) or (key == :limit and n < 1) do
        {:halt, :usage}
      else
        {:cont, {:ok, Map.put(o, key, n)}}
      end
    else
      {:halt, :usage}
    end
  end

  defp dispatch(o) do
    cond do
      o.restore ->
        if length(o.boards) != 2 do
          {2, "", usage_text()}
        else
          arch_restore(Enum.at(o.boards, 0), Enum.at(o.boards, 1))
        end

      o.selftest ->
        boards = if o.all or o.boards == [], do: Store.board_folders(), else: o.boards
        b = List.first(boards) || ""

        if b == "" or not arch_valid_board(b) do
          {2, "", usage_text()}
        else
          selftest_main(b)
        end

      true ->
        boards = if o.all, do: Store.board_folders(), else: o.boards
        run_main(%{o | boards: boards})
    end
  end

  defp selftest_main(b) do
    lines = ["自己チェック (フォルダ: ./#{b})"]

    {lines, bad} =
      Enum.reduce(arch_selftest(Config.app_path(b)), {lines, 0}, fn {label, ok, detail}, {ls, bad} ->
        mark = if ok, do: "OK   ", else: "NG   "
        d = if detail != "", do: "  (#{detail})", else: ""
        {ls ++ [mark <> label <> d], if(ok, do: bad, else: bad + 1)}
      end)

    lines =
      if bad == 0 do
        lines ++ ["すべて OK。この環境で archive を使えます。"]
      else
        lines ++ ["NG が #{bad} 件。この環境では archive を動かさないでください。"]
      end

    {if(bad == 0, do: 0, else: 2), Enum.join(lines, "\n") <> "\n", ""}
  end

  defp run_main(o) do
    boards = o.boards

    cond do
      boards == [] ->
        {2, "", usage_text()}

      Enum.any?(boards, fn b -> not arch_valid_board(b) end) ->
        bad = Enum.find(boards, fn b -> not arch_valid_board(b) end)
        {2, "", "板 #{bad}: 見つからない (blist.txt とフォルダを確認)\n"}

      true ->
        gate =
          if o.dry do
            :ok
          else
            bad = Enum.filter(arch_selftest(Config.app_path(hd(boards))), fn {_, ok, _} -> not ok end)

            if bad == [] do
              :ok
            else
              err =
                Enum.map_join(bad, "", fn {label, _, _} -> "自己チェック NG: #{label}\n" end) <>
                  "この環境では動かしません。`archive --selftest 板名` で詳細を確認してください。\n"

              {:error, err}
            end
          end

        case gate do
          {:error, err} -> {2, "", err}
          :ok -> run_boards(o)
        end
    end
  end

  defp run_boards(o) do
    st0 = new_state(o.quiet, o.dry, o.verbose, o.limit)

    {st, lines} =
      Enum.reduce(o.boards, {st0, []}, fn folder, {st, lines} ->
        before = st

        st =
          board_run(folder, fn -> process_board(st, folder) end)

        summary =
          "板 #{folder}: 圧縮 #{st.compressed - before.compressed} " <>
            "(#{arch_mb(st.in_bytes - before.in_bytes)} → #{arch_mb(st.out_bytes - before.out_bytes)})、" <>
            "平文削除 #{st.plain_removed - before.plain_removed}、" <>
            "古い gz 削除 #{st.stale_removed - before.stale_removed}、" <>
            "gz を退避 #{st.quarantined - before.quarantined}、NG #{st.ng - before.ng}"

        {st, lines ++ [summary]}
      end)

    out_lines = Enum.reverse(st.out) ++ lines

    out_lines =
      if st.skip != %{} do
        parts =
          Enum.map_join(st.skip_order, ", ", fn r -> "#{r} #{Map.fetch!(st.skip, r)}" end)

        out_lines ++ ["スキップ: " <> parts]
      else
        out_lines
      end

    code = if st.ng > 0, do: 1, else: 0
    {code, Enum.join(out_lines, "\n") <> "\n", ""}
  end

  # 板プロセスの中で1板分を処理する (投稿と直列化される)
  defp board_run(folder, fun) do
    case Board.run(folder, fun, :infinity) do
      {:ok, result} -> result
      other -> raise "archive: 板 #{folder} の処理に失敗しました: #{inspect(other)}"
    end
  end

  defp process_board(st, folder) do
    {plain, gz, tmps} = arch_scan(folder)
    gz_set = MapSet.new(gz)

    st =
      if st.dry do
        st
      else
        Enum.reduce(tmps, st, fn tp, st ->
          {mt, ok} = Util.file_mtime(tp)

          if ok and Util.epoch_now() - mt > @tmp_max_age do
            File.rm(tp)
            %{st | out: ["#{tp}  古い一時ファイルを削除" | st.out]}
          else
            st
          end
        end)
      end

    st =
      Enum.reduce(plain, st, fn name, st ->
        if MapSet.member?(gz_set, name), do: stage2(st, folder, name), else: st
      end)

    Enum.reduce(plain, st, fn name, st ->
      cond do
        MapSet.member?(gz_set, name) ->
          st

        limit_reached?(st) ->
          elem(skip_it(st, "./" <> folder <> "/" <> name, "--limit に達した"), 0)

        true ->
          {st, done} = stage1(st, folder, name)
          if done, do: count_limit(st), else: st
      end
    end)
  end

  # --limit は板をまたいで効く。状態は st.limit_left に持つ
  defp limit_reached?(st), do: Map.get(st, :limit_left) != nil and st.limit_left <= 0
  defp count_limit(st), do: if(Map.get(st, :limit_left), do: %{st | limit_left: st.limit_left - 1}, else: st)
end
