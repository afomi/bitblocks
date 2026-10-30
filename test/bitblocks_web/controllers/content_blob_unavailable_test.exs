defmodule BitblocksWeb.ContentBlobUnavailableTest do
  @moduledoc """
  The blob store is a cache for /content: when it can't be read or written
  (e.g. prod before the bucket exists), verified bytes are still served.
  """
  # async: false — swaps the TxStore adapter globally.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.OrdinalFixtures

  defmodule Unavailable do
    @behaviour Bitblocks.TxStore
    def put(_key, _bytes), do: {:error, :no_bucket_configured}
    def get(_key), do: {:error, :no_bucket_configured}
    def size(_key), do: {:error, :no_bucket_configured}
    def public_url(_key), do: nil
    def ready?, do: {:error, :no_bucket_configured}
  end

  setup do
    previous = Application.get_env(:bitblocks, Bitblocks.TxStore)
    Application.put_env(:bitblocks, Bitblocks.TxStore, adapter: Unavailable)
    on_exit(fn -> Application.put_env(:bitblocks, Bitblocks.TxStore, previous) end)
  end

  test "a tx fetched from WhatsOnChain is served even though it can't be cached" do
    cid = "#{String.duplicate("c", 64)}_0"
    txid = tx([funding_outpoint()], [item(cid, "T1", address())]) |> publish()

    conn = build_conn() |> get("/content/#{txid}_0")

    assert conn.status == 200
    assert conn.resp_body == "<svg/>"
  end
end
