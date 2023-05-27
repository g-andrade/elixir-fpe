defmodule FPE.FF3_1 do
  # https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-38Gr1-draft.pdf

  import Bitwise
  require Record

  alias FPE.FFX

  ## Types

  @type radix :: 2..0xFFFF # 5.2, FF3-1 requirements
  @type tweak :: <<_::56>> # 5.2, Algorithm 9: FF3.Encrypt(K, T, X)

  Record.defrecordp(:ctx, [
    :k, :radix, :minlen, :maxlen
  ])

  @opaque ctx :: record(:ctx,
    k: FFX.key,
    radix: radix
  )

  ## API

  defguardp is_valid_key(k) when is_binary(k) and bit_size(k) in [128, 192, 256]
  defguardp is_valid_radix(radix) when is_integer(radix) and radix in 2..0xFFFF

  @spec new(k, radix) :: {:ok, ctx} | {:error, term}
  when k: FFX.key, radix: radix
  def new(k, _radix) when not is_valid_key(k), do: {:error, {:invalid_key, k}}
  def new(_k, radix) when not is_valid_radix(radix), do: {:error, {:invalid_radix, radix}}
  def new(k, radix) do
    with {:ok, minlen} <- calculate_minlen(radix),
         {:ok, maxlen} <- calculate_maxlen(minlen, radix)
    do
      {:ok, ctx(
        k: k,
        radix: radix,
        minlen: minlen,
        maxlen: maxlen
      )}
    else
      {:error, _} = error ->
        error
    end
  end

  @spec encrypt!(ctx, t, vX) :: vY
  when ctx: ctx, t: tweak, vX: String.t, vY: String.t
  def encrypt!(ctx, t, vX) do
    do_encrypt_or_decrypt!(ctx, t, vX, _enc = true)
  end

  @spec decrypt!(ctx, t, vX) :: vY
  when ctx: ctx, t: tweak, vX: String.t, vY: String.t
  def decrypt!(ctx, t, vX) do
    do_encrypt_or_decrypt!(ctx, t, vX, _enc = false)
  end

  ## Internal Functions

  defp calculate_minlen(radix) do
    # 5.2, FF3-1 requirements: radix ** minlen >= 1_000_000
    min_domain_size = 1_000_000
    case ceil(:math.log2(min_domain_size) / :math.log2(radix)) do
      minlen when minlen >= 2 ->
        # 5.2, FF3-1 requirements: 2 <= minlen <= [...]
        {:ok, minlen}
      minlen ->
        {:error, {:minlen_too_low, minlen}}
    end
  end

  defp calculate_maxlen(minlen, radix) do
    upper_limit = 2 * floor(96 / :math.log2(radix))

    case upper_limit do
      maxlen when maxlen >= minlen ->
        # 5.2, FF3-1 requirements: 2 <= minlen <= maxlen <= [...]
        {:ok, maxlen}
      maxlen ->
        {:error, {:maxlen_less_when_minlen, %{max: maxlen, min: minlen}}}
    end
  end

  defp do_encrypt_or_decrypt!(ctx, t, vX, enc) do
    with :ok <- validate_enc_or_dec_input(ctx, vX),
         :ok <- validate_tweak(t)
    do
        ctx(k: k, radix: radix) = ctx
        {even_m, odd_m, vA, vB, even_vW, odd_vW} = setup_encrypt_or_decrypt_vars!(t, vX)

        case enc do
          true ->
            do_encrypt_rounds!(_i = 0, k, radix, even_m, odd_m, vA, vB, even_vW, odd_vW)
          false ->
            do_decrypt_rounds!(_i = 7, k, radix, odd_m, even_m, vA, vB, odd_vW, even_vW)
        end
    else
      {whats_wrong, details_msg} ->
        raise ArgumentError, message: "Invalid #{whats_wrong}: #{inspect t}: #{details_msg}"
    end
  end

  defp validate_enc_or_dec_input(ctx, vX) do
    ctx(minlen: minlen, maxlen: maxlen) = ctx
    # TODO validate alphabet
    case byte_size(vX) do
      valid_size when valid_size in minlen..maxlen ->
        :ok
      _invalid_size ->
        {:input, "invalid size (not between #{minlen} and #{maxlen} symbols long"}
    end
  end

  defp validate_tweak(<<_::bits-size(56)>>), do: :ok
  defp validate_tweak(<<_::bits>>), do: {:tweak, "invalid size (not 56 bits long)"}
  defp validate_tweak(_), do: {:tweak, "not a 56 bits -long bitstring"}

  defp setup_encrypt_or_decrypt_vars!(t, vX) do
    n = byte_size(vX)

    # 1. Let u = ceil(n/2); v = n - u
    u = div(n, 2) + (n &&& 1)
    v = n - u

    # 2. Let A = X[1..u]; B = X[u + 1..n]
    <<vA::bytes-size(u), vB::bytes>> = vX

    # 3. Let T_L = T[0..27] || O⁴ and T_R = T[32..55] || T[28..31] || O⁴
    <<t_left::bits-size(28), t_middle::bits-size(4), t_right::bits-size(24)>> = t
    <<vT_L::bytes>> = <<t_left::bits, 0::4>>
    <<vT_R::bytes>> = <<t_right::bits, t_middle::bits, 0::4>>

    # 4.i. If i is even, let m = u and W = T_R, else let m = v and W = T_L
    even_m = u
    odd_m = v
    even_vW= vT_R
    odd_vW = vT_L
    {even_m, odd_m, vA, vB, even_vW, odd_vW}
  end

  defp do_encrypt_rounds!(i, k, radix, m, other_m, vA, vB, vW, other_vW) when i < 8 do
    # 4.ii. Let P = W ⊕ [i]⁴ || [NUM_radix(REV(B))]¹²
    vP_W_xor_i = :crypto.exor(vW, <<i::unsigned-size(4)-unit(8)>>)
    vP_num_radix_rev_B = FFX.num_radix(radix, FFX.rev(vB))
    vP = <<vP_W_xor_i::bytes, vP_num_radix_rev_B::unsigned-size(12)-unit(8)>>

    ## 4.iii. Let S = REVB(CIPH_REVB(K)(REVB(P)))
    vS_revb_P = FFX.revb(vP)
    vS_revb_K = FFX.revb(k)
    vS_ciph_etc = ciph(vS_revb_K, vS_revb_P)
    vS = FFX.revb(vS_ciph_etc)

    ## iv. Let y = NUM(S)
    y = FFX.num(vS)

    ## v. Let c = (NUM_radix(REV(A)) + y) mod (radix**m)
    c_rev_A = FFX.rev(vA)
    c_num_radix_rev_A_plus_y = FFX.num_radix(radix, c_rev_A) + y
    c = rem(c_num_radix_rev_A_plus_y, Integer.pow(radix, m))

    ## vi. Let C = REV(STR_m_radix(c))
    vC = FFX.rev(FFX.str_m_radix(m, radix, c))

    ## vii. Let A = B
    vA = vB

    ## viii. let B = C
    vB = vC

    do_encrypt_rounds!(
      i + 1, k, radix,
      _m = other_m, _other_m = m, # swap odd with even
      vA, vB,
      _vW = other_vW, _other_vW = vW # swap odd with even
    )
  end

  defp do_encrypt_rounds!(8 = _i, _k, _radix, _m, _other_m, vA, vB, _vW, _other_vW) do
    ## 5. Return A || B
    <<vA::bytes, vB::bytes>>
  end

  defp do_decrypt_rounds!(i, k, radix, m, other_m, vA, vB, vW, other_vW) when i >= 0 do
    # ii. Let P = W ⊕ [i]⁴ || [NUM_radix(REV(A))]¹²
    vP_W_xor_i = :crypto.exor(vW, <<i::unsigned-size(4)-unit(8)>>)
    vP_num_radix_rev_A = FFX.num_radix(radix, FFX.rev(vA))
    vP = <<vP_W_xor_i::bytes, vP_num_radix_rev_A::unsigned-size(12)-unit(8)>>

    ## iii. Let S = REVB(CIPH_REVB(K)(REVB(P)))
    vS_revb_P = FFX.revb(vP)
    vS_revb_K = FFX.revb(k)
    vS_ciph_etc = ciph(vS_revb_K, vS_revb_P)
    vS = FFX.revb(vS_ciph_etc)

    ## iv. Let y = NUM(S)
    y = FFX.num(vS)

    ## v. Let c = (NUM_radix(REV(B)) + y) mod (radix**m)
    c_rev_B = FFX.rev(vB)
    c_num_radix_rev_B_minus_y = FFX.num_radix(radix, c_rev_B) - y
    c = Integer.mod(c_num_radix_rev_B_minus_y, Integer.pow(radix, m))

    ## vi. Let C = REV(STR_m_radix(c))
    vC = FFX.rev(FFX.str_m_radix(m, radix, c))

    ## vii. Let B = A
    vB = vA

    ## viii. Let A = C
    vA = vC

    do_decrypt_rounds!(
      i - 1, k, radix,
      _m = other_m, _other_m = m,  # swap odd with even
      vA, vB,
      _vW = other_vW, _other_vW = vW # swap odd with even
    )
  end

  defp do_decrypt_rounds!(-1 = _i, _k, _radix, _m, _other_m, vA, vB, _vW, _other_vW) do
    ## 5. Return A || B
    <<vA::bytes, vB::bytes>>
  end

  defp ciph(k, input) do
    %{
      128 => :aes_128_ecb,
      192 => :aes_192_ecb,
      256 => :aes_256_ecb
    }
    |> Map.fetch!(bit_size(k))
    |> :crypto.crypto_one_time(k, input, _enc = true)
  end
end
