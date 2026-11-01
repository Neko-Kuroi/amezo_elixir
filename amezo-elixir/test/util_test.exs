defmodule Amezo.UtilTest do
  use ExUnit.Case, async: true
  alias Amezo.Util

  test "dates" do
    # epoch 1793433455 = JST 2026-10-31 (土) 16:57:35
    assert Util.format_jst_date(1_793_433_455) == "2026年10月31日(土)16時57分35秒"
    assert Util.format_res_number(1_793_433_455) == "261031165735"
    assert Util.jst_to_epoch(2026, 10, 31, 16, 57, 35) == 1_793_433_455
    assert Util.format_admin_time(1_793_433_455) == "2026-10-31 16:57"
  end

  test "html chars len and ccut" do
    assert Util.html_chars_len("a&amp;b") == 3
    assert Util.html_chars_len("あいう") == 3
    assert Util.ccut("a&amp;bcdef", 3) == "a&amp;b"
    assert Util.ccut("あいうえお", 2) == "あい"
  end

  test "escape" do
    assert Util.html_escape(~s(<a>&"')) == "&lt;a&gt;&amp;&quot;&#39;"
    assert Util.html_unescape("&lt;a&gt;&amp;&quot;&#39;") == ~s(<a>&"')
  end

  test "url decode/encode" do
    assert Util.url_decode("%E3%81%82+%26") == "あ &"
    assert Util.url_decode("%zz") == "%zz"
    assert Util.url_encode("あ &") == "%E3%81%82%20%26"
  end

  test "utf8 lossy decode" do
    assert Util.utf8_decode(<<0xE3, 0x81, 0x82>>) == "あ"
    assert Util.utf8_decode(<<0xFF, ?a>>) == "\uFFFD" <> "a"
    assert Util.utf8_decode(<<0xE3, 0x81>>) == "\uFFFD\uFFFD"
  end

  test "digits" do
    assert Util.digits?("123", 1, -1)
    refute Util.digits?("12a", 1, -1)
    refute Util.digits?("", 1, -1)
    assert Util.all_digits?("007")
    refute Util.all_digits?("")
  end

  test "ip" do
    assert Util.ip_valid?("127.0.0.1")
    refute Util.ip_valid?("256.0.0.1")
    refute Util.ip_valid?("01.2.3.4")
    assert Util.ip_valid?("::1")
    assert Util.ip_valid?("2001:db8::1")
    refute Util.ip_valid?("2001:::1")
    assert Util.ip_unit("127.0.0.1") == "127.0.0.1"
    assert Util.ip_unit("2001:db8::1") == "20010db800000000"
    assert Util.ip_unit("::ffff:1.2.3.4") == "0000000000000000"
  end

  test "strip invisible" do
    assert Util.strip_invisible("a\u200Bb\uFEFFc") == "abc"
  end

  test "trim space includes fullwidth" do
    assert Util.trim_space("　 abc \n") == "abc"
  end
end
