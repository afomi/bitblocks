defmodule Bitblocks.Analytics.RewardInsights do
  @moduledoc """
  Analytical helpers for block reward and address concentration visualizations.

  The functions here intentionally expose lightweight JSON-friendly maps that the
  front-end can consume without additional transformation.
  """

  alias Bitblocks.Analytics.AddressConcentration
  alias Bitblocks.Chain

  @initial_reward 50.0
  @halving_interval 210_000
  @phases %{
    "200k" => {0, 200_000},
    "600k" => {0, 600_000},
    "900k" => {0, 900_000},
    "full" => {0, :latest}
  }

  @doc """
  Builds a sampled reward schedule for the requested phase.

  The result contains:

    * `:data` - list of points with `height`, `reward_btc`, and `total_minted_btc`
    * `:metadata` - details about the sampled range and resolution
  """
  def reward_schedule(opts \\ %{}) do
    phase = Map.get(opts, :phase, Map.get(opts, "phase", "200k"))
    {start_height, requested_end} = Map.get(@phases, phase, Map.get(@phases, "200k"))

    latest_height =
      case Chain.get_latest_block() do
        %{height: height} -> height
        _ -> 0
      end

    end_height =
      case requested_end do
        :latest when latest_height > 0 -> latest_height
        :latest -> 840_000
        value -> value
      end

    end_height = max(end_height, start_height)
    range_size = end_height - start_height
    step = Map.get(opts, :step, determine_step(range_size))

    {data, _last_reward, _last_total} =
      Enum.reduce(
        Stream.iterate(start_height, &(&1 + step))
        |> Stream.take_while(&(&1 <= end_height)),
        {[], nil, nil},
        fn height, {acc, _prev_reward, _prev_total} ->
          reward = reward_for_height(height)
          total_minted = total_minted(height)

          point = %{
            height: height,
            reward_btc: Float.round(reward, 8),
            total_minted_btc: Float.round(total_minted, 8)
          }

          {[point | acc], reward, total_minted}
        end
      )

    %{
      data: Enum.reverse(data),
      metadata: %{
        phase: phase,
        start_height: start_height,
        end_height: end_height,
        step: step,
        sample_count: length(data)
      }
    }
  end

  @doc """
  Placeholder for address concentration analytics.

  Until daily aggregation jobs are built this returns an empty dataset with a status flag.
  """
  def address_concentration(opts \\ %{}) do
    phase = Map.get(opts, :phase, Map.get(opts, "phase", "200k"))

    case AddressConcentration.snapshot(phase) do
      {:ok, payload} ->
        payload
        |> Map.put("phase", phase)

      {:error, reason} ->
        %{
          "metadata" => %{
            "phase" => phase,
            "status" => "error",
            "message" => "Unable to compute address concentration: #{inspect(reason)}"
          },
          "top_addresses" => []
        }
    end
  end

  def phases do
    @phases
  end

  defp determine_step(range) when range <= 50_000, do: 1
  defp determine_step(range) when range <= 200_000, do: 10
  defp determine_step(range) when range <= 600_000, do: 25
  defp determine_step(range) when range <= 1_000_000, do: 50
  defp determine_step(_range), do: 100

  defp reward_for_height(height) do
    halving = div(height, @halving_interval)
    reward = @initial_reward / :math.pow(2, halving)
    max(reward, 0.0)
  end

  defp total_minted(height) do
    halving = div(height, @halving_interval)
    remainder = rem(height, @halving_interval) + 1

    minted_full =
      if halving == 0 do
        0.0
      else
        Enum.reduce(0..(halving - 1), 0.0, fn interval, acc ->
          acc + reward_for_interval(interval) * @halving_interval
        end)
      end

    minted_partial = reward_for_interval(halving) * remainder
    minted_full + minted_partial
  end

  defp reward_for_interval(interval) do
    reward = @initial_reward / :math.pow(2, interval)
    max(reward, 0.0)
  end
end
