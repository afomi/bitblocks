defmodule BitblocksWeb.ScriptComponents do
  @moduledoc """
  Function components for rendering `Bitblocks.Script.Descriptor` structs —
  the per-output script cards on the transaction show page.

  Each card dispatches on `descriptor.type` and shows the semantic fields for
  that type (pubkey hash, script hash, pubkey, multisig quorum) instead of a
  truncated ASM slice.
  Unknown scripts get the full ASM plus an optional registered-template badge;
  the template is looked up once in the LiveView (batched) and passed in as
  an assign — the component never queries.
  """

  use Phoenix.Component

  alias Bitblocks.Script.Descriptor

  attr :descriptor, Descriptor, required: true

  attr :template, :any,
    default: nil,
    doc: "a registered %Bitblocks.Script.Template{} matching this script's template_hash, or nil"

  attr :protocols, :list,
    default: [],
    doc: "protocol handler names detected in an OP_RETURN output (e.g. [\"B://\", \"MAP\"])"

  attr :txid, :string,
    default: nil,
    doc: "when present, renders the txid_vout outpoint line at the bottom of the card"

  def script_card(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold text-gray-700">
            Output #<%= @descriptor.vout %>
          </span>
          <span class="px-2 py-0.5 bg-gray-100 text-gray-700 text-xs font-mono rounded">
            <%= type_label(@descriptor.type) %>
          </span>
          <%= if @descriptor.type == :unknown && @template do %>
            <span class="px-2 py-0.5 bg-purple-100 text-purple-800 rounded-full text-xs font-semibold">
              Template: <%= @template.name %>
            </span>
          <% end %>
          <%= for protocol <- @protocols do %>
            <span class="px-2 py-0.5 bg-blue-100 text-blue-800 rounded-full text-xs font-semibold">
              <%= protocol %>
            </span>
          <% end %>
        </div>
        <span class="px-3 py-1 bg-green-100 text-green-800 text-sm font-semibold rounded">
          <%= format_satoshis(@descriptor.satoshis) %>
        </span>
      </div>

      <div class="space-y-2 text-sm">
        <.card_body descriptor={@descriptor} />

        <%= if @txid do %>
          <div class="font-mono text-xs text-gray-400">
            <%= @txid %>_<%= @descriptor.vout %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :descriptor, Descriptor, required: true

  defp card_body(%{descriptor: %{type: :p2pkh}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        Public Key Hash:
      </span>
      <div class="font-mono text-xs bg-gray-50 p-2 rounded mt-1 break-all">
        <%= @descriptor.fields.pubkey_hash %>
      </div>
      <div class="text-xs text-gray-400 mt-1">
        Pay to Public Key Hash — spendable by the owner of the matching key
      </div>
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :p2sh}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        Script Hash:
      </span>
      <div class="font-mono text-xs bg-gray-50 p-2 rounded mt-1 break-all">
        <%= @descriptor.fields.script_hash %>
      </div>
      <div class="text-xs text-gray-400 mt-1">
        Pay to Script Hash — the redeem script is revealed when spent
      </div>
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :p2pk}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        Public Key:
      </span>
      <div class="font-mono text-xs bg-gray-50 p-2 rounded mt-1 break-all">
        <%= @descriptor.fields.pubkey %>
      </div>
      <div class="text-xs text-gray-400 mt-1">
        Pay to Public Key — spendable by the holder of this key
      </div>
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :multisig}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        <%= @descriptor.fields.m %>-of-<%= @descriptor.fields.n %> multisig
      </span>
      <div class="mt-1 space-y-1">
        <%= for pubkey <- @descriptor.fields.pubkeys do %>
          <div class="font-mono text-xs bg-gray-50 p-2 rounded break-all">
            <%= pubkey %>
          </div>
        <% end %>
      </div>
      <div class="text-xs text-gray-400 mt-1">
        Requires <%= @descriptor.fields.m %> of the <%= @descriptor.fields.n %> keys above to spend
      </div>
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :op_return}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        OP_RETURN (<%= length(@descriptor.fields.data) %> chunks)
      </span>
      <div class="text-xs text-gray-400 mt-1">
        Data output — see the OP_RETURN Data section below for the full chunk breakdown
      </div>
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :unknown}} = assigns) do
    ~H"""
    <div>
      <span class="text-gray-600">
        Locking Script (ASM):
      </span>
      <div class="font-mono text-xs bg-gray-50 p-2 rounded mt-1 break-all max-h-48 overflow-y-auto">
        <%= @descriptor.asm %>
      </div>
      <details class="mt-2">
        <summary class="text-xs text-gray-500 cursor-pointer">
          Script hashes
        </summary>
        <div class="mt-1 space-y-1 text-xs text-gray-500 font-mono break-all">
          <div>
            script_hash: <%= @descriptor.script_hash %>
          </div>
          <div>
            template_hash: <%= @descriptor.template_hash %>
          </div>
        </div>
      </details>
    </div>
    """
  end

  @doc """
  Human label for a `Bitblocks.Script.script_type()`.
  """
  def type_label(:p2pkh), do: "P2PKH"
  def type_label(:p2sh), do: "P2SH"
  def type_label(:p2pk), do: "P2PK"
  def type_label(:multisig), do: "Multisig"
  def type_label(:op_return), do: "OP_RETURN"
  def type_label(:unknown), do: "Script"

  @doc """
  Formats satoshis as `X.XXXXXXXX BSV (N sats)`.
  """
  def format_satoshis(satoshis) when is_number(satoshis) do
    bsv = satoshis / 100_000_000
    bsv_str = :erlang.float_to_binary(bsv, decimals: 8)
    sats_str = satoshis |> round() |> Integer.to_string() |> format_integer_commas()
    "#{bsv_str} BSV (#{sats_str} sats)"
  end

  def format_satoshis(_), do: "0 sats"

  defp format_integer_commas(str) do
    str
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
