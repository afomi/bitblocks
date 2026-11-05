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
    <div class="py-2 first:pt-0 last:pb-0">
      <div class="flex flex-wrap items-center justify-between gap-x-2 mb-1">
        <div class="flex flex-wrap items-center gap-1.5">
          <span class="text-xs font-semibold text-gray-700">
            Output #<%= @descriptor.vout %>
          </span>
          <span class="px-1.5 bg-gray-100 text-gray-700 text-xs font-mono rounded">
            <%= type_label(@descriptor.type) %>
          </span>
          <%= if @descriptor.type == :unknown && @template do %>
            <span class="px-1.5 bg-purple-100 text-purple-800 rounded-full text-xs font-semibold">
              Template: <%= @template.name %>
            </span>
          <% end %>
          <%= for protocol <- @protocols do %>
            <span class="px-1.5 bg-blue-100 text-blue-800 rounded-full text-xs font-semibold">
              <%= protocol %>
            </span>
          <% end %>
        </div>
        <span class="font-mono text-xs font-semibold text-green-800">
          <%= format_satoshis(@descriptor.satoshis) %>
        </span>
      </div>

      <.card_body descriptor={@descriptor} />

      <%= if @txid do %>
        <.script_field label="Outpoint:">
          <%= @txid %>_<%= @descriptor.vout %>
        </.script_field>
      <% end %>
    </div>
    """
  end

  @doc """
  One labelled line of an input or output on the transaction page: the label
  in a narrow column, the value in mono beside it. `title` carries the
  explanation a reader can ask for by hovering.
  """
  attr :label, :string, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def script_field(assigns) do
    ~H"""
    <div class="flex gap-2 text-xs leading-snug">
      <span
        class="w-24 shrink-0 text-gray-600"
        title={@title}
      >
        <%= @label %>
      </span>
      <span class="min-w-0 font-mono break-all">
        <%= render_slot(@inner_block) %>
      </span>
    </div>
    """
  end

  attr :descriptor, Descriptor, required: true

  defp card_body(%{descriptor: %{type: :p2pkh}} = assigns) do
    ~H"""
    <.script_field
      label="Public Key Hash:"
      title="Pay to Public Key Hash: spendable by the owner of the matching key"
    >
      <%= @descriptor.fields.pubkey_hash %>
    </.script_field>
    """
  end

  defp card_body(%{descriptor: %{type: :p2sh}} = assigns) do
    ~H"""
    <.script_field
      label="Script Hash:"
      title="Pay to Script Hash: the redeem script is revealed when spent"
    >
      <%= @descriptor.fields.script_hash %>
    </.script_field>
    """
  end

  defp card_body(%{descriptor: %{type: :p2pk}} = assigns) do
    ~H"""
    <.script_field
      label="Public Key:"
      title="Pay to Public Key: spendable by the holder of this key"
    >
      <%= @descriptor.fields.pubkey %>
    </.script_field>
    """
  end

  defp card_body(%{descriptor: %{type: :multisig}} = assigns) do
    ~H"""
    <.script_field
      :for={{pubkey, i} <- Enum.with_index(@descriptor.fields.pubkeys)}
      label={if i == 0, do: "#{@descriptor.fields.m}-of-#{@descriptor.fields.n} multisig", else: ""}
      title={"Requires #{@descriptor.fields.m} of the #{@descriptor.fields.n} keys to spend"}
    >
      <%= pubkey %>
    </.script_field>
    """
  end

  defp card_body(%{descriptor: %{type: :op_return}} = assigns) do
    ~H"""
    <div class="text-xs leading-snug text-gray-600">
      OP_RETURN (<%= length(@descriptor.fields.data) %> chunks), in the OP_RETURN Data section below.
    </div>
    """
  end

  defp card_body(%{descriptor: %{type: :unknown}} = assigns) do
    ~H"""
    <div class="text-xs leading-snug">
      <span class="text-gray-600">
        Locking Script (ASM):
      </span>
      <div class="font-mono break-all max-h-32 overflow-y-auto">
        <%= @descriptor.asm %>
      </div>
      <details>
        <summary class="text-gray-600 cursor-pointer">
          Script hashes
        </summary>
        <div class="font-mono break-all text-gray-600">
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
