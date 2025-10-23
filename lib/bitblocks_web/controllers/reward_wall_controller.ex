defmodule BitblocksWeb.RewardWallController do
  use BitblocksWeb, :controller

  alias Bitblocks.Analytics.RewardInsights

  def index(conn, _params) do
    render(conn, :index, phases: RewardInsights.phases())
  end

  def reward_data(conn, params) do
    phase = Map.get(params, "phase", "200k")
    dataset = RewardInsights.reward_schedule(%{phase: phase})
    json(conn, dataset)
  end

  def address_data(conn, params) do
    phase = Map.get(params, "phase", "200k")
    dataset = RewardInsights.address_concentration(%{phase: phase})
    json(conn, dataset)
  end
end
