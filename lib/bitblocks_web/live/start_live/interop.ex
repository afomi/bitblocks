defmodule BitblocksWeb.StartLive.Interop do
  @moduledoc """
  `/start/interop`: check a BEEF by hand, and read the pattern behind the kit
  (`docs/INTEROP_KIT.md`). The check is `BeefVerifier`'s, through
  `Bitblocks.Interop.Check`.

  Everything here comes from a stranger, and socket events pass no rate limiter:

    * the paste form sends only on submit, and the upload form is separate, so
      a `phx-change` never carries the textarea;
    * input is never assigned: only a report cut down by `Check` stays;
    * one check a second per LiveView (`@min_interval_ms`), counted from the end
      of the last one, so events that queue during a check are turned away
      cheaply;
    * a budget of `:interop_checks_per_minute` a minute per user, or per IP
      when logged out, held across every LiveView they open;
    * every output is a hash the verifier derived or a fixed sentence.

  Admin only until published, like `/start`.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.StartComponents

  alias Bitblocks.Interop.{Check, Vectors}
  alias BitblocksWeb.Plugs.RateLimiter
  alias BitblocksWeb.Seo
  alias BitblocksWeb.StartLive.Index
  alias BitblocksWeb.Utils.IpHelper

  @min_interval_ms 1_000
  @checks_per_minute 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Check a payment's proof",
         meta_description:
           "Check BEEF against block headers, and read what a sender and a receiver each do.",
         canonical_path: "/start/interop",
         meta_robots: "noindex, nofollow"
       )
     )
     |> assign(report: nil, error: nil, last_check_at: nil)
     |> assign(:budget_bucket, budget_bucket(socket))
     |> assign(:max_bytes, Check.max_bytes())
     |> assign(:vectors, Vectors.summary())
     |> allow_upload(:beef,
       accept: :any,
       max_entries: 1,
       max_file_size: Check.max_input_bytes()
     )}
  end

  @impl true
  def handle_event("check_paste", %{"beef" => input}, socket) when is_binary(input) do
    {:noreply, check(socket, fn -> {:ok, input} end)}
  end

  def handle_event("check_paste", _params, socket) do
    {:noreply, refuse(socket, :empty)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) when is_binary(ref) do
    held? = Enum.any?(socket.assigns.uploads.beef.entries, &(&1.ref == ref))
    {:noreply, if(held?, do: cancel_upload(socket, :beef, ref), else: socket)}
  end

  def handle_event("cancel_upload", _params, socket), do: {:noreply, socket}

  def handle_event("check_upload", _params, socket) do
    case uploaded_entries(socket, :beef) do
      {[], []} -> {:noreply, refuse(socket, :no_file)}
      {_done, [_ | _]} -> {:noreply, refuse(socket, :upload_not_ready)}
      {[_ | _], []} -> {:noreply, check(socket, fn -> read_upload(socket) end)}
    end
  end

  defp read_upload(socket) do
    results =
      consume_uploaded_entries(socket, :beef, fn %{path: path}, _entry ->
        {:ok, File.read(path)}
      end)

    case results do
      [{:ok, bytes}] -> {:ok, bytes}
      _ -> {:error, :unreadable_file}
    end
  end

  defp check(socket, input) do
    if too_soon?(socket) do
      # The last result stays: this is usually a second press of the button.
      assign(socket, :error, Check.message(:too_soon))
    else
      outcome =
        with :ok <- within_budget(socket),
             {:ok, bytes} <- input.(),
             do: Check.run(bytes)

      socket
      |> assign(:last_check_at, now())
      |> present(outcome)
    end
  end

  defp within_budget(socket) do
    limit = Application.get_env(:bitblocks, :interop_checks_per_minute, @checks_per_minute)

    if RateLimiter.allow?(socket.assigns.budget_bucket, limit),
      do: :ok,
      else: {:error, :over_budget}
  end

  defp budget_bucket(%{assigns: %{current_user: %{id: id}}}), do: "interop:user:#{id}"

  defp budget_bucket(socket) do
    if connected?(socket), do: "interop:ip:#{IpHelper.get_socket_ip(socket)}"
  end

  defp present(socket, {:ok, report}), do: assign(socket, report: report, error: nil)
  defp present(socket, {:error, reason}), do: refuse(socket, reason)

  defp refuse(socket, reason) do
    assign(socket, report: nil, error: Check.message(reason))
  end

  defp too_soon?(%{assigns: %{last_check_at: nil}}), do: false

  defp too_soon?(%{assigns: %{last_check_at: at}}) do
    now() - at < @min_interval_ms
  end

  defp now, do: System.monotonic_time(:millisecond)

  @doc "A status as a reader sees it: text first, colour as support (DESIGN.md)."
  attr :status, :atom, required: true

  def verdict(assigns) do
    ~H"""
    <span class={["rounded-full px-2.5 py-0.5 text-xs font-semibold", verdict_class(@status)]}>
      {verdict_label(@status)}
    </span>
    """
  end

  defp verdict_label(:proven), do: "Proven"
  defp verdict_label(:anchored), do: "Anchored"
  defp verdict_label(:unknown), do: "Unknown"
  defp verdict_label(:failed), do: "Failed"

  defp verdict_class(:proven),
    do: "bg-green-100 text-green-900 dark:bg-green-900/40 dark:text-green-200"

  defp verdict_class(:anchored),
    do: "bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"

  defp verdict_class(:unknown),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"

  defp verdict_class(:failed), do: "bg-red-100 text-red-900 dark:bg-red-900/40 dark:text-red-200"

  @doc "The verifier's `not_checked` names, in words."
  def not_checked_label("scripts"), do: "Scripts"
  def not_checked_label("signatures"), do: "Signatures"
  def not_checked_label("input_amounts"), do: "Input amounts"
  def not_checked_label("double_spends"), do: "Double spends"
  def not_checked_label("token_validity"), do: "Token validity"
  def not_checked_label("payment_terms"), do: "Payment terms"

  @doc false
  def upload_error(:too_large), do: "That file is larger than a BEEF at the limit, even as hex."
  def upload_error(:too_many_files), do: "Choose one file at a time."
  def upload_error(:not_accepted), do: "That file wasn't accepted."
  def upload_error(_other), do: "That file couldn't be uploaded. Try choosing it again."

  @doc false
  def group(number), do: Index.format_number(number)

  @doc false
  def vectors_example do
    """
    curl -s https://bitblocks.app/interop/vectors/v1.json | jq '.vectors[0] | {id, valid, expected}'
    """
  end
end
