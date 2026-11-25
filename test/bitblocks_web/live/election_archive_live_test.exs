defmodule BitblocksWeb.ElectionArchiveLiveTest do
  @moduledoc """
  "Build the archive" on `/elections/:outpoint`
  (https://github.com/afomi/bitblocks/issues/136, step 5), and "Download the
  archive (.zip)". The admin gate is off in the suite (config/test.exs); the
  gate tests turn it on, as `user_auth_test.exs` does.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ElectionFixtures

  alias Bitblocks.Accounts
  alias Bitblocks.Elections.Archive

  defp unzip(bytes) do
    {:ok, entries} = :zip.unzip(bytes, [:memory])
    Map.new(entries, fn {path, data} -> {to_string(path), data} end)
  end

  describe "once the close is six blocks deep" do
    setup do
      %{s: scenario()}
    end

    test "builds, then lists every file with its sha256 and the archive_sha256",
         %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(
               view,
               ~s(#archive-status[data-status="ready"]),
               "Voting closed at block 15"
             )

      assert has_element?(view, "#archive-build-button", "Build the archive")
      refute has_element?(view, "#archive-build fieldset[disabled]")
      refute has_element?(view, "#archive-built")

      html = view |> form("#archive-build", %{"result_txid" => ""}) |> render_submit()
      {:ok, plan} = Archive.plan(s.election)

      assert has_element?(view, "#archive-sha256", plan.archive_sha256)

      for file <- plan.files do
        assert has_element?(view, "#archive-files li", file.path)
        assert html =~ file.sha256
      end

      for path <- Archive.beside(), do: assert(has_element?(view, "#archive-beside li", path))

      assert has_element?(view, "#archive-download", "Download the archive (.zip)")

      assert has_element?(
               view,
               ~s(#archive-download[href="/elections/#{s.election}/archive.zip?sha256=#{plan.archive_sha256}"])
             )
    end

    test "the page's tally and the archive's count.json come from the same count, and match",
         %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      {:ok, plan} = Archive.plan(s.election)
      count_json = Enum.find(plan.files, &(&1.path == "count.json")).bytes
      result = Jason.decode!(count_json)["result"]

      for %{"candidate" => id, "votes" => votes} <- result["tally"] do
        label = if votes == 1, do: "1 vote", else: "#{votes} votes"
        assert has_element?(view, "#candidate-#{id}", label)
        assert has_element?(view, "#candidate-#{id}", "Elected") == id in result["winners"]
      end
    end

    test "a bad result txid is named, and nothing is listed", %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      view |> form("#archive-build", %{"result_txid" => "nope"}) |> render_submit()

      assert has_element?(view, "#archive-error", "64 lowercase hex characters")
      refute has_element?(view, "#archive-built")
    end

    test "the result txid goes to the download link and the archive page",
         %{conn: conn, s: s} do
      txid = String.duplicate("cd", 32)
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      view |> form("#archive-build", %{"result_txid" => txid}) |> render_submit()
      {:ok, plan} = Archive.plan(s.election)

      href =
        "/elections/#{s.election}/archive.zip?sha256=#{plan.archive_sha256}&result_txid=#{txid}"

      assert has_element?(view, ~s(#archive-download[href="#{href}"]))

      conn = get(conn, href)
      assert conn.status == 200
      folder = Archive.folder(s.election)
      assert unzip(conn.resp_body)["#{folder}/index.html"] =~ txid
    end

    test "the zip download holds the archive's files and the three beside them",
         %{conn: conn, s: s} do
      {:ok, plan} = Archive.plan(s.election)
      conn = get(conn, "/elections/#{s.election}/archive.zip?sha256=#{plan.archive_sha256}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
      assert get_resp_header(conn, "x-archive-sha256") == [plan.archive_sha256]
      folder = Archive.folder(s.election)

      assert get_resp_header(conn, "content-disposition") |> hd() =~
               ~s(filename="#{folder}.zip")

      unzipped = unzip(conn.resp_body)

      assert Enum.sort(Map.keys(unzipped)) ==
               Enum.sort(Enum.map(plan.files ++ plan.beside, &"#{folder}/#{&1.path}"))

      for file <- plan.files, do: assert(unzipped["#{folder}/#{file.path}"] == file.bytes)
    end

    test "a download whose archive no longer hashes to the one shown is refused",
         %{conn: conn, s: s} do
      conn = get(conn, "/elections/#{s.election}/archive.zip?sha256=#{String.duplicate("0", 64)}")

      assert conn.status == 409
      assert conn.resp_body =~ "build it again"
    end
  end

  describe "before the close is six blocks deep" do
    setup do
      %{s: scenario(through: 18)}
    end

    test "the button is disabled, naming the blocks to go", %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(
               view,
               ~s(#archive-status[data-status="refused"]),
               "Builds once block 15 is 6 deep: 3 blocks to go."
             )

      assert has_element?(view, "#archive-build fieldset[disabled]")
      assert has_element?(view, "#archive-build-button", "Build the archive")

      # The event itself is refused too, not just the button.
      render_submit(view, "build_archive", %{"result_txid" => ""})
      refute has_element?(view, "#archive-built")
    end

    test "the download is refused with the same sentence", %{conn: conn, s: s} do
      conn = get(conn, "/elections/#{s.election}/archive.zip")

      assert conn.status == 409
      assert conn.resp_body =~ "Builds once block 15 is 6 deep: 3 blocks to go."
    end
  end

  describe "with the admin gate on" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:bitblocks, :admin_auth, previous),
          else: Application.delete_env(:bitblocks, :admin_auth)
      end)

      %{s: scenario()}
    end

    defp github_user(login, id) do
      {:ok, user} =
        Accounts.upsert_github_user(%Ueberauth.Auth{
          provider: :github,
          uid: id,
          info: %Ueberauth.Auth.Info{nickname: login, name: login},
          extra: %Ueberauth.Auth.Extra{raw_info: %{user: %{"id" => id, "login" => login}}}
        })

      user
    end

    test "a visitor sees the count but not the archive, and can't download it",
         %{conn: conn, s: s} do
      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")

      assert has_element?(view, "#candidate-carol", "2 votes")
      refute has_element?(view, "#election-archive")
      refute render(view) =~ "Build the archive"

      render_submit(view, "build_archive", %{"result_txid" => ""})
      refute has_element?(view, "#archive-built")

      conn = get(build_conn(), "/elections/#{s.election}/archive.zip")
      assert conn.status in [302, 503]
      refute get_resp_header(conn, "content-type") |> Enum.any?(&(&1 =~ "zip"))
    end

    test "a signed-in member who isn't an admin gets a 403 for the zip", %{conn: conn, s: s} do
      user = github_user("member", 4242)
      conn = init_test_session(conn, %{"user_id" => user.id})

      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      refute has_element?(view, "#election-archive")

      assert get(conn, "/elections/#{s.election}/archive.zip").status == 403
    end

    test "an admin sees the button and downloads the zip", %{conn: conn, s: s} do
      github_user("afomi", 1)
      {:ok, admin} = Accounts.set_admin("afomi", true)
      conn = init_test_session(conn, %{"user_id" => admin.id})

      {:ok, view, _html} = live(conn, ~p"/elections/#{s.election}")
      assert has_element?(view, "#archive-build-button", "Build the archive")

      conn = get(conn, "/elections/#{s.election}/archive.zip")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
    end
  end
end
