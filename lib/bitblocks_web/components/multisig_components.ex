defmodule BitblocksWeb.MultisigComponents do
  @moduledoc """
  Bare multisig on the transaction page, in plain words: who had to agree
  ("Locked to 2 of these 3 keys") and, on a tx that spends one, who did
  (`Bitblocks.Multisig.signers/2`).

  Keys show in short form (`Bitblocks.Multisig.short_key/1`), the whole key
  on hover and behind a copy button.
  A key with no matching signature reads "Didn't sign" only when every
  signature in the input was checked, and "Not checked" otherwise: the
  page never says more than was checked.
  """

  use Phoenix.Component

  alias Bitblocks.Multisig
  alias Phoenix.LiveView.JS

  @doc """
  A small button that copies `text` to the clipboard (the `bitblocks:copy`
  listener in `assets/js/app.js`).
  The button reads "Copied", or "Couldn't copy" when the browser gives no
  clipboard, for a moment, and the polite live region beside it says the
  same to a screen reader.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true, doc: "what is copied, for screen readers: \"key 1\""

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="rounded border border-gray-300 px-1.5 text-xs font-medium text-gray-700 hover:bg-gray-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-600 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-700 dark:focus-visible:ring-blue-400"
      title={"Copy #{@label}"}
      phx-click={JS.dispatch("bitblocks:copy", detail: %{text: @text, label: @label})}
    >
      <span data-copy-label>Copy</span>
      <span class="sr-only">
        <%= @label %>
      </span>
    </button>
    <span
      id={"#{@id}-status"}
      class="sr-only"
      aria-live="polite"
    ></span>
    """
  end

  @doc """
  The keys of a multisig lock, numbered from 1 in script order, each short
  with a copy button.
  With `states` (`key_states/1`), each key also says "Signed", "Didn't
  sign" or "Not checked".
  """
  attr :id, :string, required: true
  attr :pubkeys, :list, required: true
  attr :states, :map, default: nil

  def key_list(assigns) do
    ~H"""
    <ol
      id={@id}
      class="mt-1 space-y-1"
    >
      <li
        :for={{pubkey, k} <- Enum.with_index(@pubkeys)}
        id={"#{@id}-#{k}"}
        class="flex flex-wrap items-center gap-x-2 text-sm"
      >
        <span class="w-12 shrink-0 text-gray-600 dark:text-gray-400">
          Key <%= k + 1 %>
        </span>
        <span
          class="font-mono text-gray-800 dark:text-gray-200"
          title={pubkey}
        >
          <%= Multisig.short_key(pubkey) %>
        </span>
        <.copy_button
          id={"#{@id}-#{k}-copy"}
          text={pubkey}
          label={"key #{k + 1}"}
        />
        <%= case @states && Map.get(@states, k) do %>
          <% :signed -> %>
            <span class="font-semibold text-green-700 dark:text-green-400">
              Signed
            </span>
          <% :not_signed -> %>
            <span class="text-gray-600 dark:text-gray-400">
              Didn't sign
            </span>
          <% :not_checked -> %>
            <span class="text-amber-900 dark:text-amber-200">
              Not checked
            </span>
          <% nil -> %>
        <% end %>
      </li>
    </ol>
    """
  end

  @doc """
  Each key's state in a checked input: `:signed` when a signature matched
  it in order; else `:not_signed` when every signature was checked, and
  `:not_checked` when any wasn't.
  """
  @spec key_states(map()) :: %{non_neg_integer() => :signed | :not_signed | :not_checked}
  def key_states(%{pubkeys: pubkeys, signed: signed} = input) do
    otherwise = if all_checked?(input), do: :not_signed, else: :not_checked

    for k <- 0..(length(pubkeys) - 1)//1,
        into: %{},
        do: {k, if(k in signed, do: :signed, else: otherwise)}
  end

  @doc """
  The input's headline: "Key 1 and key 3 signed." when every signature was
  checked; with any unchecked, what matched and "We checked 1 of 2
  signatures.", never "No signature matched".
  """
  @spec headline(map()) :: String.t()
  def headline(%{signed: signed} = input) do
    if all_checked?(input) do
      signed_sentence(signed)
    else
      checked = Enum.count(input.signatures, &(&1.result != :not_checked))
      total = length(input.signatures)
      prefix = if signed == [], do: "", else: signed_sentence(signed) <> " "
      prefix <> "We checked #{checked} of #{total} #{plural(total, "signature")}."
    end
  end

  defp all_checked?(%{signatures: signatures}),
    do: Enum.all?(signatures, &(&1.result != :not_checked))

  @doc """
  "Key 1 and key 3 signed." for the keys that signed, in key order.
  """
  @spec signed_sentence([non_neg_integer()]) :: String.t()
  def signed_sentence([]), do: "No signature matched one of these keys."
  def signed_sentence([k]), do: "Key #{k + 1} signed."

  def signed_sentence(keys) do
    {init, [last]} = keys |> Enum.sort() |> Enum.map(&"key #{&1 + 1}") |> Enum.split(-1)
    String.capitalize(Enum.join(init, ", ")) <> " and #{last} signed."
  end

  @doc """
  One sentence for a signature that is not a plain match, nil for a match.
  "Couldn't match" is only for a signature checked against every key.
  """
  @spec signature_note(map(), pos_integer() | nil) :: String.t() | nil
  def signature_note(%{result: :matched}, _n), do: nil

  def signature_note(%{result: :no_match, index: i}, n),
    do: "Signature #{i + 1} couldn't match any of the #{n} keys."

  def signature_note(%{result: :out_of_order, index: i, key: k}, _n),
    do: "Signature #{i + 1} is from key #{k + 1}, but out of order, so it doesn't count."

  def signature_note(%{result: :not_checked, index: i, reason: :budget}, _n),
    do:
      "Signature #{i + 1} wasn't checked: we stop after #{Multisig.check_budget()} checks on one page."

  def signature_note(%{result: :not_checked, index: i, reason: :no_sighash}, _n),
    do: "Signature #{i + 1} wasn't checked: we couldn't compute what this signature signs."

  def signature_note(%{result: :not_checked}, _n), do: nil

  @doc "\"signature\" or \"signatures\" for a count."
  def plural(1, word), do: word
  def plural(_count, word), do: word <> "s"
end
