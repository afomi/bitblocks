defmodule BitblocksWeb.BcatContentTest do
  # #15: a BCat file from its head tx. The txs here are built to the BCat
  # layout with real hashes; every chunk is checked against the head's txid.
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.OrdinalFixtures, only: [publish: 1]

  alias Bitblocks.{Bcat, TxStore}

  @head "15DHFxWZJT58f9nhyGnsRBqrgwK4W6h4Up"
  @part "1ChDHzdd1H4wSjgGMHyndZm6qxEDGjqpJL"

  defp push(data) when byte_size(data) < 76, do: <<byte_size(data), data::binary>>
  defp push(data) when byte_size(data) < 256, do: <<76, byte_size(data), data::binary>>
  defp push(data), do: <<78, byte_size(data)::little-32, data::binary>>

  defp tx(pushes) do
    script = IO.iodata_to_binary([<<0, 0x6A>> | Enum.map(pushes, &push/1)])

    bytes =
      <<1::little-32, 1, 7::size(256), 0::32, 0, 0xFFFFFFFF::32, 1, 0::64>> <>
        varint(byte_size(script)) <> script <> <<0::32>>

    {TxStore.txid(bytes), Base.encode16(bytes, case: :lower)}
  end

  defp varint(n) when n < 253, do: <<n>>
  defp varint(n) when n < 0x10000, do: <<253, n::little-16>>
  defp varint(n), do: <<254, n::little-32>>

  defp chunk(data), do: tx([@part, data])

  defp bcat_head(chunks, opts \\ []) do
    ids = for {txid, _hex} <- chunks, do: Base.decode16!(txid, case: :lower)

    tx(
      [@head, " ", opts[:mime] || "text/plain", opts[:charset] || "utf-8", "a file.txt", " "] ++
        ids ++ (opts[:after_pipe] || [])
    )
  end

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

  test "reads a real head from the chain: display byte order, then a pipe and an address" do
    %{"hex" => hex} =
      "test/support/data/mainnet/bcat_head.json" |> File.read!() |> Jason.decode!()

    assert {:ok, head} = hex |> Base.decode16!(case: :lower) |> Bcat.parse_head()

    assert head.info == "canonic.xyz"
    assert head.mime == "image/png"
    assert head.charset == nil
    assert head.filename == "Hypophysics-1754334922388.png"
    assert head.flag == nil

    # WhatsOnChain answers the first of these as written, and 404s it reversed.
    assert [
             "9175e42783df1021cf46f0011e7fde022d1ce1cc0170b87315fc49967112fcdf",
             "0975d5b13c1a00a3fb45fd277508bb3970a745ec0fa307c8a3c427759de6178f",
             "17bb964ee729af973fb3c0a019ffb34e3a4f0036ff13df20770cc9277074653c"
           ] = Enum.map(head.chunk_txids, & &1)
  end

  test "a 32-byte push after the pipe is not a chunk", %{conn: conn} do
    chunks = [chunk("only this")]
    {txid, _} = head = bcat_head(chunks, after_pipe: ["|", String.duplicate("x", 32)])
    Enum.each([head | chunks], &publish/1)

    assert conn |> get(~p"/content/bcat/#{txid}") |> response(200) == "only this"
  end

  test "a chunk of real size, carried by OP_PUSHDATA4", %{conn: conn} do
    data = :binary.copy("x", 1_000_000)
    chunks = [chunk(data)]
    {txid, _} = head = bcat_head(chunks)
    Enum.each([head | chunks], &publish/1)

    assert conn |> get(~p"/content/bcat/#{txid}") |> response(200) == data
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
