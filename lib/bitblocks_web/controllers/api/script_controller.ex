defmodule BitblocksWeb.Api.ScriptController do
  @moduledoc """
  Script-addressed lookups — the read surface for arbitrary (non-P2PKH)
  scripts that have no address:

      GET  /api/v1/script/:scripthash/history   — txs whose outputs include the script
      GET  /api/v1/script/:scripthash/unspent   — its unspent outputs (spend index)
      POST /api/v1/script/decode                — hex → type/fields/asm/hashes/template
      GET  /api/v1/script/templates             — registered script templates
      POST /api/v1/script/templates             — register a template
      GET  /api/v1/script/templates/:template_hash
      GET  /api/v1/script/templates/:template_hash/history

  scripthash uses the Electrum/WhatsOnChain convention (sha256 of the raw
  scriptPubKey, byte-reversed hex), so results are directly comparable with
  those ecosystems.
  """

  use BitblocksWeb, :controller

  alias Bitblocks.Chain
  alias Bitblocks.Script.{Descriptor, Templates}
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  def history(conn, %{"scripthash" => raw}) do
    with {:ok, scripthash} <- BsvParams.scripthash(raw) do
      scripthash = String.downcase(scripthash)

      json(conn, %{
        scripthash: scripthash,
        history: Chain.history_for_script_hash(scripthash),
        source: "local"
      })
    end
  end

  def unspent(conn, %{"scripthash" => raw}) do
    with {:ok, scripthash} <- BsvParams.scripthash(raw) do
      scripthash = String.downcase(scripthash)

      json(conn, %{
        scripthash: scripthash,
        unspent: Chain.utxos_for_script_hash(scripthash),
        source: "local"
      })
    end
  end

  def decode(conn, %{"script" => hex}) when is_binary(hex) do
    with {:ok, script} <- decode_script_hex(hex) do
      descriptor = Descriptor.from_output(%BSV.TxOut{satoshis: 0, script: script}, 0)
      template = Templates.get_by_hash(descriptor.template_hash)

      json(conn, %{
        type: descriptor.type,
        fields: sanitize_fields(descriptor.fields),
        asm: descriptor.asm,
        script_hash: descriptor.script_hash,
        template_hash: descriptor.template_hash,
        template: template && template_json(template)
      })
    end
  end

  def decode(_conn, _params), do: {:error, :invalid_script_hex}

  def list_templates(conn, _params) do
    json(conn, %{templates: Enum.map(Templates.list(), &template_json/1)})
  end

  def create_template(conn, params) do
    attrs = Map.take(params, ["name", "template_hash", "body_asm", "args", "source"])

    with {:ok, template} <- Templates.register(attrs) do
      conn
      |> put_status(:created)
      |> json(%{template: template_json(template)})
    end
  end

  def show_template(conn, %{"template_hash" => raw}) do
    with {:ok, hash} <- BsvParams.scripthash(raw),
         %{} = template <- Templates.get_by_hash(String.downcase(hash)) do
      json(conn, %{template: template_json(template)})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def template_history(conn, %{"template_hash" => raw}) do
    with {:ok, hash} <- BsvParams.scripthash(raw) do
      hash = String.downcase(hash)
      template = Templates.get_by_hash(hash)

      json(conn, %{
        template_hash: hash,
        template: template && template_json(template),
        history: Chain.history_for_template_hash(hash)
      })
    end
  end

  defp decode_script_hex(hex) do
    with {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         {:ok, script} <- BSV.Script.from_binary(bytes) do
      {:ok, script}
    else
      _ -> {:error, :invalid_script_hex}
    end
  end

  # OP_RETURN field maps carry nested chunk structs that serialize fine, but
  # trim the potentially huge data list for the decode endpoint's response.
  defp sanitize_fields(%{type: :op_return, data: data} = fields) do
    %{fields | data: Enum.take(data, 100)}
  end

  defp sanitize_fields(fields), do: fields

  defp template_json(template) do
    %{
      name: template.name,
      template_hash: template.template_hash,
      body_asm: template.body_asm,
      args: template.args,
      source: template.source,
      registered_at: template.inserted_at
    }
  end
end
