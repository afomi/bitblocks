defmodule Bitblocks.ElectionFixtures do
  @moduledoc """
  Election records as a wallet would write them (`docs/ELECTION_DOGFOOD.md`):
  a MAP `SET`, the roll's B:// file ahead of it, and an AIP signature over
  everything to its left, made here with keys generated for the test. Nothing
  here is a funded key.

  `block/3` mines a block of such txs with a header that really meets its
  (easy) target, so `Chain.Headers` verifies it, `Chain.MerkleProof` proves
  its txs, and an archive's headers chain as a real chain does.
  """

  import Bitblocks.ChainFixtures

  alias Bitblocks.{Aip, SyntheticBlock}
  alias Bitblocks.Elections.Records

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  # Regtest's target: about one hash in two meets it.
  @bits 0x207FFFFF

  @doc "A fresh key and its P2PKH address, as AIP writes it."
  def key do
    privkey = BSV.PrivKey.new()

    address =
      privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

    %{privkey: privkey, address: address}
  end

  @doc "MAP SET fields for a record of `type` with `pairs` ([{key, value}])."
  def map_fields(type, pairs, opts \\ []) do
    app = Keyword.get(opts, :app, Records.app())
    kvs = Enum.flat_map([{"app", app}, {"type", type} | pairs], fn {k, v} -> [k, v] end)
    [@map, "SET" | kvs]
  end

  @doc "An election record's fields. `roll` is `{outpoint, sha256}`."
  def election_fields({roll, roll_sha256}, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "name" => "PBA Board 2026",
          "number_elected" => "2",
          "votes_allowed" => "2",
          "candidates" =>
            Jason.encode!([
              %{"id" => "alice", "name" => "Alice"},
              %{"id" => "bob", "name" => "Bob"},
              %{"id" => "carol", "name" => "Carol"}
            ]),
          "opens_at_height" => "12",
          "closes_at_height" => "15",
          "roll" => roll,
          "roll_sha256" => roll_sha256
        },
        attrs
      )

    pairs = for k <- Enum.sort(Map.keys(attrs)), not is_nil(attrs[k]), do: {k, attrs[k]}
    map_fields("election_v1", pairs)
  end

  @doc "The roll file's bytes for `addresses`, sorted and unique."
  def roll_file(addresses),
    do: Jason.encode!(%{"members" => addresses |> Enum.uniq() |> Enum.sort()})

  @doc "A roll record's fields: its B:// file, then the MAP."
  def roll_fields(content) do
    [@b, content, "application/json", "utf-8", "roll.json", "|"] ++ map_fields("roll_v1", [])
  end

  @doc "A ballot's fields."
  def ballot_fields(election, choices) do
    choices = if is_binary(choices), do: choices, else: Jason.encode!(choices)
    map_fields("ballot_v1", [{"election", election}, {"choices", choices}])
  end

  @doc """
  A data output: `fields`, then an AIP by `signer` over everything to their
  left. Options: `unsigned`, `bad_signature`, `indexes` (field indexes to
  sign, as decimal text: 0 is OP_RETURN, 1 the first field).
  """
  def output(fields, signer, opts \\ []) do
    aip =
      if opts[:unsigned] do
        []
      else
        message = message(fields, opts[:indexes])
        signature = BSV.Message.sign(message, signer.privkey, encoding: :raw)
        signature = if opts[:bad_signature], do: flip(signature), else: signature
        ["|", Aip.prefix(), "BITCOIN_ECDSA", signer.address, signature] ++ (opts[:indexes] || [])
      end

    %BSV.TxOut{satoshis: 0, script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN] ++ fields ++ aip}}
  end

  # Without indexes AIP signs OP_RETURN (0x6a), every field and the "|"; with
  # them, only the fields they name, in their order.
  defp message(fields, nil), do: IO.iodata_to_binary([<<0x6A>>, fields, "|"])

  defp message(fields, indexes) do
    cells = List.to_tuple([<<0x6A>> | fields] ++ ["|"])
    indexes |> Enum.map(&elem(cells, String.to_integer(&1))) |> IO.iodata_to_binary()
  end

  defp flip(<<head::binary-40, byte, rest::binary>>),
    do: <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

  @doc "A tx's raw bytes, spending one random input, with `outputs`."
  def tx(outputs) do
    in_tx = %BSV.TxIn{outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0}}

    %BSV.Tx{inputs: [in_tx], outputs: outputs}
    |> Bitblocks.OrdinalFixtures.raw_tx_hex()
    |> Base.decode16!(case: :lower)
  end

  @doc "The display txid of raw tx bytes."
  def txid(bytes), do: Bitblocks.TxStore.txid(bytes)

  @doc """
  Mines and stores a `completed` block at `height` on `prev` (display hex)
  holding a coinbase and `txs` (raw bytes), and stores each tx's row as the
  pipeline would tag it. Returns the block's display hash.
  """
  def block(height, prev, txs) do
    all = [SyntheticBlock.coinbase() | txs]
    hashes = Enum.map(all, &SyntheticBlock.sha256d/1)
    root = SyntheticBlock.merkle_root(hashes)
    {header, nonce} = mine(prev, root, height)
    hash = SyntheticBlock.display(SyntheticBlock.sha256d(header))

    block_fixture(%{
      height: height,
      hash: hash,
      prevblockhash: prev,
      merkleroot: SyntheticBlock.display(root),
      version: 1,
      time: 1_700_000_000 + height,
      bits: Integer.to_string(@bits, 16) |> String.downcase(),
      nonce: nonce,
      num_tx: length(all),
      tx: Enum.map(hashes, &SyntheticBlock.display/1),
      sync_state: "completed"
    })

    Enum.each(txs, &store_tx(&1, height, hash))
    hash
  end

  @doc "Stores a tx row at `height` under `block_hash`, tagged as the pipeline tags it."
  def store_tx(bytes, height, block_hash) do
    hex = Base.encode16(bytes, case: :lower)
    {:ok, analysis} = Bitblocks.TransactionParser.analyze(hex)

    transaction_fixture(%{
      txid: txid(bytes),
      raw: hex,
      block_height: height,
      block_hash: block_hash,
      protocols: analysis.protocols,
      aip_signers: analysis.aip_signers
    })
  end

  @doc """
  A whole election on a mined chain, as `docs/ELECTION_DOGFOOD.md` describes
  it: the roll in block 9, the election in block 10 (opens 12, closes 15,
  two seats, two votes each), and ballots:

    * `early` at 11 by one: before_open
    * `first` at 12 by one, replaced by `second` at 13 by one: counted
    * `outsider` at 13, a key not on the roll: not_on_roll
    * `unsigned` at 14: no_signature
    * `other` at 14 by three, for another election: not gathered
    * `two` at 15 by two, the closing block: counted
    * `late` at 16 by three: after_close
    * `orphaned` stored at 14 under a block our headers no longer hold: unconfirmed

  Blocks run to `through` (default 21, closes + 6); 0..8 are filler.
  Returns the keys, the election's outpoint and each ballot's txid.
  """
  def scenario(opts \\ []) do
    through = Keyword.get(opts, :through, 21)
    [admin, one, two, three, outsider] = for _ <- 1..5, do: key()

    content = roll_file([one.address, two.address, three.address])
    roll_tx = tx([output(["filler"], admin), output(roll_fields(content), admin)])
    roll = "#{txid(roll_tx)}.1"
    sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    election_tx = tx([output(election_fields({roll, sha}), admin)])
    election = "#{txid(election_tx)}.0"
    elsewhere = "#{random_hash()}.0"

    ballot = fn choices, signer, opts ->
      tx([output(ballot_fields(election, choices), signer, opts)])
    end

    b = %{
      early: ballot.(["alice"], one, []),
      first: ballot.(["alice", "bob"], one, []),
      second: ballot.(["carol"], one, []),
      outsider: ballot.(["alice"], outsider, []),
      unsigned: ballot.(["bob"], two, unsigned: true),
      other: tx([output(ballot_fields(elsewhere, ["alice"]), three)]),
      two: ballot.(["carol", "bob"], two, []),
      late: ballot.(["alice"], three, []),
      orphaned: ballot.(["bob"], three, [])
    }

    by_height = %{
      9 => [roll_tx],
      10 => [election_tx],
      11 => [b.early],
      12 => [b.first],
      13 => [b.second, b.outsider],
      14 => [b.unsigned, b.other],
      15 => [b.two],
      16 => [b.late]
    }

    Enum.reduce(9..through//1, random_hash(), fn height, prev ->
      block(height, prev, Map.get(by_height, height, []))
    end)

    store_tx(b.orphaned, 14, random_hash())
    completed_chain_fixture(through)

    %{
      admin: admin,
      one: one,
      two: two,
      three: three,
      outsider: outsider,
      election: election,
      roll: roll,
      roll_content: content,
      roll_tx: roll_tx,
      election_tx: election_tx,
      txs: b,
      txids: Map.new(b, fn {k, bytes} -> {k, txid(bytes)} end)
    }
  end

  @doc "A random display hash, for a parent below the stored chain."
  def random_hash, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp mine(prev, root, height, nonce \\ 0) do
    prev_internal = prev |> Base.decode16!(case: :lower) |> reverse()

    header =
      <<1::little-32, prev_internal::binary, root::binary, 1_700_000_000 + height::little-32,
        @bits::little-32, nonce::little-32>>

    target = 0x7FFFFF * Integer.pow(256, 0x20 - 3)

    if :binary.decode_unsigned(SyntheticBlock.sha256d(header), :little) <= target,
      do: {header, nonce},
      else: mine(prev, root, height, nonce + 1)
  end

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
