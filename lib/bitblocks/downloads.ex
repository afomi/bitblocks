defmodule Bitblocks.Downloads do
  @moduledoc """
  Bulk downloads of a block range (https://github.com/afomi/bitblocks/issues/111),
  first cut: the free quote only. Checkout, webhooks, links and resume are not
  built.

  A quote covers only blocks we hold whole: `0..complete_through`
  (`Bitblocks.Sync.complete_through/0`), every one `completed`, with its
  merkleroot rebuilt and every tx stored. A range reaching above it is
  refused, naming that height.

  Sizes are read from `blocks.size`, the block's exact serialised size, set
  from the raw bytes the sync fetched (or the node's `getblock` size), never
  from `transactions`. One aggregate over `blocks` by its height index, plus at
  most 10 heights of blocks with no stored size. A block with no size is
  counted and named, never guessed: the bytes are then a lower bound
  (`bytes_exact: false`).

  What can be produced today:

    * `raw`: raw transactions, packed by block, as `.bin` files: one file per
      block, its exact bytes (the 80-byte header, the tx count, then every tx
      in order), the same object the tx store holds (`docs/TX_STORAGE.md`).

  Transaction JSON and data packs are listed as coming, and are refused.

  The price is `price_usd_per_gib` under `config :bitblocks,
  Bitblocks.Downloads`: $1.00 a GiB in prod (config/prod.exs), nil (price on
  request) in dev and test unless set. The arithmetic is the quote's own:
  `billable_gib` (bytes / 1,073,741,824, rounded half up to 0.01 GiB, at
  least 0.01 for any bytes) times `price_usd_per_gib`, rounded to the cent.
  A quote with a block of no stored size has only a lower bound, so no price.

  To help choose a range, `presets/1` names a few ranges (the first 100,000
  blocks, everything we hold, eras between halvings and forks), and
  `size_bands/1` gives the size of each 50,000-block band up to
  `complete_through`: one bounded aggregate per band over `blocks`, cached
  for `:size_bands_ttl_ms` (10 minutes), since it changes slowly.
  """

  import Ecto.Query

  alias Bitblocks.Chain.Block
  alias Bitblocks.Repo
  alias Bitblocks.Sync

  @gib 1_073_741_824
  @missing_sample 10
  @query_timeout 15_000
  @band_size 50_000
  @size_bands_ttl_ms 600_000
  @size_bands_key {__MODULE__, :size_bands}

  # Ranges a buyer often wants. `:complete_through` as `to` means as far as
  # we hold; every range is clipped to it. Heights from
  # priv/data/chain_annotations.json.
  @presets [
    %{id: "first_100k", label: "First 100,000 blocks", from: 0, to: 99_999},
    %{id: "all", label: "Everything we hold", from: 0, to: :complete_through},
    %{
      id: "first_halving",
      label: "Up to the first halving",
      from: 0,
      to: 209_999,
      note: "The 50-coin era"
    },
    %{
      id: "second_halving",
      label: "First to second halving",
      from: 210_000,
      to: 419_999,
      note: "The 25-coin era"
    },
    %{
      id: "before_bch",
      label: "Before the Bitcoin Cash split",
      from: 0,
      to: 478_558,
      note: "The history BTC, BCH and BSV share"
    },
    %{
      id: "bsv",
      label: "Bitcoin SV since its split",
      from: 556_767,
      to: :complete_through,
      note: "From the November 2018 split on"
    }
  ]

  @data [
    %{
      id: "raw",
      label: "Raw transactions",
      available: true,
      formats: [
        %{
          id: "bin",
          label: "Raw block files (.bin), one per block",
          available: true
        }
      ]
    },
    %{id: "tx_json", label: "Transaction JSON", available: false, formats: []},
    %{id: "data_pack", label: "Data pack", available: false, formats: []}
  ]

  @type quote :: %{
          from: non_neg_integer(),
          to: non_neg_integer(),
          data: String.t(),
          format: String.t(),
          complete_through: integer(),
          blocks: non_neg_integer(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          gib: float(),
          bytes_exact: boolean(),
          sizes_missing: non_neg_integer(),
          sizes_missing_heights: [non_neg_integer()],
          not_in_store: non_neg_integer(),
          billable_gib: Decimal.t(),
          price_usd_per_gib: Decimal.t() | nil,
          price_usd: Decimal.t() | nil
        }

  @type error ::
          :invalid_range
          | {:above_complete_through, integer()}
          | {:coming, String.t()}
          | :unknown_data
          | :unknown_format

  @doc """
  The data a download can hold, each with its formats, and whether it can be
  produced today (`available`). The unavailable ones show as "(coming)".
  """
  @spec data_options() :: [map()]
  def data_options, do: @data

  @doc """
  Quotes a download of blocks `from..to` (inclusive) as `data`, in `format`
  (`opts[:format]`, else the data's first format).

  `from` and `to` are integers or decimal strings (`,` and `_` allowed).
  Returns `{:ok, quote}`, or `{:error, reason}`:

    * `:invalid_range`: not whole numbers, negative, or `from > to`;
    * `{:above_complete_through, h}`: `to` is above `complete_through`, `h`;
    * `{:coming, data}`: data we can't produce yet;
    * `:unknown_data` and `:unknown_format`.

  The quote's fields:

    * `blocks` and `files`: blocks in range, and files (one per block);
    * `bytes` and `gib`: the summed stored sizes, exact when `bytes_exact`;
    * `sizes_missing` and `sizes_missing_heights`: blocks with no stored size,
      and the lowest #{@missing_sample} of them;
    * `not_in_store`: blocks whose object isn't in the tx store yet, which
      would be refetched from our node first;
    * `complete_through`: what the quote is bounded by;
    * `billable_gib`: the size the price is figured on, `bytes` / 1 GiB
      rounded half up to 0.01, and at least 0.01 for any bytes;
    * `price_usd_per_gib`: the configured price, nil while none is set;
    * `price_usd`: `billable_gib` x `price_usd_per_gib`, rounded to the
      cent; nil while no price is set or while a size is missing.
  """
  @spec quote(term(), term(), term(), keyword()) :: {:ok, quote()} | {:error, error()}
  def quote(from, to, data, opts \\ []) do
    with {:ok, from, to} <- parse_range(from, to),
         {:ok, option} <- data_option(data),
         {:ok, format} <- format(option, Keyword.get(opts, :format)),
         complete_through = Keyword.get_lazy(opts, :complete_through, &Sync.complete_through/0),
         :ok <- within(to, complete_through) do
      {:ok, build(from, to, option.id, format, complete_through)}
    end
  end

  @doc """
  The price per GiB in USD as a Decimal, from config; nil (price on request)
  when none is set.
  """
  @spec price_usd_per_gib() :: Decimal.t() | nil
  def price_usd_per_gib do
    case config(:price_usd_per_gib, nil) do
      nil -> nil
      n -> to_decimal(n)
    end
  end

  @doc """
  The size a price is figured on: `bytes` in GiB, rounded half up to 0.01,
  and at least 0.01 for any bytes, so a small range never reads as free.
  """
  @spec billable_gib(non_neg_integer()) :: Decimal.t()
  def billable_gib(0), do: Decimal.new("0.00")

  def billable_gib(bytes) when is_integer(bytes) and bytes > 0 do
    bytes
    |> Decimal.new()
    |> Decimal.div(Decimal.new(@gib))
    |> Decimal.round(2, :half_up)
    |> Decimal.max(Decimal.new("0.01"))
  end

  @doc """
  The price of `bytes`, or nil while no price is set: `billable_gib/1` times
  the price per GiB, rounded half up to the cent.
  """
  @spec price_for(non_neg_integer()) :: Decimal.t() | nil
  def price_for(bytes) when is_integer(bytes) and bytes >= 0 do
    case price_usd_per_gib() do
      nil -> nil
      per_gib -> bytes |> billable_gib() |> Decimal.mult(per_gib) |> Decimal.round(2, :half_up)
    end
  end

  @doc "A dollar amount with two decimals and thousands separated: `$1,234.50`."
  @spec format_usd(Decimal.t()) :: String.t()
  def format_usd(%Decimal{} = amount) do
    [whole, fraction] =
      amount |> Decimal.round(2, :half_up) |> Decimal.to_string(:normal) |> String.split(".")

    "$" <> format_number(String.to_integer(whole)) <> "." <> fraction
  end

  @doc """
  The named ranges, each clipped to `complete_through`:

    * `from` and `to`: the range as it can be quoted today (`to` no higher
      than `complete_through`);
    * `clipped`: `to` was lowered to `complete_through`;
    * `available`: false when even `from` is above `complete_through`.
  """
  @spec presets(integer()) :: [map()]
  def presets(complete_through) do
    for preset <- @presets do
      wanted = if preset.to == :complete_through, do: complete_through, else: preset.to
      to = min(wanted, complete_through)

      preset
      |> Map.put_new(:note, nil)
      |> Map.merge(%{
        to: to,
        clipped: to < wanted,
        available: complete_through >= 0 and preset.from <= to
      })
    end
  end

  @doc "A named range by its id, clipped as `presets/1` does, or nil."
  @spec preset(term(), integer()) :: map() | nil
  def preset(id, complete_through),
    do: Enum.find(presets(complete_through), &(&1.id == id))

  @doc """
  The size of each #{@band_size}-block band from 0 to `complete_through`,
  for choosing a range: `%{complete_through, band_size, bands, computed_at}`,
  each band `%{from, to, blocks, bytes, bytes_exact, sizes_missing,
  price_usd}`; the last band ends at `complete_through`.

  One aggregate per band over `blocks` by its height index, never
  `transactions`. Cached for `:size_bands_ttl_ms` (10 minutes);
  `opts[:complete_through]` computes afresh for that height, uncached.
  """
  @spec size_bands(keyword()) :: map()
  def size_bands(opts \\ []) do
    now = System.monotonic_time(:millisecond)

    case {Keyword.fetch(opts, :complete_through), :persistent_term.get(@size_bands_key, nil)} do
      {{:ok, complete_through}, _} ->
        compute_size_bands(complete_through)

      {:error, {expires, value}} when expires > now ->
        value

      {:error, _} ->
        value = compute_size_bands(Sync.complete_through())
        :persistent_term.put(@size_bands_key, {now + size_bands_ttl_ms(), value})
        value
    end
  end

  @doc "Drops the cached `size_bands/1`, for tests and after a size backfill."
  @spec clear_size_bands() :: :ok
  def clear_size_bands do
    :persistent_term.erase(@size_bands_key)
    :ok
  end

  defp size_bands_ttl_ms, do: config(:size_bands_ttl_ms, @size_bands_ttl_ms)

  defp compute_size_bands(complete_through) do
    bands =
      if complete_through < 0 do
        []
      else
        for from <- 0..complete_through//@band_size do
          to = min(from + @band_size - 1, complete_through)
          row = aggregate(from, to)

          %{
            from: from,
            to: to,
            blocks: row.blocks,
            bytes: row.bytes,
            bytes_exact: row.sizes_missing == 0,
            sizes_missing: row.sizes_missing,
            price_usd: if(row.sizes_missing == 0, do: price_for(row.bytes))
          }
        end
      end

    %{
      complete_through: complete_through,
      band_size: @band_size,
      bands: bands,
      computed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, []) |> Keyword.get(key, default)
  end

  @doc "A plain sentence for an error from `quote/4`, for the page and the API."
  @spec error_message(error()) :: String.t()
  def error_message(:invalid_range),
    do: "Give a block range as two whole numbers, from no higher than to."

  def error_message({:above_complete_through, h}) when h < 0,
    do: "No blocks are complete yet, so there is nothing to quote."

  def error_message({:above_complete_through, h}),
    do:
      "We hold every block whole through #{format_number(h)}. " <>
        "Choose a range that ends at or below it."

  def error_message({:coming, data}),
    do: "#{label(data)} downloads are coming. Raw transactions can be quoted today."

  def error_message(:unknown_data),
    do: "Choose the data: raw, tx_json or data_pack."

  def error_message(:unknown_format),
    do: "Choose a format this data comes in."

  @doc "An error from `quote/4` as a short machine-readable code."
  @spec error_code(error()) :: String.t()
  def error_code(:invalid_range), do: "invalid_range"
  def error_code({:above_complete_through, _}), do: "above_complete_through"
  def error_code({:coming, _}), do: "coming"
  def error_code(:unknown_data), do: "unknown_data"
  def error_code(:unknown_format), do: "unknown_format"

  @doc "Thousands separated with commas."
  @spec format_number(integer()) :: String.t()
  def format_number(n) when is_integer(n) and n < 0, do: "-" <> format_number(-n)

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # One aggregate over `blocks` by its height index.
  defp aggregate(from, to) do
    Repo.one(
      from(b in Block,
        where: b.height >= ^from and b.height <= ^to,
        select: %{
          blocks: count(b.id),
          bytes: fragment("coalesce(sum(?), 0)::bigint", b.size),
          sizes_missing: fragment("count(*) FILTER (WHERE ? IS NULL)", b.size),
          not_in_store: fragment("count(*) FILTER (WHERE ? IS NULL)", b.raw_object_stored_at)
        }
      ),
      timeout: @query_timeout
    )
  end

  defp build(from, to, data, format, complete_through) do
    row = aggregate(from, to)

    missing_heights =
      if row.sizes_missing > 0 do
        Repo.all(
          from(b in Block,
            where: b.height >= ^from and b.height <= ^to and is_nil(b.size),
            order_by: b.height,
            limit: @missing_sample,
            select: b.height
          ),
          timeout: @query_timeout
        )
      else
        []
      end

    %{
      from: from,
      to: to,
      data: data,
      format: format,
      complete_through: complete_through,
      blocks: row.blocks,
      files: row.blocks,
      bytes: row.bytes,
      gib: Float.round(row.bytes / @gib, 2),
      bytes_exact: row.sizes_missing == 0,
      sizes_missing: row.sizes_missing,
      sizes_missing_heights: missing_heights,
      not_in_store: row.not_in_store,
      billable_gib: billable_gib(row.bytes),
      price_usd_per_gib: price_usd_per_gib(),
      # A price only on exact bytes, and only once one is configured.
      price_usd: if(row.sizes_missing == 0, do: price_for(row.bytes))
    }
  end

  defp to_decimal(%Decimal{} = n), do: n
  defp to_decimal(n) when is_float(n), do: n |> Float.to_string() |> Decimal.new()
  defp to_decimal(n), do: Decimal.new(n)

  defp within(to, complete_through) when to > complete_through,
    do: {:error, {:above_complete_through, complete_through}}

  defp within(_to, _complete_through), do: :ok

  defp parse_range(from, to) do
    with {:ok, from} <- parse_height(from),
         {:ok, to} <- parse_height(to),
         true <- from <= to do
      {:ok, from, to}
    else
      _ -> {:error, :invalid_range}
    end
  end

  defp parse_height(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse_height(s) when is_binary(s) do
    case s |> String.trim() |> String.replace([",", "_"], "") |> Integer.parse() do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_height(_), do: :error

  defp data_option(data) when is_atom(data) and not is_nil(data),
    do: data_option(Atom.to_string(data))

  defp data_option(data) when is_binary(data) do
    case Enum.find(@data, &(&1.id == data)) do
      nil -> {:error, :unknown_data}
      %{available: false, id: id} -> {:error, {:coming, id}}
      option -> {:ok, option}
    end
  end

  defp data_option(_), do: {:error, :unknown_data}

  defp format(%{formats: [first | _]}, nil), do: {:ok, first.id}
  defp format(option, ""), do: format(option, nil)

  defp format(%{formats: formats}, format) do
    format = to_string(format)

    if Enum.any?(formats, &(&1.available and &1.id == format)),
      do: {:ok, format},
      else: {:error, :unknown_format}
  end

  defp label(id) do
    case Enum.find(@data, &(&1.id == id)) do
      %{label: label} -> label
      nil -> id
    end
  end
end
