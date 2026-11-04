defmodule BitblocksWeb.AuthHTML do
  @moduledoc "Templates for the sign-in page and the admins-only refusal."
  use BitblocksWeb, :html

  embed_templates "auth_html/*"
end
