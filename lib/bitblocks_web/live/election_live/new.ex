defmodule BitblocksWeb.ElectionLive.New do
  @moduledoc """
  `/elections/new` (admins): define an election and see its records exactly
  as they'll be published, the roll first, then the election that names it
  (https://github.com/afomi/bitblocks/issues/136, steps 1 and 2).

  The form is checked with the count's own rules (`Bitblocks.Elections.Draft`)
  and the records built by `Bitblocks.Elections.Compose`, unsigned. Bitblocks
  never signs or sends a tx: "Sign in your wallet" copies a BRC-100
  `createAction` request, and the AIP signature is the wallet's job.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Elections.{Compose, Draft}
  alias Bitblocks.Sync
  alias BitblocksWeb.ElectionCount

  @blank Map.new(Draft.fields(), &{&1, ""})

  @impl true
  def mount(_params, _session, socket) do
    tip = Sync.tip()

    {:ok,
     socket
     |> assign(
       page_title: "New election",
       tip: tip,
       week: Draft.week_window(tip),
       params: @blank,
       shown?: false,
       roll_outpoint: ""
     )
     |> build()}
  end

  @impl true
  def handle_event("change", %{"election" => params}, socket) do
    {:noreply, socket |> assign(:params, Map.merge(@blank, params)) |> build()}
  end

  def handle_event("show", %{"election" => params}, socket) do
    {:noreply, socket |> assign(params: Map.merge(@blank, params), shown?: true) |> build()}
  end

  def handle_event("week", _params, %{assigns: %{week: %{opens: opens, closes: closes}}} = socket) do
    params =
      Map.merge(socket.assigns.params, %{
        "opens_at_height" => Integer.to_string(opens),
        "closes_at_height" => Integer.to_string(closes)
      })

    {:noreply, socket |> assign(:params, params) |> build()}
  end

  def handle_event("week", _params, socket), do: {:noreply, socket}

  def handle_event("roll", %{"roll_outpoint" => text}, socket) do
    {:noreply, socket |> assign(:roll_outpoint, text) |> build()}
  end

  # The draft, its errors, the roll record and, once the roll's outpoint is
  # in, the election record.
  defp build(%{assigns: assigns} = socket) do
    parsed = Draft.parse(assigns.params, assigns.tip)

    {draft, errors} =
      case parsed do
        {:ok, draft} -> {draft, %{}}
        {:error, errors} -> {nil, errors}
      end

    roll = draft && Compose.roll(draft.members)

    {election, roll_error} =
      cond do
        is_nil(draft) or String.trim(assigns.roll_outpoint) == "" ->
          {nil, nil}

        true ->
          case Draft.with_roll(draft, assigns.roll_outpoint) do
            {:ok, e} -> {Compose.election(e, e["roll"], e["roll_sha256"]), nil}
            {:error, message} -> {nil, message}
          end
      end

    assign(socket,
      draft: draft,
      errors: if(assigns.shown?, do: errors, else: %{}),
      window: window(assigns.params, assigns.tip),
      roll: roll,
      template: draft && Compose.election_pairs(draft.election, nil, roll.sha256),
      election: election,
      roll_error: roll_error
    )
  end

  # The window in blocks and about how long, for the line under the heights.
  defp window(params, tip) do
    with {opens, ""} <- Integer.parse(String.replace(params["opens_at_height"] || "", ",", "")),
         {closes, ""} <- Integer.parse(String.replace(params["closes_at_height"] || "", ",", "")),
         true <- closes >= opens do
      blocks = closes - opens + 1

      %{
        blocks: blocks,
        about: ElectionCount.about(blocks),
        opens_in: if(is_integer(tip) and opens > tip, do: ElectionCount.about(opens - tip))
      }
    else
      _ -> nil
    end
  end

  @doc "Errors for `field`, as a list of sentences."
  def errors_for(errors, field), do: Map.get(errors, field, [])

  @doc "A number with thousands separators: 1008 → \"1,008\"."
  def delimit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "The fields AIP must cover, as a phrase: \"fields 1 to 12\"."
  def covered(%{covered: covered}), do: "fields 1 to #{length(covered)}"

  # Shared by the field component in the template.
  defp described_by(errors, field, hint) do
    [hint && "#{field}-hint", errors_for(errors, field) != [] && "#{field}-error"]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :params, :map, required: true
  attr :errors, :map, required: true
  attr :hint, :string, default: nil
  attr :type, :string, default: "text"
  attr :rows, :integer, default: nil
  attr :mono, :boolean, default: false
  attr :placeholder, :string, default: nil
  attr :inputmode, :string, default: nil

  defp field(assigns) do
    assigns =
      assign(assigns,
        invalid: errors_for(assigns.errors, assigns.field) != [],
        described: described_by(assigns.errors, assigns.field, assigns.hint)
      )

    ~H"""
    <div>
      <label
        for={"election_#{@field}"}
        class="block text-sm font-medium text-gray-800 dark:text-gray-200"
      >
        {@label}
      </label>
      <p
        :if={@hint}
        id={"#{@field}-hint"}
        class="mt-1 text-sm text-gray-600 dark:text-gray-400"
      >
        {@hint}
      </p>
      <textarea
        :if={@rows}
        id={"election_#{@field}"}
        name={"election[#{@field}]"}
        rows={@rows}
        spellcheck="false"
        placeholder={@placeholder}
        aria-invalid={to_string(@invalid)}
        aria-describedby={@described != "" && @described}
        class={[
          "mt-1 w-full rounded-md border bg-white px-3 py-2 text-sm text-gray-900 dark:bg-gray-800 dark:text-gray-100",
          @mono && "font-mono",
          if(@invalid,
            do: "border-red-600 dark:border-red-400",
            else: "border-gray-300 dark:border-gray-600"
          )
        ]}
      >{@params[@field]}</textarea>
      <input
        :if={!@rows}
        type={@type}
        id={"election_#{@field}"}
        name={"election[#{@field}]"}
        value={@params[@field]}
        inputmode={@inputmode}
        autocomplete="off"
        placeholder={@placeholder}
        aria-invalid={to_string(@invalid)}
        aria-describedby={@described != "" && @described}
        class={[
          "mt-1 w-full rounded-md border bg-white px-3 py-2 text-sm text-gray-900 dark:bg-gray-800 dark:text-gray-100",
          @mono && "font-mono tabular-nums",
          if(@invalid,
            do: "border-red-600 dark:border-red-400",
            else: "border-gray-300 dark:border-gray-600"
          )
        ]}
      />
      <ul
        :if={@invalid}
        id={"#{@field}-error"}
        class="mt-1 text-sm text-red-800 dark:text-red-200"
      >
        <li :for={message <- errors_for(@errors, @field)}>
          {message}
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :record, :map, required: true
  attr :what, :string, required: true

  # The unsigned script, the bytes AIP signs, the createAction request and
  # "Sign in your wallet", for one record.
  defp record_parts(assigns) do
    ~H"""
    <h4 class="mt-4 text-sm font-semibold text-gray-900 dark:text-white">
      Output script, unsigned (hex)
    </h4>
    <pre
      id={"#{@id}-script"}
      class="mt-1 whitespace-pre-wrap break-all rounded bg-gray-50 p-3 font-mono text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200"
    >{@record.script_hex}</pre>

    <h4 class="mt-4 text-sm font-semibold text-gray-900 dark:text-white">
      AIP signing is your wallet's job
    </h4>
    <div
      id={"#{@id}-aip"}
      class="mt-1 space-y-2 text-sm text-gray-700 dark:text-gray-300"
    >
      <p>
        Before it signs the transaction, the wallet appends <code class="font-mono break-all">{Compose.aip_template()}</code> to this output, signed with the administrator's key.
      </p>
      <p>
        The signature must cover every field, {covered(@record)} above, so it lists no field indexes.
      </p>
      <p>
        It signs these bytes as a Bitcoin Signed Message: <code class="font-mono">0x6a</code>, then each field, then <code class="font-mono">|</code>.
      </p>
      <pre
        id={"#{@id}-message"}
        class="whitespace-pre-wrap break-all rounded bg-gray-50 p-3 font-mono text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200"
      >{@record.message_hex}</pre>
      <p>
        A record without that signature isn't counted, so a wallet that sends the request below unchanged publishes nothing that counts.
      </p>
    </div>

    <h4 class="mt-4 text-sm font-semibold text-gray-900 dark:text-white">
      BRC-100 <code class="font-mono">createAction</code>
    </h4>
    <p class="mt-1 text-sm text-gray-700 dark:text-gray-300">
      The record is output 0, and the outputs keep their order, so the record's outpoint is <code class="font-mono">{"<txid>.0"}</code>.
    </p>
    <pre
      id={"#{@id}-create-action"}
      class="mt-1 whitespace-pre-wrap break-all rounded bg-gray-50 p-3 font-mono text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200"
    >{@record.create_action_json}</pre>

    <div class="mt-4">
      <button
        type="button"
        id={"#{@id}-sign"}
        class="rounded-md bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-600 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-gray-800"
        phx-click={
          JS.dispatch("bitblocks:copy",
            detail: %{text: @record.create_action_json, label: "the #{@what} createAction request"}
          )
        }
      >
        <span data-copy-label="Sign in your wallet">Sign in your wallet</span>
      </button>
      <span
        id={"#{@id}-sign-status"}
        class="sr-only"
        aria-live="polite"
      ></span>
      <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
        Copies the <code class="font-mono">createAction</code> request, to paste into your wallet.
        Bitblocks never signs or sends it.
      </p>
    </div>
    """
  end
end
