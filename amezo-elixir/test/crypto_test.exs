defmodule Amezo.CryptoTest do
  use ExUnit.Case, async: false
  alias Amezo.Crypto

  # 秘密鍵を aa×32 に固定したときの他版共通ベクタ (テスト用に Secrets を介さず直接確かめる)
  @key :binary.copy(<<0xAA>>, 32)

  test "sha256" do
    assert Crypto.sha256_hex("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "pbkdf2" do
    assert Crypto.pbkdf2_sha256("password", "salt", 2, 32) |> Crypto.hex_encode() ==
             "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
  end

  test "hash roundtrip" do
    stored = Crypto.make_hash_with("adminpw", 1000, nil)
    assert String.starts_with?(stored, "pbkdf2_sha256$1000$")
    assert Crypto.verify_hash("adminpw", stored)
    refute Crypto.verify_hash("wrong", stored)
    refute Crypto.verify_hash("adminpw", "pbkdf2_sha256$abc$zz$zz")
    refute Crypto.verify_hash("adminpw", "")
  end

  test "trip vector" do
    digest = Crypto.hmac_sha256(@key, "testpw")

    trip =
      digest
      |> Crypto.base64_encode()
      |> String.slice(0, 10)
      |> String.replace("+", ".")
      |> String.replace("/", "_")

    assert trip == "LzM4cgqcw."
  end

  test "jump sign vector" do
    url = "https://example.com/?a=1&b=2"
    sig = Crypto.b64url_encode(Crypto.hmac_sha256(@key, "jump:" <> url)) |> String.slice(0, 22)
    assert sig == "YcP70X8lmTkV4tYoh5YGrM"
  end

  test "key hash vector" do
    assert Crypto.hmac_sha256_hex(@key, "key:ABCD2345EFGH2345IJKL2345") ==
             "f22f36da875f3f733d0214c3e77019e9e9b61c50b160a6e2c5fba07d554e3670"
  end

  test "b64url decode strictness" do
    assert Crypto.b64url_decode("") == nil
    assert Crypto.b64url_decode("a+b") == nil
    assert Crypto.b64url_decode("aGVsbG8") == "hello"
    assert Crypto.b64url_encode("hello") == "aGVsbG8"
  end

  test "base32 no padding" do
    assert Crypto.base32_encode(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>) |> String.length() == 24
  end

  test "constant time equal" do
    assert Crypto.constant_time_equal("abc", "abc")
    refute Crypto.constant_time_equal("abc", "abd")
    refute Crypto.constant_time_equal("abc", "ab")
  end
end
