defmodule Bitblocks.Elections.Compose do
  @moduledoc """
  Builds the roll and election records exactly as they'll be published
  (`docs/ELECTION_DOGFOOD.md`, "Records"), unsigned, for a wallet to sign.

  Bitblocks composes and never signs or sends a tx, as the Bitcom composer
  (`Bitblocks.Bitcom.compose/2`) does. Each record is one data output:

      OP_FALSE OP_RETURN <fields…>

  The wallet appends the AIP section before it signs the tx:

      | 15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva BITCOIN_ECDSA <address> <signature>

  with no field indexes, so the signature covers every field, over the bytes
  `message_hex` gives (`0x6a`, every field, then `|`, as `Bitblocks.Aip`
  reads it). `Bitblocks.Elections.Records` then reads the signed output back
  into the same election and roll; `test/bitblocks/elections/compose_test.exs`
  holds the two to that.

  The roll comes first. The election names the roll by its outpoint, which
  isn't known until the roll is broadcast, so `election/3` takes it.
  """

  alias Bitblocks.Aip
  alias Bitblocks.Elections.Records

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"

  @type record :: %{
          type: String.t(),
          pushes: [String.t()],
          covered: [%{index: pos_integer(), value: String.t()}],
          script_hex: String.t(),
          asm: String.t(),
          message_hex: String.t(),
          create_action: map(),
          create_action_json: String.t()
        }

  @doc "The B:// protocol prefix the roll's file sits behind."
  @spec b_prefix() :: String.t()
  def b_prefix, do: @b

  @doc "The MAP protocol prefix every record's fields sit behind."
  @spec map_prefix() :: String.t()
  def map_prefix, do: @map

  @doc """
  The roll file's exact bytes: `{"members": [...]}`, sorted and unique,
  compact JSON.
  """
  @spec roll_content([String.t()]) :: String.t()
  def roll_content(members),
    do: Jason.encode!(%{"members" => members |> Enum.uniq() |> Enum.sort()})

  @doc "The sha256 of `bytes`, lowercase hex: `roll_sha256` for the roll file."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  The roll record: its B:// file (`roll.json`, `application/json`), then the
  MAP `SET` with `type=roll_v1`. Adds `content` and `sha256` to the record.
  """
  @spec roll([String.t()], keyword()) :: record()
  def roll(members, opts \\ []) do
    content = roll_content(members)

    pushes =
      [@b, content, "application/json", "utf-8", "roll.json", "|"] ++
        map_set("roll_v1", [])

    pushes
    |> record("roll_v1", "Publish the election roll", opts)
    |> Map.merge(%{content: content, sha256: sha256(content)})
  end

  @doc """
  The election record's MAP `SET`, in the order Bitblocks writes it: `name`,
  `number_elected`, `votes_allowed`, `candidates` (one JSON array of
  `{"id", "name"}`), `opens_at_height`, `closes_at_height`, `roll`,
  `roll_sha256`. Integers are decimal ASCII with no leading zeros.

  `election` is the count's shape (`Bitblocks.Elections.Count`), with
  integers as integers; `roll` the roll's outpoint, `<txid>.<vout>`.
  """
  @spec election(map(), String.t(), String.t(), keyword()) :: record()
  def election(election, roll, roll_sha256, opts \\ []) do
    election
    |> election_pairs(roll, roll_sha256)
    |> then(&map_set("election_v1", &1))
    |> record("election_v1", "Publish the election", opts)
  end

  @doc """
  The election's fields as `[{key, value}]`, values as they go on chain.
  `roll` may be nil, for the template shown before the roll is broadcast.
  """
  @spec election_pairs(map(), String.t() | nil, String.t()) :: [{String.t(), String.t() | nil}]
  def election_pairs(election, roll, roll_sha256) do
    candidates =
      Enum.map(election["candidates"], fn c ->
        Jason.OrderedObject.new([{"id", c["id"]}, {"name", c["name"]}])
      end)

    [
      {"name", election["name"]},
      {"number_elected", Integer.to_string(election["number_elected"])},
      {"votes_allowed",
       Integer.to_string(election["votes_allowed"] || election["number_elected"])},
      {"candidates", Jason.encode!(candidates)},
      {"opens_at_height", Integer.to_string(election["opens_at_height"])},
      {"closes_at_height", Integer.to_string(election["closes_at_height"])},
      {"roll", roll},
      {"roll_sha256", roll_sha256}
    ]
  end

  defp map_set(type, pairs) do
    [@map, "SET", "app", Records.app(), "type", type] ++
      Enum.flat_map(pairs, fn {k, v} -> [k, v] end)
  end

  defp record(pushes, type, description, opts) do
    script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN | pushes]}
    script_hex = BSV.Script.to_binary(script, encoding: :hex)
    create_action = create_action(script_hex, type, Keyword.get(opts, :description, description))

    %{
      type: type,
      pushes: pushes,
      covered: pushes |> Enum.with_index(1) |> Enum.map(fn {v, i} -> %{index: i, value: v} end),
      script_hex: script_hex,
      asm: BSV.Script.to_asm(script),
      message_hex: IO.iodata_to_binary([<<0x6A>>, pushes, "|"]) |> Base.encode16(case: :lower),
      create_action: create_action,
      create_action_json: Jason.encode!(create_action, pretty: true)
    }
  end

  # A BRC-100 createAction request with the record as output 0. Outputs are
  # kept in order (randomizeOutputs false), so the record's outpoint is
  # <txid>.0 and change follows it.
  defp create_action(script_hex, type, description) do
    Jason.OrderedObject.new([
      {"description", description},
      {"labels", ["election", type]},
      {"outputs",
       [
         Jason.OrderedObject.new([
           {"lockingScript", script_hex},
           {"satoshis", 0},
           {"outputDescription", "#{type} record, AIP to add"}
         ])
       ]},
      {"options", Jason.OrderedObject.new([{"randomizeOutputs", false}])}
    ])
  end

  @doc """
  The AIP section a wallet appends to an output, for a signature by
  `address` over `message_hex`'s bytes. Shown on the page as the shape the
  wallet must add, never filled in by Bitblocks.
  """
  @spec aip_template() :: String.t()
  def aip_template, do: "| #{Aip.prefix()} BITCOIN_ECDSA <address> <signature>"
end
