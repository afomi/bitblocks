defmodule Bitblocks.TxTypes do
  @moduledoc """
  Transaction types: the definitions behind `/types` and `/api/v1/types`.

  Each type is a script pattern or a data protocol, with prose (description,
  history, how it is spent), its spec link, a labelled pattern, related types,
  and where its real examples come from (`Bitblocks.TxTypes.Examples`).

  Definitions live in `priv/data/tx_types/types.json` and are read at compile
  time, so a change to the file recompiles this module. They move to a table
  when types become CRUD resources (phase 3 of afomi/bitblocks#49).

  `priv/data/tx_types/output_types_v1.json` is a byte-identical copy of the
  shared classification vectors from `@1sat/templates`. A type whose examples
  come from a script shape names its vector, and the tests check that the
  template hash in `types.json` is that vector's `Bitblocks.Script.template_hash/1`.
  A type drafted from a real output (`mix tx_types.propose`,
  `Bitblocks.TxTypes.Proposal`) names its vector in
  `priv/data/tx_types/chain_vectors.json` instead, beside the txid and vout it
  was read from.
  A type that belongs to a whole tx (`nlocktime`) names real txs in
  `priv/data/tx_types/tx_vectors.json` under `tx_vectors`, each with whether
  the classifier must give it that type.
  """

  @types_path Path.join([__DIR__, "..", "..", "priv", "data", "tx_types", "types.json"])
              |> Path.expand()
  @external_resource @types_path

  @data @types_path |> File.read!() |> Jason.decode!()

  defmodule Keys do
    @moduledoc false
    # The data file's keys, as atoms. Anything else (a stray key) stays a string.
    @atom_keys ~w(id title short group summary description history spec label url pattern
                  parts token note spendable spend related explore href examples kind vector
                  template_hashes shape standard protocols collections reason concepts term text
                  attribution license license_url source_url share_alike vectors tx_vectors)

    def atomize(map) when is_map(map) do
      Map.new(map, fn {key, value} ->
        key = if key in @atom_keys, do: String.to_atom(key), else: key
        {key, atomize(value)}
      end)
    end

    def atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
    def atomize(value), do: value
  end

  @types @data |> Map.fetch!("types") |> Keys.atomize()
  @groups @data |> Map.fetch!("groups") |> Keys.atomize()
  @by_id Map.new(@types, &{&1.id, &1})

  @type t :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:group) => String.t(),
          required(:summary) => String.t(),
          optional(atom()) => term()
        }

  defmodule NotFoundError do
    @moduledoc "No transaction type has this id. Renders as a 404."
    defexception [:id, plug_status: 404]

    @impl true
    def message(%{id: id}), do: "no transaction type #{inspect(id)}"
  end

  @doc "Every type, in the order of the data file."
  @spec all() :: [t()]
  def all, do: @types

  @doc "Every type id (slug)."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@types, & &1.id)

  @doc "The groups, each with its types, in order. Empty groups are left out."
  @spec groups() :: [map()]
  def groups do
    for group <- @groups,
        types = Enum.filter(@types, &(&1.group == group.id)),
        types != [] do
      Map.put(group, :types, types)
    end
  end

  @doc "A type by id, or nil."
  @spec get(String.t()) :: t() | nil
  def get(id) when is_binary(id), do: Map.get(@by_id, id)

  @doc "A type by id; raises `NotFoundError` (a 404) when there is none."
  @spec get!(String.t()) :: t()
  def get!(id) when is_binary(id), do: get(id) || raise(NotFoundError, id: id)

  @doc "The related types of `type`, resolved, in the order listed."
  @spec related(t()) :: [t()]
  def related(type),
    do: type |> Map.get(:related, []) |> Enum.map(&get/1) |> Enum.reject(&is_nil/1)

  # Opcode bytes with two names in the BSV library. `BSV.OpCode.to_atom/1`
  # picks one by map iteration order, which differs between boots, so rows
  # stamped before script analysis v7 may carry either name. Since v7
  # `Bitblocks.Script.template_hash/1` names each byte once (OP_1, OP_NOP2,
  # OP_NOP3), and the variants matter only until the v7 backfill has run
  # (afomi/bitblocks#49). Byte 0 is pinned to OP_FALSE by the library.
  @opcode_aliases %{
    81 => ["OP_1", "OP_TRUE"],
    177 => ["OP_CHECKLOCKTIMEVERIFY", "OP_NOP2"],
    178 => ["OP_CHECKSEQUENCEVERIFY", "OP_NOP3"]
  }

  @doc """
  Every template hash a stored row may carry for `script`, one per choice of
  name for each aliased opcode it contains (OP_1/OP_TRUE,
  OP_NOP2/OP_CHECKLOCKTIMEVERIFY, OP_NOP3/OP_CHECKSEQUENCEVERIFY), sorted.
  One of them is the canonical `Bitblocks.Script.template_hash/1`; the others
  are on rows stamped before script analysis v7. A script with no aliased
  opcode has exactly one.
  """
  @spec template_hash_variants(BSV.Script.t()) :: [String.t()]
  def template_hash_variants(%BSV.Script{chunks: chunks}) do
    tokens =
      Enum.map(chunks, fn
        chunk when is_binary(chunk) -> :push
        opcode when is_atom(opcode) -> BSV.OpCode.to_integer(opcode)
      end)

    aliased = tokens |> Enum.filter(&Map.has_key?(@opcode_aliases, &1)) |> Enum.uniq()

    aliased
    |> Enum.reduce([%{}], fn byte, choices ->
      for choice <- choices, name <- @opcode_aliases[byte], do: Map.put(choice, byte, name)
    end)
    |> Enum.map(fn names ->
      tokens
      |> Enum.map_join(" ", fn
        :push -> "PUSH"
        byte -> Map.get_lazy(names, byte, fn -> Atom.to_string(BSV.OpCode.to_atom(byte)) end)
      end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end)
    |> Enum.sort()
  end

  @doc """
  The type page for a token standard (`"bsv-20"`, `"bsv-21"`) or a collection
  standard (`"1Sat"`, `"Run"`), or nil when the standard has no type page.
  """
  @spec id_for_standard(String.t() | nil) :: String.t() | nil
  def id_for_standard("bsv-20"), do: "bsv-20"
  def id_for_standard("bsv-21"), do: "bsv-21"
  def id_for_standard("1Sat"), do: "1sat-inscription"
  def id_for_standard("Run"), do: "run"
  def id_for_standard(_), do: nil

  @doc """
  The type a registered protocol is, by name, whatever its punctuation:
  "BSV20" is `bsv-20`, "B://" is `b`. Nil when no type matches.
  """
  def for_protocol(name) when is_binary(name) do
    key = protocol_key(name)
    Enum.find(@types, &(key != "" and protocol_key(&1.short) == key))
  end

  defp protocol_key(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
  end
end
