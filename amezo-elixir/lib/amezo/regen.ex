defmodule Amezo.Regen do
  @moduledoc """
  板 index の再生成と過去ログ一覧 (Python 版 amezo.regen_index 周辺)。
  書き込みは呼び出し側が Board.run/2 で直列化している前提 (他版の regen.lock 相当)。
  """
  alias Amezo.{Config, Core, Store, Util}

  # ---------- 過去ログ一覧 (kako) ----------
  def kako_list_size(folder) do
    case Util.file_size(Config.app_path([folder, Config.kako_list()])) do
      {sz, true} -> sz
      _ -> -1
    end
  end

  defp sort_kako_items(items) do
    Enum.sort_by(items, fn {mt, name} -> {mt, name} end)
  end

  # 退避したアイテムの題名を kako.txt に追記する
  def append_kako_list(folder, items) do
    buf =
      items
      |> sort_kako_items()
      |> Enum.map_join("", fn {_mt, name} ->
        p = Store.archived_path(folder, name)
        p = if p == "", do: Config.app_path([folder, name]), else: p
        name <> Config.kako_sep() <> Store.read_thread_title(p) <> "\n"
      end)

    Util.append_file_string(Config.app_path([folder, Config.kako_list()]), buf)
  end

  def rebuild_kako_list(folder, names) do
    items =
      Enum.map(names, fn name ->
        p = Store.archived_path(folder, name)
        p = if p == "", do: Config.app_path([folder, name]), else: p
        {mt, _} = Util.file_mtime(p)
        {String.pad_leading(Integer.to_string(mt), 11, "0"), name}
      end)

    buf =
      items
      |> sort_kako_items()
      |> Enum.map_join("", fn {_mt, name} ->
        p = Store.archived_path(folder, name)
        p = if p == "", do: Config.app_path([folder, name]), else: p
        name <> Config.kako_sep() <> Store.read_thread_title(p) <> "\n"
      end)

    Util.write_file_atomic(Config.app_path([folder, Config.kako_list()]), buf)
  end

  def reverse_file_lines(path) do
    {lines, _} = Util.read_file_lines(path)
    Enum.reverse(lines)
  end

  def write_kako(folder, body_tag, title0, amezo_name_v, suffix, title) do
    list_path = Config.app_path([folder, Config.kako_list()])

    if Util.file_regular?(list_path) do
      head =
        "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n" <>
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" <>
          "<link rel=\"stylesheet\" href=\"../style.css\">\n" <>
          "<title>" <> title0 <> amezo_name_v <> suffix <> " 過去ログ</title></head>\n" <>
          Config.copyright_text() <>
          body_tag <> "\n" <>
          "<font size=+2>" <> title <> amezo_name_v <> suffix <> " 過去ログ</font>\n" <>
          "<div class=\"row links\"><a href=\"./\">板へ戻る</a></div>\n<font size=2>\n"

      {body, _i} =
        Enum.reduce(reverse_file_lines(list_path), {"", 0}, fn line, {acc, i} ->
          case :binary.match(line, Config.kako_sep()) do
            :nomatch ->
              {acc, i}

            {p, seplen} ->
              name = binary_part(line, 0, p)
              ttl = binary_part(line, p + seplen, byte_size(line) - p - seplen)

              if byte_size(name) > 5 and String.starts_with?(name, "o") and
                   String.ends_with?(name, ".html") and
                   Util.digits?(binary_part(name, 1, byte_size(name) - 6), 1, -1) do
                i2 = i + 1
                {acc <> " #{i2}<a href=\"" <> name <> "\">" <> ttl <> "</a>\n", i2}
              else
                {acc, i}
              end
          end
        end)

      Util.write_file_atomic(
        Config.app_path([folder, Config.kako_file()]),
        head <> body <> "</font>\n<hr></body></html>\n"
      )
    end
  end

  # ---------- スレッド走査 ----------
  def thread_file_name?(name) do
    byte_size(name) > 5 and String.ends_with?(name, ".html") and
      Util.digits?(binary_part(name, 0, byte_size(name) - 5), 1, -1)
  end

  # o数字.html / o数字.html.gz のどちらかなら "o数字.html" を返す
  def old_file_name(name) do
    base =
      if String.ends_with?(name, ".gz"),
        do: binary_part(name, 0, byte_size(name) - 3),
        else: name

    if byte_size(base) > 6 and String.starts_with?(base, "o") and
         String.ends_with?(base, ".html") and
         Util.digits?(binary_part(base, 1, byte_size(base) - 6), 1, -1) do
      base
    else
      ""
    end
  end

  # {スレッド [{時刻文字列, 名前}] 新しい順, 過去ログ名のリスト}
  def scan_threads(folder, want_old) do
    {files, old_names} =
      Enum.reduce(Util.list_dir_names(Config.app_path(folder)), {[], []}, fn name, {fs, olds} ->
        cond do
          thread_file_name?(name) ->
            {mt, _} = Util.file_mtime(Config.app_path([folder, name]))
            {[{String.pad_leading(Integer.to_string(mt), 11, "0"), name} | fs], olds}

          want_old ->
            o = old_file_name(name)

            if o != "" and o not in olds do
              {fs, [o | olds]}
            else
              {fs, olds}
            end

          true ->
            {fs, olds}
        end
      end)

    files =
      Enum.sort_by(files, fn {mt, name} -> {mt, name} end, :desc)

    {files, old_names}
  end

  def count_threads(folder) do
    n =
      Enum.count(Util.list_dir_names(Config.app_path(folder)), &thread_file_name?/1)

    if Config.max_threads() > 0 and n > Config.max_threads(), do: Config.max_threads(), else: n
  end

  def total_pages(n) do
    p = div(n + Config.per_page() - 1, Config.per_page())
    if p < 1, do: 1, else: p
  end

  def page_clamp(folder, page) do
    cond do
      page <= 1 -> 1
      page > total_pages(count_threads(folder)) -> total_pages(count_threads(folder))
      true -> page
    end
  end

  def pager_html(folder, page, total) do
    if total <= 1 do
      ""
    else
      q = Util.url_encode(folder)

      href = fn
        1 -> "./"
        p -> "../amezo.cgi?folder=" <> q <> "&amp;page=" <> Integer.to_string(p)
      end

      {nums, _last} =
        Enum.reduce(1..total, {[], 0}, fn p, {acc, last_p} ->
          if total <= 10 or p == 1 or p == total or abs(p - page) <= 2 do
            acc = if last_p > 0 and p - last_p > 1, do: acc ++ ["…"], else: acc

            item =
              if p == page do
                "<b>[#{p}]</b>"
              else
                "<a href=\"" <> href.(p) <> "\">#{p}</a>"
              end

            {acc ++ [item], p}
          else
            {acc, last_p}
          end
        end)

      segments = []
      segments = if page > 1, do: segments ++ ["<a href=\"" <> href.(page - 1) <> "\">← 前の#{Config.per_page()}件</a>"], else: segments
      segments = segments ++ [Enum.join(nums, " ")]
      segments = if page < total, do: segments ++ ["<a href=\"" <> href.(page + 1) <> "\">次の#{Config.per_page()}件 →</a>"], else: segments

      "<div class=\"row links pager\">" <> Enum.join(segments, "　") <> "</div>\n"
    end
  end

  # {先頭行, 最後の7レスのリスト, レス行数, 読めたか}
  def read_thread_excerpt(path) do
    case Util.read_file_lines(path) do
      {[], _} ->
        {"", [], 0, false}

      {[first | rest], true} ->
        body = Enum.take_while(rest, fn l -> not String.starts_with?(l, "<form") end)
        last = if length(body) > 7, do: Enum.drop(body, length(body) - 7), else: body
        {first, last, length(body), true}

      _ ->
        {"", [], 0, false}
    end
  end

  # 板 index 用に、先頭行から html/head/body/meta/link/title/script を取り除く
  def strip_board_tags(line) do
    s = strip_blocks(line, "<title>", "</title>", 8)
    s = strip_blocks(s, "<script", "</script>", 9)
    strip_tag_chars(s)
  end

  defp strip_blocks(s, open, close, close_len) do
    case :binary.match(s, open) do
      :nomatch ->
        s

      {a, _olen} ->
        rest = binary_part(s, a, byte_size(s) - a)

        case :binary.match(rest, close) do
          :nomatch ->
            binary_part(s, 0, a)

          {b, _} ->
            strip_blocks(
              binary_part(s, 0, a) <>
                binary_part(rest, b + close_len, byte_size(rest) - b - close_len),
              open,
              close,
              close_len
            )
        end
    end
  end

  @strip_prefixes ["html", "/html", "head", "/head", "body", "/body", "meta", "link"]

  defp strip_tag_chars(s), do: strip_tag_chars(s, [])
  defp strip_tag_chars(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_tag_chars(<<c, rest::binary>>, acc) do
    if c == ?< do
      case :binary.match(rest, ">") do
        :nomatch ->
          strip_tag_chars(rest, [<<c>> | acc])

        {rel_end, 1} ->
          inside = binary_part(rest, 0, min(rel_end, 7))

          if Enum.any?(@strip_prefixes, &String.starts_with?(inside, &1)) do
            strip_tag_chars(binary_part(rest, rel_end + 1, byte_size(rest) - rel_end - 1), acc)
          else
            strip_tag_chars(rest, [<<c>> | acc])
          end
      end
    else
      strip_tag_chars(rest, [<<c>> | acc])
    end
  end

  # ---------- 見た目情報 ----------
  def board_view_info(folder) do
    {color, title} = Store.board_info(folder)
    suffix = if folder == "main", do: "(メイン)", else: ""

    {bg_attr, color} =
      case :binary.match(color, "!") do
        {bang, 1} ->
          {" background=\"" <> binary_part(color, bang + 1, byte_size(color) - bang - 1) <> "\"",
           binary_part(color, 0, bang)}

        :nomatch ->
          {"", color}
      end

    {text_attr, color} =
      if String.ends_with?(color, "*") do
        {" text=\"#ffffff\" link=\"red\" vlink=\"orange\"", binary_part(color, 0, byte_size(color) - 1)}
      else
        {"", color}
      end

    title = String.replace(title, "#c#", ",")

    {title0, name} =
      case :binary.match(title, "alt=\"") do
        {a, 5} ->
          rest = binary_part(title, a + 5, byte_size(title) - a - 5)

          case :binary.match(rest, "\"") do
            {b, 1} -> {binary_part(rest, 0, b), ""}
            :nomatch -> {title, Config.amezo_name()}
          end

        :nomatch ->
          {title, Config.amezo_name()}
      end

    %{
      title0: title0,
      amezo_name: name,
      suffix: suffix,
      bg_attr: bg_attr,
      color: color,
      text_attr: text_attr,
      title: title
    }
  end

  # ---------- index ページ ----------
  def write_index_page(folder, page, total, files, v) do
    pager = pager_html(folder, page, total)
    start = (page - 1) * Config.per_page()

    head =
      "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n" <>
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" <>
        "<link rel=\"stylesheet\" href=\"../style.css\">" <> Config.script_tag() <> "\n" <>
        "<title>" <> v.title0 <> v.amezo_name <> v.suffix <> "</title></head>\n" <>
        Config.copyright_text() <>
        "<body" <> v.bg_attr <> " bgcolor=\"" <> v.color <> "\"" <> v.text_attr <> ">\n" <>
        "<font size=+2>" <> v.title <> v.amezo_name <> v.suffix <> "</font>\n"

    header =
      case Util.read_file_string(Config.app_path("header.html")) do
        {h, true} -> h
        _ -> ""
      end

    headlines =
      files
      |> Enum.slice(start, Config.headline_count())
      |> Enum.with_index()
      |> Enum.map_join("", fn {{_mt, fname}, i} ->
        ttl =
          case Util.read_file_lines(Config.app_path([folder, fname])) do
            {[first | _], true} ->
              case Store.extract_first_b(first) do
                {b, true} -> b
                _ -> ""
              end

            _ ->
              ""
          end

        " #{start + i + 1}<a href=\"" <> fname <> "\">" <> ttl <> "</a>\n"
      end)

    kako_link =
      if kako_list_size(folder) > 0 do
        "<div class=\"row links\"><a href=\"" <> Config.kako_file() <> "\">過去ログ</a></div>\n"
      else
        ""
      end

    threads =
      files
      |> Enum.slice(start, Config.per_page())
      |> Enum.map_join("", fn {_mt, fname} ->
        {first, lines, n_lines, _} = read_thread_excerpt(Config.app_path([folder, fname]))

        first_html = if first != "", do: strip_board_tags(first) <> "\n", else: ""
        lines_html = Enum.map_join(lines, "", fn l -> l <> "\n" end)
        res_id = binary_part(fname, 0, byte_size(fname) - 5)

        sub_tag =
          if n_lines > 200 do
            "<input type=text name=\"from\" value=\"#{n_lines - 98}\" size=\"4\"><input type=submit name=\"sub\" value=\"〜\"> "
          else
            ""
          end

        links =
          "<div class=\"row links\"><a href=\"" <> res_id <>
            ".html\">レス全部を見る</a> " <> sub_tag <>
            "<a href=\"#top\">上へ</a> <a href=\"./\">リロード</a></div>"

        "<table border=1 cellspacing=1 cellpadding=2 width=100% bgcolor=\"#efefef\"><tr><td><font color=\"#000000\">\n" <>
          first_html <> lines_html <>
          "</font></td></tr></table>\n" <>
          Core.reply_form(res_id, links, Store.thread_is_locked(folder, res_id)) <> "<hr>\n"
      end)

    head <> header <> pager <> "<font size=2>\n<!-- HEAD LINE -->\n" <> headlines <>
      "<!-- HEAD LINE END -->\n</font>\n" <> kako_link <> threads <> pager <> "<hr></body></html>\n"
  end

  defp replace_index(tmp_path, index_path) do
    mode =
      case Util.file_mode(index_path) do
        {m, true} -> m
        _ -> 0o644
      end

    Util.chmod_file(tmp_path, mode)

    case File.rename(tmp_path, index_path) do
      :ok -> :ok
      _ -> File.rm(tmp_path); Amezo.Exit.page_error("indexを更新できません.")
    end
  end

  # {index名, 状態} を返す。状態は "done" / "cached"
  def regen_index(folder, page, reload_flag, use_cache) do
    page = if page < 1, do: 1, else: page
    v = board_view_info(folder)

    if page > 1 do
      regen_page_n(folder, page, use_cache, v)
    else
      regen_page_1(folder, reload_flag, use_cache, v)
    end
  end

  defp regen_page_n(folder, page, use_cache, v) do
    {files, _} = scan_threads(folder, false)

    files =
      if Config.max_threads() > 0 and length(files) > Config.max_threads() do
        Enum.take(files, Config.max_threads())
      else
        files
      end

    total = total_pages(length(files))
    page = if page > total, do: total, else: page

    if page == 1 do
      regen_index(folder, 1, true, use_cache)
    else
      index_name = "index#{page}.html"
      index_path = Config.app_path([folder, index_name])

      cached =
        use_cache and Config.page_cache() > 0 and
          case Util.file_mtime(index_path) do
            {mt, true} -> Util.epoch_now() - mt < Config.page_cache()
            _ -> false
          end

      if cached do
        {index_name, "cached"}
      else
        buf = write_index_page(folder, page, total, files, v)
        tmp = index_path <> ".tmp" <> to_string(:os.getpid())
        Util.write_file_string(tmp, buf)
        replace_index(tmp, index_path)
        {index_name, "done"}
      end
    end
  end

  defp regen_page_1(folder, reload_flag, use_cache, v) do
    index_name = "index.html"
    index_path = Config.app_path([folder, index_name])

    cached =
      use_cache and reload_flag and Config.post_interval() > 0 and
        case Util.file_mtime(index_path) do
          {mt, true} -> Util.epoch_now() - mt < Config.post_interval()
          _ -> false
        end

    if cached do
      {index_name, "cached"}
    else
      {files, old_names} = scan_threads(folder, kako_list_size(folder) <= 0)

      {files, retired} =
        if Config.max_threads() > 0 do
          {kept_rev, retired_rev, _n} =
            Enum.reduce(files, {[], [], 0}, fn f, {kept, retired, n} ->
              n = n + 1

              if n > Config.max_threads() do
                {_mt, fname} = f
                res = binary_part(fname, 0, byte_size(fname) - 5)

                if not Store.archived_exists(folder, res) and
                     Util.rename_path(
                       Config.app_path([folder, fname]),
                       Config.app_path([folder, "o" <> fname])
                     ) do
                  File.rm(Config.app_path([folder, res <> ".lock"]))
                  {kept, [f_retired(f) | retired], n}
                else
                  {kept, retired, n}
                end
              else
                {[f | kept], retired, n}
              end
            end)

          {Enum.reverse(kept_rev), Enum.reverse(retired_rev)}
        else
          {files, []}
        end

      kako_changed =
        cond do
          kako_list_size(folder) <= 0 ->
            if old_names != [] or retired != [] do
              names = old_names ++ Enum.map(retired, fn {_mt, name} -> name end)
              rebuild_kako_list(folder, names)
            else
              false
            end

          retired != [] ->
            append_kako_list(folder, retired)

          true ->
            false
        end

      has_kako = kako_list_size(folder) > 0
      buf = write_index_page(folder, 1, total_pages(length(files)), files, v)
      tmp = index_path <> ".tmp" <> to_string(:os.getpid())

      if not Util.write_file_string(tmp, buf) do
        Amezo.Exit.page_error("indexを書き込めません.")
      end

      replace_index(tmp, index_path)

      if has_kako and (kako_changed or not Util.file_regular?(Config.app_path([folder, Config.kako_file()]))) do
        write_kako(
          folder,
          "<body" <> v.bg_attr <> " bgcolor=\"" <> v.color <> "\"" <> v.text_attr <> ">",
          v.title0,
          v.amezo_name,
          v.suffix,
          v.title
        )
      end

      # 古い「次のページ」ファイルの掃除
      for name <- Util.list_dir_names(Config.app_path(folder)) do
        if index_n_file?(name) do
          case Util.file_mtime(Config.app_path([folder, name])) do
            {mt, true} ->
              if Util.epoch_now() - mt > 600, do: File.rm(Config.app_path([folder, name]))

            _ ->
              :ok
          end
        end
      end

      {index_name, "done"}
    end
  end

  defp f_retired({mt, fname}), do: {mt, "o" <> fname}

  defp index_n_file?(name) do
    byte_size(name) > 6 and String.starts_with?(name, "index") and
      String.ends_with?(name, ".html") and
      (fn c -> c >= ?0 and c <= ?9 end).(binary_part(name, 5, 1) |> :binary.first())
  end
end
