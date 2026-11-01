defmodule Amezo.Dai do
  @moduledoc "板一覧 + 各板の HEAD LINE (Python 版 dai.py)"
  alias Amezo.{Config, Exit, Store, Util}

  @headline_max 20

  def read_headline(folder, folder_escaped) do
    case Util.read_file_lines(Config.app_path([folder, "index.html"])) do
      {lines, true} ->
        case Enum.find_index(lines, &String.contains?(&1, "<!-- HEAD LINE -->")) do
          nil ->
            []

          pos ->
            lines
            |> Enum.drop(pos + 1)
            |> Enum.take_while(fn l -> not String.contains?(l, "<!-- HEAD LINE END -->") end)
            |> Enum.take(@headline_max)
            |> Enum.map(fn l -> replace_first_digit_html(l, folder_escaped) end)
        end

      _ ->
        []
    end
  end

  # 最初の 数字.html だけを folder/数字.html に変える
  def replace_first_digit_html(line, folder_escaped) do
    replace_first_digit_html(line, folder_escaped, 0)
  end

  defp replace_first_digit_html(line, folder_escaped, i) do
    if i >= byte_size(line) do
      line
    else
      c = :binary.at(line, i)

      if c >= ?0 and c <= ?9 do
        j = skip_digits(line, i)

        if j + 5 <= byte_size(line) and binary_part(line, j, 5) == ".html" do
          binary_part(line, 0, i) <> folder_escaped <> "/" <> binary_part(line, i, byte_size(line) - i)
        else
          replace_first_digit_html(line, folder_escaped, j)
        end
      else
        replace_first_digit_html(line, folder_escaped, i + 1)
      end
    end
  end

  defp skip_digits(line, j) do
    if j < byte_size(line) and :binary.at(line, j) in ?0..?9 do
      skip_digits(line, j + 1)
    else
      j
    end
  end

  def handle_dai(_req) do
    body =
      Enum.reduce(Store.blist_lines(), [], fn line, acc ->
        if line == "" do
          acc
        else
          parts = String.split(line, ",")
          folder = hd(parts)
          color = Enum.at(parts, 1, "")
          title = Enum.at(parts, 2, "")

          if folder == "" or String.starts_with?(folder, ".") or String.contains?(folder, "/") or
               String.contains?(folder, "..") do
            acc
          else
            color =
              case :binary.match(color, "!") do
                {bang, 1} -> binary_part(color, 0, bang)
                :nomatch -> color
              end

            color =
              if String.ends_with?(color, "*"),
                do: binary_part(color, 0, byte_size(color) - 1),
                else: color

            title = String.replace(title, "#c#", ",")
            folder_escaped = Util.html_escape(folder)

            headlines =
              Enum.map_join(read_headline(folder, folder_escaped), "", fn hl -> hl <> "\n" end)

            table =
              "<table border=0 cellspacing=1 cellpadding=2 width=100% bgcolor=\"" <>
                Util.html_escape(color) <> "\"><tr><td>\n" <>
                "<a href=\"" <> folder_escaped <> "/\"><b><font size=\"3\" color=\"#F92500\">" <>
                title <> "</font></b></a>\n" <> headlines <> "</td></tr></table>\n"

            [table | acc]
          end
        end
      end)

    out =
      "<!DOCTYPE html>\n<html lang=\"ja\"><head>\n<meta charset=\"UTF-8\">\n" <>
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" <>
        "<base target=\"naka\">\n<link rel=\"stylesheet\" href=\"style.css\">\n" <>
        "<title>板一覧</title>\n</head><body>\n" <>
        (body |> Enum.reverse() |> Enum.join("")) <> "</body></html>\n"

    Exit.html_header_response(out, 200)
  end
end
