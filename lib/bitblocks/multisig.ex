defmodule Bitblocks.Multisig do
  @moduledoc """
  Who had to agree, and who did: bare multisig (`m <key>… n
  OP_CHECKMULTISIG`) read for people.

  `signers/2` takes a decoded tx and its inputs' previous outputs, as
  `Bitblocks.Chain.TxPipeline.Steps.SatsIn.stored_outputs/1` returns them
  (one query for the whole tx, never a previous tx's row or raw bytes,
  https://github.com/afomi/bitblocks/issues/107), and for each input that
  spends a bare multisig output says which of its keys produced the
  signatures in the unlocking script.

  Each signature is checked against this input's sighash (its flag byte,
  the previous output's script and value) with `BSV.Sig.sighash/4`, then
  against the keys in multisig order: `OP_CHECKMULTISIG` takes signatures
  in key order, so a signature is first tried against the keys after the
  last one matched. A signature that only matches an earlier key is
  `:out_of_order`, which the opcode would not accept; one checked against
  every key and matching none is `:no_match`.

  That is all this checks: which keys signed this input. It runs no script
  and says nothing about the rest of the tx.

  The work is bounded per page:

    * the inputs are scanned lazily, and only the first 20 candidates
      (an unlocking script of `OP_0` and pushes alone) are decoded;
    * an input reads at most as many signatures as its lock has keys;
    * one page spends at most 64 checks, where computing a sighash is one
      and each signature-against-key verify (about 1.3 ms) is one. The
      sighash is computed once per input and flag byte, so a 2-of-3 spend
      costs four or five checks.

  A signature past the budget is `:not_checked` with reason `:budget`; one
  whose sighash can't be computed (the BSV library raises on a legacy
  `SIGHASH_SINGLE` input with no matching output, where consensus signs the
  constant 1) is `:not_checked` with reason `:no_sighash`. Neither is ever
  reported as a key that didn't sign.
  """

  alias Bitblocks.Chain.TxPipeline.Steps.SatsIn

  @max_inputs 20
  @check_budget 64
  # The most keys a bare multisig lock can list (OP_16).
  @max_keys 16

  @type signature_result :: %{
          index: non_neg_integer(),
          key: non_neg_integer() | nil,
          result: :matched | :out_of_order | :no_match | :not_checked,
          reason: :budget | :no_sighash | nil
        }

  @type input_result :: %{
          vin: non_neg_integer(),
          txid: String.t(),
          vout: non_neg_integer(),
          status: :checked | :not_in_index,
          m: pos_integer() | nil,
          n: pos_integer() | nil,
          pubkeys: [String.t()],
          signatures: [signature_result()],
          signed: [non_neg_integer()],
          extra_pushes: non_neg_integer()
        }

  @doc "The most multisig inputs one page reads."
  def max_inputs, do: @max_inputs

  @doc "The most checks (sighashes and verifies) one page spends."
  def check_budget, do: @check_budget

  @doc """
  The multisig inputs of `tx`, in input order, each as an `t:input_result/0`,
  and whether later inputs were left unread past the first 20.

  `stored` is `%{{txid, vout} => output json}` for the previous outputs we
  hold. An input whose previous output is stored and is a bare multisig is
  `:checked`. One whose previous output isn't stored, but whose unlocking
  script has a multisig spend's shape (`OP_0` then signatures only), is
  `:not_in_index`: we can't say which keys signed. Every other input is
  left out.
  """
  @spec signers(BSV.Tx.t() | nil, map()) :: {[input_result()], boolean()}
  def signers(%BSV.Tx{inputs: inputs} = tx, stored) when is_map(stored) do
    candidates =
      inputs
      |> Stream.with_index()
      |> Stream.flat_map(fn {input, vin} -> candidate(input, vin, stored) end)
      |> Enum.take(@max_inputs)

    {results, _state} =
      Enum.map_reduce(candidates, %{budget: @check_budget, digests: %{}}, &check(tx, &1, &2))

    {results, more_inputs?(inputs, candidates)}
  end

  def signers(_tx, _stored), do: {[], false}

  # With the cap reached, whether any later input could still be a multisig
  # spend, read from its unlocking script's shape alone (no decode).
  defp more_inputs?(inputs, candidates) when length(candidates) == @max_inputs do
    last = List.last(candidates).vin

    inputs
    |> Enum.drop(last + 1)
    |> Enum.any?(&match?({:ok, _}, signature_pushes(&1.script)))
  end

  defp more_inputs?(_inputs, _candidates), do: false

  @doc """
  The sentence a lock reads as: "Locked to 2 of these 3 keys".
  """
  @spec lock_sentence(pos_integer(), pos_integer()) :: String.t()
  def lock_sentence(_m, 1), do: "Locked to this key"
  def lock_sentence(n, n), do: "Locked to all #{n} of these keys"
  def lock_sentence(m, n), do: "Locked to #{m} of these #{n} keys"

  @doc """
  A key in short form, its first and last eight hex digits:
  `0279be66…16f81798`.
  """
  @spec short_key(String.t()) :: String.t()
  def short_key(hex) when byte_size(hex) > 20,
    do: String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -8, 8)

  def short_key(hex), do: hex

  # An input is a candidate when its previous output is a stored bare
  # multisig, or isn't stored and its unlocking script looks like a
  # multisig spend.
  # Only an unlocking script that opens with OP_0 (the dummy item wallets
  # put there) and then pushes signatures alone is read, so every other
  # input (a P2PKH spend's signature and key, say) costs nothing more here.
  # A spend with some other dummy item is not shown.
  defp candidate(%BSV.TxIn{outpoint: outpoint, script: script}, vin, stored) do
    txid = BSV.OutPoint.get_txid(outpoint)
    vout = outpoint.vout

    case signature_pushes(script) do
      {:ok, signatures} -> candidate(txid, vout, vin, signatures, Map.fetch(stored, {txid, vout}))
      :error -> []
    end
  end

  defp candidate(txid, vout, vin, signatures, stored) do
    case stored do
      {:ok, json} ->
        case multisig_output(json, vout) do
          {:ok, txout, fields} ->
            [
              %{
                vin: vin,
                txid: txid,
                vout: vout,
                txout: txout,
                fields: fields,
                signatures: signatures
              }
            ]

          :error ->
            []
        end

      :error ->
        if Enum.all?(signatures, &der_signature?/1),
          do: [%{vin: vin, txid: txid, vout: vout, txout: nil, signatures: signatures}],
          else: []
    end
  end

  defp check(_tx, %{txout: nil} = c, state) do
    {read, extra} = Enum.split(c.signatures, @max_keys)

    {%{
       vin: c.vin,
       txid: c.txid,
       vout: c.vout,
       status: :not_in_index,
       m: nil,
       n: nil,
       pubkeys: [],
       signatures: for({_sig, i} <- Enum.with_index(read), do: not_checked(i, nil)),
       signed: [],
       extra_pushes: length(extra)
     }, state}
  end

  defp check(tx, %{fields: fields} = c, state) do
    keys = Enum.map(fields.pubkeys, &Base.decode16!(&1, case: :lower))
    n = length(keys)
    {read, extra} = Enum.split(c.signatures, n)

    {results, {_next, state}} =
      read
      |> Enum.with_index()
      |> Enum.map_reduce({0, state}, fn {sig, i}, {next, state} ->
        match_signature(tx, c, sig, i, keys, n, next, state)
      end)

    {%{
       vin: c.vin,
       txid: c.txid,
       vout: c.vout,
       status: :checked,
       m: fields.m,
       n: fields.n,
       pubkeys: fields.pubkeys,
       signatures: results,
       signed: for(%{result: :matched, key: k} <- results, do: k),
       extra_pushes: length(extra)
     }, state}
  end

  # Keys from `next` on first (multisig order), then the earlier ones, so an
  # out-of-order signature is named rather than called unmatched.
  defp match_signature(_tx, _c, _sig, i, _keys, _n, next, %{budget: 0} = state),
    do: {not_checked(i, :budget), {next, state}}

  defp match_signature(tx, c, sig, i, keys, n, next, state) do
    case digest(tx, c, sig, state) do
      {{:ok, der, hash}, state} ->
        order = Enum.to_list(next..(n - 1)//1) ++ Enum.to_list(0..(next - 1)//1)

        case find_key(order, keys, der, hash, state.budget) do
          {:found, k, budget} when k >= next ->
            {%{index: i, key: k, result: :matched, reason: nil},
             {k + 1, %{state | budget: budget}}}

          {:found, k, budget} ->
            {%{index: i, key: k, result: :out_of_order, reason: nil},
             {next, %{state | budget: budget}}}

          {:none, budget} ->
            {%{index: i, key: nil, result: :no_match, reason: nil},
             {next, %{state | budget: budget}}}

          :out_of_budget ->
            {not_checked(i, :budget), {next, %{state | budget: 0}}}
        end

      {:no_sighash, state} ->
        {not_checked(i, :no_sighash), {next, state}}

      {:out_of_budget, state} ->
        {not_checked(i, :budget), {next, state}}
    end
  end

  defp find_key([], _keys, _der, _hash, budget), do: {:none, budget}
  defp find_key(_order, _keys, _der, _hash, 0), do: :out_of_budget

  defp find_key([k | rest], keys, der, hash, budget) do
    if verify?(der, hash, Enum.at(keys, k)),
      do: {:found, k, budget - 1},
      else: find_key(rest, keys, der, hash, budget - 1)
  end

  # The sighash this signature commits to, from its own flag byte: computed
  # once per input and flag (each computation, raising or not, costs one
  # check), then read from `state.digests`.
  defp digest(_tx, _c, sig, state) when byte_size(sig) < 9, do: {:no_sighash, state}

  defp digest(tx, %{vin: vin, txout: txout}, sig, state) do
    size = byte_size(sig) - 1
    <<der::binary-size(size), flag>> = sig

    case Map.fetch(state.digests, {vin, flag}) do
      {:ok, cached} ->
        {with_der(cached, der), state}

      :error when state.budget == 0 ->
        {:out_of_budget, state}

      :error ->
        computed = sighash(tx, vin, txout, flag)

        state = %{
          state
          | budget: state.budget - 1,
            digests: Map.put(state.digests, {vin, flag}, computed)
        }

        {with_der(computed, der), state}
    end
  end

  defp with_der({:ok, hash}, der), do: {:ok, der, hash}
  defp with_der(:no_sighash, _der), do: :no_sighash

  defp sighash(tx, vin, txout, flag) do
    {:ok, BSV.Sig.sighash(tx, vin, txout, flag)}
  rescue
    _ -> :no_sighash
  end

  defp verify?(der, hash, pubkey) do
    Curvy.verify(der, hash, pubkey, hash: false) == true
  rescue
    _ -> false
  end

  defp not_checked(i, reason), do: %{index: i, key: nil, result: :not_checked, reason: reason}

  # The previous output as a TxOut whose script re-serialises to the stored
  # bytes (the sighash commits to those exact bytes), when it is a bare
  # multisig.
  # A bare multisig's output JSON is small (16 keys of 65 bytes is about
  # 2 KB of hex); a larger element is some other script, not decoded.
  defp multisig_output(json, _vout) when byte_size(json) > 16_384, do: :error

  defp multisig_output(json, vout) do
    with {:ok, %{"scriptPubKey" => %{"hex" => hex}}} <- Jason.decode(json),
         sats when is_integer(sats) <- SatsIn.output_value(json, vout),
         {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         {:ok, script} <- BSV.Script.from_binary(bytes),
         true <- BSV.Script.to_binary(script) == bytes,
         :multisig <- Bitblocks.Script.classify(script) do
      {:ok, %BSV.TxOut{satoshis: sats, script: script}, Bitblocks.Script.extract_fields(script)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The pushes after the leading OP_0 (the extra item OP_CHECKMULTISIG
  # pops), when that is all the unlocking script holds.
  defp signature_pushes(%BSV.Script{chunks: [op | [_ | _] = rest]})
       when op in [:OP_0, :OP_FALSE] do
    if Enum.all?(rest, &is_binary/1), do: {:ok, rest}, else: :error
  end

  defp signature_pushes(_script), do: :error

  # A DER signature plus its sighash flag byte: 0x30, length, body, flag.
  defp der_signature?(<<0x30, len, rest::binary>>), do: byte_size(rest) == len + 1
  defp der_signature?(_push), do: false
end
