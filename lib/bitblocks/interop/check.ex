defmodule Bitblocks.Interop.Check do
  @moduledoc """
  One check of a BEEF from the page at `/start/interop`, bounded for a caller
  no rate limiter sees: a LiveView event doesn't pass through the endpoint's plugs.

  The judgement is `Bitblocks.Chain.BeefVerifier`'s, and nothing here repeats
  it. This module turns input into bytes, holds it to the limit, and cuts the
  answer down to what a page should keep:

    * input is sized before any work is done on it;
    * the same `:beef_verify_max_bytes` as `POST /api/v1/beef/verify` applies to
      the decoded BEEF, so the page and the API agree on every input;
    * the answer keeps at most `max_rows/0` transactions, the subject first,
      and nothing that refers to the input's bytes.

  Every error is a fixed atom with a fixed sentence (`message/1`), so nothing
  from the input reaches the page but the hashes the verifier derives.
  """

  alias Bitblocks.Chain.BeefVerifier

  @max_bytes 4_000_000
  @max_rows 200

  # A pasted or wrapped hex file may break lines; not without end.
  @whitespace_allowance 64_000

  @raw_prefixes [
    <<0x01, 0x00, 0xBE, 0xEF>>,
    <<0x02, 0x00, 0xBE, 0xEF>>,
    <<0x01, 0x01, 0x01, 0x01>>
  ]

  @messages %{
    empty: "There's nothing to check yet. Paste BEEF as hex, or choose a file.",
    not_hex: "That isn't hex, or it has an odd number of digits.",
    no_file: "Choose a file first.",
    upload_not_ready: "That file hasn't finished uploading, or it wasn't accepted.",
    unreadable_file: "That file couldn't be read. Try choosing it again.",
    too_soon: "One check at a time. Give it a moment and try again.",
    over_budget: "That's the most checks we can take for now. Try again in a minute.",
    too_many_bumps: "This BEEF lists more BUMPs than the reader takes.",
    too_many_transactions: "This BEEF lists more transactions than the reader takes.",
    too_many_leaves: "This BEEF's BUMPs have more leaves than the reader takes.",
    truncated: "The bytes end before the BEEF does.",
    trailing_bytes: "There are bytes after the end of the BEEF.",
    unknown_format: "These bytes don't start with a BEEF version we can read.",
    varint_not_minimal: "A VarInt is longer than it needs to be.",
    block_height_out_of_range: "A BUMP names a block height past what a header can hold.",
    tree_height_out_of_range: "A BUMP's tree height is outside 1 to 64.",
    empty_level: "A BUMP has no leaves at level 0.",
    offset_out_of_range: "A BUMP has an offset that can't fit its tree.",
    duplicate_offset: "A BUMP has two leaves at one offset.",
    bad_leaf_flag: "A BUMP has a leaf flag outside BRC-74.",
    bad_duplicate_offset: "A BUMP has a duplicate leaf at an even offset.",
    bad_transaction: "A transaction has no inputs or no outputs. BEEF carries raw transactions.",
    bad_transaction_flag: "A transaction's format byte isn't one BEEF defines.",
    bump_index_out_of_range: "A transaction points to a BUMP that isn't there.",
    no_transactions: "This BEEF holds no transactions.",
    duplicate_transaction: "The same transaction appears twice.",
    transactions_out_of_order: "A transaction comes ahead of its parent.",
    atomic_subject_missing: "This Atomic BEEF names a subject it doesn't hold.",
    atomic_unrelated_transaction:
      "This Atomic BEEF holds a transaction outside its subject's ancestry."
  }

  @doc "The limit on a decoded BEEF, shared with `POST /api/v1/beef/verify`."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:bitblocks, :beef_verify_max_bytes, @max_bytes)

  @doc "The most input worth reading: a BEEF at the limit, as hex, with line breaks."
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: max_bytes() * 2 + @whitespace_allowance

  @doc "How many transactions a report keeps."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc """
  Checks raw BEEF bytes or BEEF as hex. `{:ok, report}` whatever the evidence
  shows, or `{:error, reason}` when there's no BEEF to judge.
  """
  @spec run(binary()) :: {:ok, map()} | {:error, atom()}
  def run(input) when is_binary(input) do
    with :ok <- within_input_limit(input),
         {:ok, bytes} <- decode(input),
         {:ok, answer} <- BeefVerifier.verify(bytes, max_bytes: max_bytes()) do
      {:ok, report(answer)}
    end
  end

  @doc "A plain sentence for an error from `run/1` or from the page."
  @spec message(atom()) :: String.t()
  def message(:too_large), do: "A BEEF can be at most #{max_bytes()} bytes."

  def message(reason) do
    Map.get(@messages, reason, "These bytes are not a BEEF we can read.")
  end

  defp within_input_limit(input) do
    if byte_size(input) > max_input_bytes(), do: {:error, :too_large}, else: :ok
  end

  defp decode(<<prefix::binary-size(4), _::binary>> = raw) when prefix in @raw_prefixes,
    do: {:ok, raw}

  defp decode(input) do
    case String.replace(input, [" ", "\t", "\r", "\n"], "") do
      "" -> {:error, :empty}
      hex -> if byte_size(hex) > max_bytes() * 2, do: {:error, :too_large}, else: unhex(hex)
    end
  end

  defp unhex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_hex}
    end
  end

  defp report(answer) do
    {subject, others} = Enum.split_with(answer.transactions, &(&1.txid == answer.subject_txid))

    %{
      format: answer.format,
      subject_txid: answer.subject_txid,
      status: answer.status,
      reason: answer.reason,
      detail: answer.detail,
      block_height: answer.block_height,
      block_hash: answer.block_hash,
      merkleroot: answer.merkleroot,
      confirmations: answer.confirmations,
      indexed_tip_height: answer.indexed_tip_height,
      claim: answer.claim,
      trust: answer.trust,
      not_checked: answer.not_checked,
      total: length(answer.transactions),
      counts: Enum.frequencies_by(answer.transactions, & &1.status),
      unused_bumps: length(answer.unused_bumps),
      rows: (subject ++ others) |> Enum.take(@max_rows) |> Enum.map(&row(&1, answer.subject_txid))
    }
  end

  defp row(entry, subject) do
    %{
      txid: entry.txid,
      subject: entry.txid == subject,
      status: entry.status,
      block_height: Map.get(entry, :block_height),
      index: Map.get(entry, :index),
      detail: entry.detail || plain(entry)
    }
  end

  defp plain(%{status: :proven, block_height: height}),
    do: "Its bytes sit under the merkle root in the header of block #{height}."

  defp plain(%{status: :anchored}),
    do:
      "It has no proof of its own, and its inputs lead, within this BEEF, to proven transactions."
end
