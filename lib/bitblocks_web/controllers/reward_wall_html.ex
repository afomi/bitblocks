defmodule BitblocksWeb.RewardWallHTML do
  @moduledoc """
  Templates rendered by RewardWallController.
  """

  use BitblocksWeb, :html

  embed_templates "reward_wall_html/*"

  def phase_label("200k", _finish), do: "0 - 200k blocks"
  def phase_label("600k", _finish), do: "0 - 600k blocks"
  def phase_label("900k", _finish), do: "0 - 900k blocks"

  def phase_label("full", :latest), do: "Full chain (auto)"
  def phase_label("full", finish) when is_integer(finish), do: "Full chain (0 - #{finish})"

  def phase_label(_phase, finish) when is_integer(finish), do: "0 - #{finish}"
  def phase_label(_phase, _finish), do: "Custom"
end
