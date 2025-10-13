defmodule BitblocksWeb.WallHTML do
  @moduledoc """
  This module contains pages rendered by WallController.
  """
  use BitblocksWeb, :html

  embed_templates "wall_html/*"
end
