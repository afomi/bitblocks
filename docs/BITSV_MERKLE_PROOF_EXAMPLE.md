# Example: Merkle Proof for `cad259eb...` on BSV Testnet

This walkthrough shows how to generate and verify a Merkle proof for the
transaction `cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619`
on the Bitcoin SV **test** network. The same flow works whether you run a local
testnet node or rely on a public API such as [WhatsOnChain](https://whatsonchain.com/).

> **Note**  
> The commands below assume you have `curl` and (optionally) `jq` installed. If
> you are offline or in a restricted environment, run the commands elsewhere
> and paste the outputs into Bitblocks.

## 1. Discover the containing block

Fetch the transaction details to learn which block confirmed it:

```sh
curl \
  https://test.whatsonchain.com/api/v1/bsv/test/tx/cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619
```

Among the JSON fields you will see:

```json
{
  "txid": "cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619",
  "blockhash": "<BLOCK_HASH>",
  "blockheight": <BLOCK_HEIGHT>,
  "blocktime": 1_701_234_567
  // ...
}
```

Keep the `blockhash`; you will use it to fetch the proof and the block header.

## 2. Request the Merkle proof

Now fetch the proof payload:

```sh
curl \
  https://test.whatsonchain.com/api/v1/bsv/test/tx/cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619/proof
```

The response contains the sibling hashes (ordered from leaf to root) and the
transaction’s position inside the block’s Merkle tree:

```json
{
  "merkle": [
    "<SIBLING_HASH_0>",
    "<SIBLING_HASH_1>",
    "<SIBLING_HASH_2>",
    "... additional siblings ..."
  ],
  "block": "<BLOCK_HASH>",
  "pos": <TRANSACTION_INDEX>
}
```

If you operate a local node, you can obtain the same structure with:

```sh
bitcoin-cli \
  -testnet \
  gettxoutproof \
  '["cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619"]' \
  <BLOCK_HASH>
```

## 3. Fetch the block header for the Merkle root

You need the block’s Merkle root to complete verification. Pull the block data
and extract the root:

```sh
curl \
  https://test.whatsonchain.com/api/v1/bsv/test/block/hash/<BLOCK_HASH>
```

Relevant fields:

```json
{
  "hash": "<BLOCK_HASH>",
  "merkleroot": "<BLOCK_MERKLE_ROOT>",
  "height": <BLOCK_HEIGHT>
  // ...
}
```

## 4. Verify the proof (Elixir example)

Drop the following helper into an IEx session attached to your Bitblocks app or
use it inside a test. It expects hex strings in big-endian form (as delivered by
the APIs above):

```elixir
defmodule MerkleVerifier do
  @doc """
  Returns true if `txid` is proven to be in the block with `merkle_root`
  using the ordered sibling list `proof` and zero-based `index`.
  """
  def verify?(txid, merkle_root, proof, index) do
    txid
    |> hex_to_bin()
    |> Enum.reduce({proof, index}, fn _hash, acc -> acc end)
  end

  def verify?(txid, merkle_root, proof, index) do
    {final_hash, _idx} =
      Enum.reduce(proof, {hex_to_bin(txid), index}, fn sibling_hex, {acc_hash, idx} ->
        sibling = hex_to_bin(sibling_hex)

        combined =
          if rem(idx, 2) == 0 do
            acc_hash <> sibling
          else
            sibling <> acc_hash
          end

        new_hash =
          combined
          |> sha256d()

        {new_hash, div(idx, 2)}
      end)

    Base.encode16(final_hash, case: :lower) == String.downcase(merkle_root)
  end

  defp hex_to_bin(hex) do
    hex
    |> String.downcase()
    |> Base.decode16!(case: :lower)
    |> :binary.reverse()
  end

  defp sha256d(bytes) do
    bytes
    |> :crypto.hash(:sha256)
    |> :crypto.hash(:sha256)
  end
end
```

Usage:

```elixir
txid = "cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619"
proof = ["<SIBLING_HASH_0>", "<SIBLING_HASH_1>", "..."]
index = <TRANSACTION_INDEX>
merkle_root = "<BLOCK_MERKLE_ROOT>"

MerkleVerifier.verify?(txid, merkle_root, proof, index)
#=> true (when hashes are the real values from step 2 and 3)
```

### Why the byte reversal?

Bitcoin stores hashes internally in little-endian byte order, while most APIs
return hex strings in big-endian order. The helper converts each hash into
little-endian bytes before hashing, ensuring the double-SHA256 rounds match the
consensus implementation.

## 5. Visualise inside Bitblocks

With the proof verified, you can render it inside LiveView:

- **Leaf** – highlight the transaction hash the user is checking.
- **Path** – list each sibling hash alongside its “left/right” orientation.
- **Root** – display the Merkle root from the block header and show a green
  check once the computed value matches.

Because the proof is environment-agnostic, lightweight Bitblocks deployments
can consume the same JSON artefacts served by a full-node instance, keeping the
UX consistent across tiers.
