defmodule BitblocksWeb.MultisigComponents do
  @moduledoc """
  Bare multisig on the transaction page, in plain words: who had to agree
  ("Locked to 2 of these 3 keys") and, on a tx that spends one, who did
  (`Bitblocks.Multisig.signers/2`).

  Keys show in short form (`Bitblocks.Multisig.short_key/1`), the whole key
  on hover and behind a copy button.
  """

  use Phoenix.Component

  alias Bitblocks.Multisig
  alias Phoenix.LiveView.JS

  @doc """
  A small button that copies `text` to the clipboard (the `bitblocks:copy`
  listener in `assets/js/app.js`) and says "Copied" for a moment.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true, doc: "what is copied, for screen readers: \"key 1\""

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="rounded border border-gray-300 px-1.5 text-xs font-medium text-gray-700 hover:bg-gray-100 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-700"
      aria-label={"Copy #{@label}"}
      title={"Copy #{@label}"}
      phx-click={JS.dispatch("bitblocks:copy", detail: %{text: @text})}
    >
      Copy
    </button>
    """
  end

  @doc """
  The keys of a multisig lock, numbered from 1 in script order, each short
  with a copy button. With `signed` (the key indexes that signed), each key
  also says whether it signed.
  """
  attr :id, :string, required: true
  attr :pubkeys, :list, required: true
  attr :signed, :list, default: nil

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
        <span
          :if={@signed && k in @signed}
          class="font-semibold text-green-700 dark:text-green-400"
        >
          Signed
        </span>
        <span
          :if={@signed && k not in @signed}
          class="text-gray-600 dark:text-gray-400"
        >
          Didn't sign
        </span>
      </li>
    </ol>
    """
  end

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
  """
  @spec signature_note(map(), pos_integer() | nil) :: String.t() | nil
  def signature_note(%{result: :matched}, _n), do: nil

  def signature_note(%{result: :no_match, index: i}, n),
    do: "Signature #{i + 1} couldn't match any of the #{n} keys."

  def signature_note(%{result: :out_of_order, index: i, key: k}, _n),
    do:
      "Signature #{i + 1} matches key #{k + 1}, but out of key order, which OP_CHECKMULTISIG does not accept."

  def signature_note(%{result: :not_checked, index: i}, _n),
    do: "Signature #{i + 1} wasn't checked: one page checks at most 64 signatures."
end
