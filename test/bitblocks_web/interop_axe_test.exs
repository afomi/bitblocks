defmodule BitblocksWeb.InteropAxeTest do
  @moduledoc """
  `/start/interop` in a real browser, past its empty state: a check through the
  LiveView client, then axe over the verdicts and the error panel, which the
  page list in `accessibility_axe_test.exs` never reaches.
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false

  alias Bitblocks.Interop.Vectors
  alias Bitblocks.RealHeaders
  alias Wallaby.Query

  @moduletag :accessibility_axe

  @vectors Jason.decode!(Vectors.body())["vectors"]

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  defp hex(id), do: Enum.find(@vectors, &(&1["id"] == id))["hex"]

  defp paste(session, input) do
    session
    |> visit("/start/interop")
    |> assert_has(css("#interop-paste-form"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> fill_in(Query.css("#interop-beef"), with: input)
    |> click(Query.css("#interop-paste-submit"))
  end

  for mode <- [:light, :dark] do
    @mode mode

    defp unquote(:"in_#{mode}")(session) do
      if @mode == :dark do
        session |> execute_script(@dark_mode_script) |> assert_has(css("html.dark"))
      else
        session
      end
    end

    test "every verdict is accessible in #{mode} mode", %{session: session} do
      RealHeaders.insert(814_435)

      session
      |> paste(hex("brc62-example"))
      |> assert_has(css("#interop-rows li", count: 2))
      |> unquote(:"in_#{mode}")()
      |> assert_no_violations()
    end

    test "a failed verdict is accessible in #{mode} mode", %{session: session} do
      RealHeaders.insert(813_706)

      session
      |> paste(hex("failed-root-mismatch"))
      |> assert_has(css("#interop-report h3", text: "Failed"))
      |> unquote(:"in_#{mode}")()
      |> assert_no_violations()
    end

    test "the error panel is accessible in #{mode} mode", %{session: session} do
      session
      |> paste("not hex")
      |> assert_has(css("#interop-error", text: "isn't hex"))
      |> unquote(:"in_#{mode}")()
      |> assert_no_violations()
    end
  end

  test "a file goes through the real upload client", %{session: session} do
    RealHeaders.insert(973_110)

    path = Path.join(System.tmp_dir!(), "interop-#{System.unique_integer([:positive])}.beef")
    File.write!(path, hex("mainnet-v1") <> "\n")
    on_exit(fn -> File.rm(path) end)

    session
    |> visit("/start/interop")
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> attach_file(Query.css("#interop-upload-form input[type=file]"), path: path)
    |> assert_has(css("#interop-upload-entries", text: ".beef"))
    |> click(Query.css("#interop-upload-submit"))
    |> assert_has(css("#interop-report h3", text: "Proven"))
  end
end
