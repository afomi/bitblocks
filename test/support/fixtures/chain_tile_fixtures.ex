defmodule Bitblocks.ChainTileFixtures do
  @moduledoc """
  Bulk block rows for chain-tile tests: contiguous heights with a chosen
  sync_state, inserted in one statement, with `updated_at` far enough in the
  past that an incremental build sees them as settled.
  """

  alias Bitblocks.Chain.Block
  alias Bitblocks.Repo

  @doc """
  Inserts blocks for `heights`. Options: `state:` (default `completed`),
  `num_tx:` (default `height + 1`), `updated_at:` (NaiveDateTime, default one
  day ago).
  """
  def insert_blocks(heights, opts \\ []) do
    state = Keyword.get(opts, :state, "completed")

    at =
      Keyword.get(opts, :updated_at, NaiveDateTime.add(NaiveDateTime.utc_now(), -86_400, :second))

    at = NaiveDateTime.truncate(at, :second)

    rows =
      for height <- heights do
        %{
          hash:
            "tilehash_#{String.pad_leading(Integer.to_string(height), 9, "0")}"
            |> String.pad_trailing(64, "0"),
          height: height,
          time: 1_231_006_505 + height * 600,
          size: 285 + height,
          num_tx: Keyword.get(opts, :num_tx, height + 1),
          sync_state: state,
          tx: [],
          inserted_at: at,
          updated_at: at
        }
      end

    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(Block, &1))

    :ok
  end
end
