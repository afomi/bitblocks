defmodule BitblocksWeb.StartInteropLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.Interop.{Check, Vectors}
  alias Bitblocks.RealHeaders
  alias BitblocksWeb.StartLive.Interop

  @vectors Jason.decode!(Vectors.body())["vectors"]

  defp hex(id), do: Enum.find(@vectors, &(&1["id"] == id))["hex"]

  defp paste(view, input) do
    view |> form("#interop-paste-form", %{beef: input}) |> render_submit()
  end

  defp limit(bytes) do
    previous = Application.get_env(:bitblocks, :beef_verify_max_bytes)
    Application.put_env(:bitblocks, :beef_verify_max_bytes, bytes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :beef_verify_max_bytes, previous),
        else: Application.delete_env(:bitblocks, :beef_verify_max_bytes)
    end)
  end

  defp upload(view, name, content) do
    file_input(view, "#interop-upload-form", :beef, [%{name: name, content: content}])
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  describe "checking" do
    test "a mined transaction reads proven, with its block", %{conn: conn} do
      RealHeaders.insert(973_110)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("mainnet-v1"))

      assert has_element?(view, "#interop-report h3", "Proven")
      assert has_element?(view, "#interop-rows", "Block 973,110")
      assert has_element?(view, "#interop-report", "beef_v1")
    end

    test "a fresh payment reads anchored, its parent proven, per transaction", %{conn: conn} do
      RealHeaders.insert(814_435)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("brc62-example"))

      assert has_element?(view, "#interop-report h3", "Anchored")
      assert has_element?(view, "#interop-rows li", "Proven")
      assert has_element?(view, "#interop-rows li", "Anchored")
      assert has_element?(view, "#interop-rows li", "Subject")
      assert has_element?(view, "#interop-rows", "It has no proof of its own")
    end

    test "no header reads unknown, with the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("brc62-example"))

      assert has_element?(view, "#interop-report h3", "Unknown")
      assert has_element?(view, "#interop-rows", "We hold no header at this height.")
    end

    test "wrong evidence reads failed, with the reason", %{conn: conn} do
      RealHeaders.insert(813_706)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("failed-root-mismatch"))

      assert has_element?(view, "#interop-report h3", "Failed")
      assert has_element?(view, "#interop-rows", "is not the merkle root of the block we hold")
    end

    test "every answer says what it claims and what it doesn't", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("brc62-example"))

      assert has_element?(view, "#interop-report", "Inclusion in a block only.")
      assert has_element?(view, "#interop-report", "We trust our node")
      assert has_element?(view, "#interop-report", "Double spends")
      assert has_element?(view, "#interop-report", "Payment terms")
    end

    test "bytes that aren't a BEEF get a plain reason, and no report", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("refused-truncated"))

      assert has_element?(view, "#interop-error", "The bytes end before the BEEF does.")
      refute has_element?(view, "#interop-report")
    end
  end

  describe "hostile input" do
    test "markup is never echoed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      html = paste(view, "<script>alert('x')</script><img src=x onerror=alert(1)>")

      assert has_element?(view, "#interop-error", "That isn't hex")
      refute html =~ "onerror"
      refute html =~ "alert("
    end

    test "a field of the wrong shape is an answer, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      for params <- [%{"beef" => %{"a" => "b"}}, %{"beef" => ["a"]}, %{}] do
        render_hook(view, "check_paste", params)
        assert has_element?(view, "#interop-error", "nothing to check yet")
      end

      render_hook(view, "cancel_upload", %{"ref" => "no-such-ref"})
      render_hook(view, "cancel_upload", %{"ref" => %{"a" => "b"}})
      assert Process.alive?(view.pid)
    end

    test "the 4 MB limit holds in the page", %{conn: conn} do
      limit(16)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("mainnet-v1"))

      assert has_element?(view, "#interop-error", "at most 16 bytes")
      refute has_element?(view, "#interop-report")
    end

    test "input past the limit by a long way is refused the same way", %{conn: conn} do
      limit(16)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, String.duplicate("ab", Check.max_input_bytes()))

      assert has_element?(view, "#interop-error", "at most 16 bytes")
    end

    test "input is never kept in assigns", %{conn: conn} do
      RealHeaders.insert(814_435)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("brc62-example"))
      assert has_element?(view, "#interop-report")

      refute inspect(assigns_of(view), limit: :infinity, printable_limit: :infinity) =~
               hex("brc62-example")

      assert Enum.sort(Map.keys(assigns_of(view).report)) ==
               Enum.sort(~w(block_hash block_height claim confirmations counts detail format
                  indexed_tip_height merkleroot not_checked reason rows status subject_txid total
                  trust unused_bumps)a)
    end

    test "a second check straight after the first waits its turn", %{conn: conn} do
      RealHeaders.insert(973_110)
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      paste(view, hex("mainnet-v1"))
      assert has_element?(view, "#interop-report h3", "Proven")

      paste(view, hex("brc62-example"))

      assert has_element?(view, "#interop-error", "One check at a time")
      assert has_element?(view, "#interop-report h3", "Proven")
    end

    test "the paste form sends only on submit, so typing costs nothing", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/start/interop")

      assert has_element?(view, "#interop-paste-form[phx-submit='check_paste']")
      refute has_element?(view, "#interop-paste-form[phx-change]")
      refute html =~ ~s(maxlength)
      refute has_element?(view, "#interop-upload-form textarea")
    end
  end

  describe "uploading a file" do
    test "raw bytes", %{conn: conn} do
      RealHeaders.insert(973_110)
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      file = upload(view, "payment.beef", Base.decode16!(hex("mainnet-v1"), case: :lower))

      render_upload(file, "payment.beef")
      view |> form("#interop-upload-form") |> render_submit()

      assert has_element?(view, "#interop-report h3", "Proven")
      assert assigns_of(view).uploads.beef.entries == []
    end

    test "hex, with a trailing newline", %{conn: conn} do
      RealHeaders.insert(973_110)
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      file = upload(view, "payment.hex", hex("mainnet-v1") <> "\n")

      render_upload(file, "payment.hex")
      view |> form("#interop-upload-form") |> render_submit()

      assert has_element?(view, "#interop-report h3", "Proven")
    end

    test "a file past the limit is turned away by the upload itself", %{conn: conn} do
      limit(16)
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      too_big = String.duplicate("a", Check.max_input_bytes() + 1)

      render_upload(upload(view, "big.hex", too_big), "big.hex")

      assert has_element?(view, "#interop-upload-entries", "larger than a BEEF at the limit")

      view |> form("#interop-upload-form") |> render_submit()
      assert has_element?(view, "#interop-error", "hasn't finished uploading")
    end

    test "a raw file past the decoded limit is refused after the upload", %{conn: conn} do
      limit(16)
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      file = upload(view, "big.beef", <<0x01, 0x00, 0xBE, 0xEF>> <> :binary.copy(<<0>>, 64))

      render_upload(file, "big.beef")
      view |> form("#interop-upload-form") |> render_submit()

      assert has_element?(view, "#interop-error", "at most 16 bytes")
    end

    test "a hostile file name is escaped", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      file = upload(view, "<img src=x onerror=alert(1)>.beef", "00")
      render_upload(file, "<img src=x onerror=alert(1)>.beef", 50)

      refute render(view) =~ "<img src=x"
    end

    test "no file gets a plain answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      view |> form("#interop-upload-form") |> render_submit()

      assert has_element?(view, "#interop-error", "Choose a file first.")
    end

    test "submitting while a file is still arriving is an answer, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      file = upload(view, "payment.hex", hex("mainnet-v1"))

      render_upload(file, "payment.hex", 50)
      view |> form("#interop-upload-form") |> render_submit()

      assert has_element?(view, "#interop-error", "hasn't finished uploading")
    end
  end

  describe "the write-up" do
    test "the page covers both parties, one payment, and the gaps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      for section <- ~w(check claims vectors sender receiver pattern anchored-proven gaps) do
        assert has_element?(view, "##{section}")
      end

      assert has_element?(view, "#pattern", "Atomic BEEF")
      assert has_element?(view, "#pattern", "acceptance record")
      assert has_element?(view, "#pattern", "BRC-237")
      assert has_element?(view, "#anchored-proven", "Anchored doesn't mean accepted.")
    end

    test "says what's been tried, and names nobody as conforming", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      assert has_element?(view, "#interop-lede", "@bsv/sdk 2.4.0")
      assert has_element?(view, "#interop-lede", "no live wallet")
      assert has_element?(view, "#interop-lede", "Nothing here says any wallet or project")
      refute String.downcase(render(view)) =~ "qart"
      refute render(view) =~ "Bitcoin SV"
    end

    test "says what the check leaves out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")

      assert has_element?(view, "#claims", "doesn't run scripts")
      assert has_element?(view, "#claims", "double spends")
      assert has_element?(view, "#claims", "right payment was made")
    end

    test "the counts come from the file, and link to it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/interop")
      summary = Vectors.summary()

      assert summary.total == summary.valid + summary.invalid
      assert has_element?(view, "#vectors", "#{summary.total}")
      assert has_element?(view, "a#interop-vectors-link[href='/interop/vectors/v1.json']")
    end

    test "every not_checked name has its words" do
      for name <- ~w(scripts signatures input_amounts double_spends token_validity payment_terms) do
        assert is_binary(Interop.not_checked_label(name))
      end
    end

    test "the doc says the same things, and keeps to its form" do
      doc = File.read!("docs/INTEROP_KIT.md")

      for phrase <- [
            "`@bsv/sdk` 2.4.0",
            "no live wallet",
            "It does not check scripts",
            "## What a conforming sender does",
            "## What a conforming receiver does",
            "## One payment, end to end",
            "## Anchored and proven",
            "## Known gaps",
            "## Further experiments",
            "/interop/vectors/v1.json"
          ] do
        assert doc =~ phrase, phrase
      end

      refute String.downcase(doc) =~ "qart"
      refute doc =~ ~r/^[^|\n`]*[a-z]\. [A-Z][^\n]*$/m
    end
  end
end
