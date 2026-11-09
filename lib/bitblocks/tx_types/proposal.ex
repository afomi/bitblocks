defmodule Bitblocks.TxTypes.Proposal do
  @moduledoc """
  `propose_type` (#51, step 5 of docs/TYPING_PIPELINE.md): drafts a new type
  from a real output no type matches yet, as a change to the data files that a
  person reviews in a pull request. Approval is merging the pull request.

  `draft/3` reads the tx's bytes (`TxStore.raw/1`, else WhatsOnChain, checked
  against the txid either way), takes its first `custom` output with the
  template hash asked for (from `Release.type_candidates/3`), and builds two
  things:

    * **A type** for `types.json`, matched by template hash: every
      opcode-name variant of the output's shape, the canonical one first, as
      the other template types list them. Its prose is the caller's; anything
      not given reads `TODO: …`, which `test/bitblocks/tx_types_test.exs`
      refuses, so the pull request can't pass until a person has written it.
    * **A vector** for `chain_vectors.json`: the output's script and sats, with
      the txid, vout and height it was read from.

  `write/2` puts both into the files under a source tree. The type goes in
  just before `custom`, as text, so the rest of the hand-formatted
  `types.json` is untouched. `output_types_v1.json` is a byte-identical copy
  of @1sat/templates' vectors and is never written here.

  A merged type changes what the classifier matches, so it also needs
  `Classifier`'s version bumped, then the tx_types backfill to re-stamp past
  rows (`docs/DERIVED_DATA.md`); `mix tx_types.propose` prints both steps.
  """

  alias Bitblocks.{Repo, Script, TxStore, TxTypes, Woc}
  alias Bitblocks.Chain.{RawTx, Transaction}
  alias Bitblocks.TxTypes.Classifier
  alias Jason.OrderedObject

  @types_file "priv/data/tx_types/types.json"
  @vectors_file "priv/data/tx_types/chain_vectors.json"

  @todo "TODO: "

  @doc "The marker a draft leaves where a person still has to write the prose."
  def todo, do: @todo

  @doc "Where the chain vectors live, relative to the source tree."
  def vectors_file, do: @vectors_file

  @type draft :: %{type: OrderedObject.t(), vector: OrderedObject.t(), vout: non_neg_integer()}

  @doc """
  Drafts type `id` from `txid`'s first `custom` output whose template hash is
  `template_hash`.

  Options (all strings unless noted): `:title`, `:short`, `:summary`,
  `:spend`, `:spec_label`, `:spec_url`, `:group` (default `other`),
  `:description` and `:history` (lists of sentences), `:related` (type ids),
  `:spendable` (boolean, default true).
  """
  @spec draft(String.t(), String.t(), String.t(), keyword()) :: {:ok, draft()} | {:error, term()}
  def draft(id, txid, template_hash, opts \\ []) do
    with :ok <- check_id(id),
         :ok <- check_group(opts[:group] || "other"),
         :ok <- check_related(opts[:related] || []),
         {:ok, bytes, height} <- tx_bytes(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes, case: :lower)),
         {:ok, vout, out} <- custom_output(tx, template_hash) do
      vector = "chain_" <> String.replace(id, "-", "_")

      hashes = [
        template_hash | List.delete(TxTypes.template_hash_variants(out.script), template_hash)
      ]

      {:ok,
       %{
         vout: vout,
         type: type_entry(id, vector, hashes, opts),
         vector:
           OrderedObject.new([
             {"name", vector},
             {"description", "#{id}: output #{vout} of #{txid}"},
             {"txid", txid},
             {"vout", vout},
             {"height", height},
             {"script_hex", BSV.Script.to_binary(out.script, encoding: :hex)},
             {"satoshis", out.satoshis}
           ])
       }}
    end
  end

  defp check_id(id) do
    cond do
      not (is_binary(id) and id =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/) -> {:error, {:not_a_slug, id}}
      TxTypes.get(id) -> {:error, {:type_exists, id}}
      true -> :ok
    end
  end

  defp check_group(group) do
    if group in Enum.map(TxTypes.groups(), & &1.id),
      do: :ok,
      else: {:error, {:unknown_group, group}}
  end

  defp check_related(ids) do
    case Enum.reject(ids, &TxTypes.get/1) do
      [] -> :ok
      unknown -> {:error, {:unknown_related, unknown}}
    end
  end

  # Our own copy first; WhatsOnChain for a tx we don't hold. Both are checked
  # against the txid, so a draft only ever quotes the chain's bytes.
  defp tx_bytes(txid) do
    case TxStore.raw(txid) do
      {:ok, bytes} ->
        {:ok, bytes, Repo.get_by(Transaction, txid: txid) |> then(&(&1 && &1.block_height))}

      {:error, _} ->
        with {:ok, [%{"hex" => hex} = tx | _]} <- Woc.txs([txid]),
             {:ok, bytes} <- Base.decode16(hex, case: :mixed),
             true <- TxStore.txid(bytes) == txid || {:error, :bytes_do_not_hash_to_txid} do
          {:ok, bytes, tx["blockheight"]}
        else
          {:ok, []} -> {:error, :tx_not_found}
          :error -> {:error, :bad_hex}
          error -> error
        end
    end
  end

  defp custom_output(%BSV.Tx{outputs: outputs}, template_hash) do
    outputs
    |> Enum.with_index()
    |> Enum.find(fn {out, _vout} -> Script.template_hash(out.script) == template_hash end)
    |> case do
      nil ->
        {:error, :no_output_with_that_template_hash}

      {out, vout} ->
        case Classifier.output_type(out.script, out.satoshis) do
          "custom" -> {:ok, vout, out}
          type -> {:error, {:already_typed, type}}
        end
    end
  end

  defp type_entry(id, vector, hashes, opts) do
    OrderedObject.new([
      {"id", id},
      {"title", opts[:title] || todo("a title")},
      {"short", opts[:short] || todo("a short name")},
      {"group", opts[:group] || "other"},
      {"summary", opts[:summary] || todo("one sentence on what it is")},
      {"description", sentences(opts[:description], "what the script checks")},
      {"history", sentences(opts[:history], "who made it, and when it first appeared")},
      {"spec",
       OrderedObject.new([
         {"label", opts[:spec_label] || todo("the spec's name")},
         {"url", opts[:spec_url] || "https://" <> todo("the spec's address")}
       ])},
      {"pattern",
       OrderedObject.new([
         {"parts",
          [OrderedObject.new([{"token", "<script>"}, {"label", todo("label each part")}])]}
       ])},
      {"spendable", Keyword.get(opts, :spendable, true)},
      {"vectors", [vector]},
      {"spend", opts[:spend] || todo("what unlocks it")},
      {"related", opts[:related] || []},
      {"examples",
       OrderedObject.new([
         {"kind", "template"},
         {"vector", vector},
         {"template_hashes", hashes}
       ])}
    ])
  end

  defp todo(what), do: @todo <> what

  defp sentences([_ | _] = list, _what), do: list
  defp sentences(_, what), do: [todo(what)]

  @doc """
  Writes a draft into the data files under `root` (the source tree): the type
  into `types.json` just before `custom`, the vector at the end of
  `chain_vectors.json`. Returns the two paths written.
  """
  @spec write(draft(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def write(%{type: type, vector: vector}, root) do
    types_path = Path.join(root, @types_file)
    vectors_path = Path.join(root, @vectors_file)

    with {:ok, types} <- File.read(types_path),
         {:ok, types} <- splice_type(types, type),
         {:ok, vectors} <- File.read(vectors_path),
         {:ok, vectors} <- Jason.decode(vectors, objects: :ordered_objects) do
      vectors = put_in(vectors["vectors"], vectors["vectors"] ++ [vector])
      File.write!(types_path, types)
      File.write!(vectors_path, Jason.encode!(vectors, pretty: true) <> "\n")
      {:ok, [types_path, vectors_path]}
    end
  end

  @custom ~s(    {\n      "id": "custom",)

  defp splice_type(types, type) do
    case String.split(types, @custom, parts: 2) do
      [before, rest] ->
        entry =
          type
          |> Jason.encode!(pretty: true)
          |> String.split("\n")
          |> Enum.map_join("\n", &("    " <> &1))

        {:ok, before <> entry <> ",\n" <> @custom <> rest}

      _ ->
        {:error, :custom_type_not_found}
    end
  end
end
