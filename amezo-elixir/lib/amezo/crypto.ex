defmodule Amezo.Crypto do
  @moduledoc """
  暗号まわりの薄いラッパ。SHA-256 / HMAC / PBKDF2 は OTP の :crypto、
  base64 / base64url / base32 は Base を使う (Python 版 hashlib / hmac / base64 と一致する)。
  """

  # ---------- 基本 ----------
  def sha256_octets(octs), do: :crypto.hash(:sha256, octs)
  def sha256_hex(octs), do: octs |> sha256_octets() |> hex_encode()

  def sha256_file(path) do
    case File.read(path) do
      {:ok, data} -> {sha256_hex(data), byte_size(data), true}
      _ -> {"", 0, false}
    end
  end

  def hmac_sha256(key, msg), do: :crypto.mac(:hmac, :sha256, key, msg)
  def hmac_sha256_hex(key, msg), do: key |> hmac_sha256(msg) |> hex_encode()

  def pbkdf2_sha256(password, salt, iterations, dklen),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, dklen)

  def hex_encode(octs), do: Base.encode16(octs, case: :lower)

  def hex_decode(s) do
    case Base.decode16(s, case: :mixed) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  def random_octets(n), do: :crypto.strong_rand_bytes(n)

  # 固定時間比較 (長さが違えば false)
  def constant_time_equal(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      xor_fold(a, b, 0) == 0
    else
      false
    end
  end

  defp xor_fold(<<>>, <<>>, acc), do: acc

  defp xor_fold(<<x, ra::binary>>, <<y, rb::binary>>, acc),
    do: xor_fold(ra, rb, Bitwise.bor(acc, Bitwise.bxor(x, y)))

  def constant_time_string_equal(a, b), do: constant_time_equal(a, b)

  # ---------- パスワードハッシュ (pbkdf2_sha256$回数$salt.hex$hash.hex) ----------
  @hash_scheme "pbkdf2_sha256"

  def make_hash(password), do: make_hash_with(password, Amezo.Config.hash_iterations(), nil)

  def make_hash_with(password, iterations, salt) do
    salt = salt || random_octets(16)
    dk = pbkdf2_sha256(password, salt, iterations, 32)
    @hash_scheme <> "$" <> Integer.to_string(iterations) <> "$" <> hex_encode(salt) <> "$" <> hex_encode(dk)
  end

  def verify_hash(password, stored) do
    parts = stored |> String.trim() |> String.split("$")

    with [scheme, iters_s, salt_hex, hash_hex] <- parts,
         true <- scheme == @hash_scheme,
         {iters, ""} <- Integer.parse(iters_s),
         true <- iters >= 1 and iters <= 5_000_000,
         salt when not is_nil(salt) <- hex_decode(salt_hex),
         expected when not is_nil(expected) <- hex_decode(hash_hex) do
      constant_time_equal(pbkdf2_sha256(password, salt, iters, 32), expected)
    else
      _ -> false
    end
  end

  # ---------- base64 / base64url / base32 ----------
  def base64_encode(octs), do: Base.encode64(octs)
  def b64url_encode(octs), do: Base.url_encode64(octs, padding: false)

  # 文字種が違う・形が壊れていれば nil (Python 版と同じ)
  def b64url_decode(""), do: nil

  def b64url_decode(s) do
    if s =~ ~r/\A[A-Za-z0-9_-]+\z/ do
      case Base.url_decode64(s, padding: false) do
        {:ok, bin} -> bin
        :error -> nil
      end
    else
      nil
    end
  end

  # パディングなしの base32 (Python の base64.b32encode から '=' を除いたもの)
  def base32_encode(octs), do: Base.encode32(octs, padding: false)
end
