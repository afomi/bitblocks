defmodule BitblocksWeb.BcatContentTest do
  # #15: a BCat file from its head tx. The txs here are built to the BCat
  # layout with real hashes; every chunk is checked against the head's txid.
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.OrdinalFixtures, only: [publish: 1]

  alias Bitblocks.TxStore

  @head "15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"
  @part "1ChDHzdd1H4wSjgGMHyndZm6qxEDGjqpJL"

  defp push(data) when byte_size(data) < 76, do: <<byte_size(data), data::binary>>
  defp push(data) when byte_size(data) < 256, do: <<76, byte_size(data), data::binary>>

  defp tx(pushes) do
    script = IO.iodata_to_binary([<<0, 0x6A>> | Enum.map(pushes, &push/1)])

    bytes =
      <<1::little-32, 1, 7::size(256), 0::32, 0, 0xFFFFFFFF::32, 1, 0::64, byte_size(script)>> <>
        script <> <<0::32>>

    {TxStore.txid(bytes), Base.encode16(bytes, case: :lower)}
  end

  defp chunk(data), do: tx([@part, data])

  defp bcat_head(chunks, opts \\ []) do
    order = Keyword.get(opts, :order, & &1)

    ids =
      for {txid, _hex} <- chunks do
        txid |> Base.decode16!(case: :lower) |> order.()
      end

    tx(
      [@head, " ", opts[:mime] || "text/plain", opts[:charset] || "utf-8", "a file.txt", " "] ++
        ids
    )
  end

  defp reversed(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  test "joins the chunks in the head's order, with its type and sandbox", %{conn: conn} do
    chunks = [chunk("hello "), chunk("from "), chunk("the chain")]
    {txid, _} = head = bcat_head(chunks)
    Enum.each([head | chunks], &publish/1)

    conn = get(conn, ~p"/content/bcat/#{txid}")

    assert response(conn, 200) == "hello from the chain"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="a_file.txt")]
  end

  test "download=1 asks for a download", %{conn: conn} do
    chunks = [chunk("bytes")]
    {txid, _} = head = bcat_head(chunks)
    Enum.each([head | chunks], &publish/1)

    conn = get(conn, ~p"/content/bcat/#{txid}?download=1")

    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="a_file.txt")]
  end

  test "reads txid pushes written in internal byte order", %{conn: conn} do
    chunks = [chunk("one"), chunk("two")]
    {txid, _} = head = bcat_head(chunks, order: &reversed/1)
    Enum.each([head | chunks], &publish/1)

    assert conn |> get(~p"/content/bcat/#{txid}") |> response(200) == "onetwo"
  end

  test "a missing chunk is an error naming it, never a partial file", %{conn: conn} do
    [{missing, _} = gone, kept] = [chunk("gone"), chunk("kept")]
    {txid, _} = head = bcat_head([gone, kept])
    Enum.each([head, kept], &publish/1)

    body = conn |> get(~p"/content/bcat/#{txid}") |> json_response(404)

    assert body["missing_chunks"] == [missing]
    assert body["error"] =~ "not assembled"
  end

  test "a named tx that carries no chunk data is reported as missing", %{conn: conn} do
    not_a_chunk = tx(["something else"])
    {txid, _} = head = bcat_head([not_a_chunk])
    Enum.each([head, not_a_chunk], &publish/1)

    body = conn |> get(~p"/content/bcat/#{txid}") |> json_response(404)
    assert body["missing_chunks"] == [elem(not_a_chunk, 0)]
  end

  test "a source that can't answer is a 502, not a missing chunk", %{conn: conn} do
    chunks = [chunk("x")]
    {txid, _} = head = bcat_head(chunks)
    publish(head)

    Process.put(:woc_txs_error, :rate_limited)

    assert conn |> get(~p"/content/bcat/#{txid}") |> json_response(502)
  end

  test "a tx that isn't a head, and a bad txid, are refused", %{conn: conn} do
    {plain, _} = other = tx(["nothing"])
    publish(other)

    assert conn |> get(~p"/content/bcat/#{plain}") |> json_response(404)
    assert conn |> get(~p"/content/bcat/nope") |> json_response(400)
    assert conn |> get(~p"/content/bcat/#{String.duplicate("ab", 32)}") |> json_response(404)
  end

  test "a type the head declares that isn't a plain mime falls back to bytes", %{conn: conn} do
    chunks = [chunk("x")]
    {txid, _} = head = bcat_head(chunks, mime: "<script>")
    Enum.each([head | chunks], &publish/1)

    conn = get(conn, ~p"/content/bcat/#{txid}")
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end
end
