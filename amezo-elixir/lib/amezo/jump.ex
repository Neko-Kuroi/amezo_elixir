defmodule Amezo.Jump do
  @moduledoc "署名つき中継ページ (Python 版 jump.py)"
  alias Amezo.{Config, Core, Crypto, Exit, Post, Req, Resp, Util}

  @jump_style ":root{color-scheme:light dark}body{font-family:sans-serif;max-width:40em;margin:1.5em auto;padding:0 1em;line-height:1.6}.url{word-break:break-all;border:1px solid #888;padding:.6em .8em;margin:.8em 0;font-family:monospace}.host{font-size:1.4em;font-weight:bold;word-break:break-all}.btns{margin:1.2em 0}.go,.back{display:inline-block;padding:.5em 1.6em;margin-right:.8em;border:1px solid #888;border-radius:6px;font-size:1em;text-decoration:none;cursor:pointer;background:transparent;color:inherit}.go{font-weight:bold}.note{font-size:.9em;opacity:.85}.warn{border:1px solid #c60;padding:.4em .7em;margin:.6em 0}.ad{margin:1.5em 0}.ad small{display:block;opacity:.7}.ad iframe{width:100%;height:260px;border:1px solid #888}"

  def jump_page(title, body, nonce, with_back) do
    back =
      if with_back do
        "<script nonce=\"" <> nonce <>
          "\">document.getElementById(\"back\").addEventListener(\"click\",function(){if(history.length>1){history.back();}else{window.close();}});</script>"
      else
        ""
      end

    Exit.bail(%Resp{
      status: 200,
      headers: [
        {"Content-Type", "text/html; charset=UTF-8"},
        {"Cache-Control", "no-store"},
        {"X-Robots-Tag", "noindex, nofollow"},
        {"Referrer-Policy", "no-referrer"},
        {"X-Content-Type-Options", "nosniff"},
        {"Content-Security-Policy",
         "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-" <> nonce <>
           "'; frame-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"}
      ],
      body:
        "<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"UTF-8\">" <>
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" <>
          "<meta name=\"robots\" content=\"noindex, nofollow\"><meta name=\"referrer\" content=\"no-referrer\">" <>
          "<title>" <> Util.html_escape(title) <> "</title><style>" <> @jump_style <> "</style></head><body><h2>" <>
          Util.html_escape(title) <> "</h2>" <> body <> back <> "</body></html>"
    })
  end

  # URL からホスト名を取り出す。取れなければ ""
  def parse_host(url) do
    case :binary.match(url, "://") do
      :nomatch ->
        ""

      {p, 3} ->
        rest = binary_part(url, p + 3, byte_size(url) - p - 3)
        auth_end = first_of(rest, [?/, ??, ?#])
        auth = binary_part(rest, 0, auth_end)

        auth =
          case :binary.matches(auth, "@") do
            [] -> auth
            matches -> binary_part(auth, (matches |> List.last() |> elem(0)) + 1, byte_size(auth) - (matches |> List.last() |> elem(0)) - 1)
          end

        cond do
          String.starts_with?(auth, "[") ->
            case :binary.match(auth, "]") do
              {e, 1} -> binary_part(auth, 0, e + 1)
              :nomatch -> auth
            end

          true ->
            case :binary.match(auth, ":") do
              {c, 1} -> binary_part(auth, 0, c)
              :nomatch -> auth
            end
        end
    end
  end

  defp first_of(s, chars) do
    Enum.reduce(chars, byte_size(s), fn c, acc ->
      case :binary.match(s, <<c>>) do
        {i, 1} -> min(acc, i)
        :nomatch -> acc
      end
    end)
  end

  def handle_jump(%Req{} = req) do
    Exit.run_handler(fn -> jump_main(req) end)
  end

  def jump_main(%Req{} = req) do
    nonce = Crypto.hex_encode(Crypto.random_octets(12))
    params = Post.parse_params(req.query_string)
    u = Post.form_get(params, "u")
    s = Post.form_get(params, "s")

    url =
      if byte_size(u) <= 3000 do
        case Crypto.b64url_decode(u) do
          nil -> nil
          raw -> if String.valid?(raw), do: raw, else: nil
        end
      end

    if is_nil(url) or not Core.jump_verify(url, s) do
      body =
        "<p>このリンクは、署名が合わないため、自動では開きません。<br>掲示板に投稿された URL ではないか、投稿のあとに署名の鍵が変わった可能性があります。</p>"

      body =
        if not is_nil(url) and Core.url_is_valid(url) do
          body <>
            "<p class=\"note\">URL (リンクにはしていません。確かめてから、自分で開いてください):</p><div class=\"url\">" <>
            Util.html_escape(url) <> "</div>"
        else
          body
        end

      body = body <> "<div class=\"btns\"><button type=\"button\" class=\"back\" id=\"back\">戻る</button></div>"
      jump_page("このリンクは使えません", body, nonce, true)
    end

    host = parse_host(url)
    host = if host == "", do: "(ホスト名を読み取れません)", else: host

    body =
      "<p>この掲示板に投稿された、外部サイトへのリンクです。移動先を確かめてから、「進む」を押してください。</p>" <>
        "<p class=\"note\">移動先のサイト</p><div class=\"host\">" <> Util.html_escape(host) <> "</div>" <>
        "<p class=\"note\">URL 全体</p><div class=\"url\">" <> Util.html_escape(url) <> "</div>"

    body =
      if String.contains?(String.downcase(host), "xn--") do
        body <>
          "<div class=\"warn\">ドメイン名に <code>xn--</code> が含まれています。見た目が似た別のサイトのことがあるので、特に注意してください。</div>"
      else
        body
      end

    body =
      body <>
        "<div class=\"btns\"><a class=\"go\" href=\"" <> Util.html_escape(url) <>
        "\" rel=\"noopener noreferrer nofollow\" referrerpolicy=\"no-referrer\">進む</a>" <>
        "<button type=\"button\" class=\"back\" id=\"back\">戻る</button></div>" <>
        "<p class=\"note\">このページは自動では転送しません。リンク先の内容について、掲示板は責任を負いません。</p>"

    body =
      if Util.file_regular?(Config.app_path("ad.html")) do
        body <>
          "<div class=\"ad\"><small>広告</small><iframe src=\"ad.html\" sandbox=\"allow-scripts allow-popups\" referrerpolicy=\"no-referrer\" loading=\"lazy\" title=\"広告\"></iframe></div>"
      else
        body
      end

    jump_page("外部サイトへ移動します", body, nonce, true)
  end
end
