defmodule Bitblocks.Payments.StripeEvents do
  @moduledoc """
  The one place a verified Stripe event is handled, for every line that
  sells through Stripe: bulk downloads (`Bitblocks.Downloads.Purchases`,
  https://github.com/afomi/bitblocks/issues/111) and monthly plans
  (`Bitblocks.Billing`, https://github.com/afomi/bitblocks/issues/112).

  Each event is recorded in `stripe_events` by its id first, in the same
  transaction as what it does, so a replay or a second delivery changes
  nothing. An event from the other mode (a test event while we run live, or
  the reverse) is recorded as `wrong_mode` and changes nothing.

  Routing is by type, and for a Checkout session by its `mode`:

  | Event | Goes to |
  | --- | --- |
  | `checkout.session.completed`, `checkout.session.expired`, mode `subscription` | `Bitblocks.Billing` |
  | `checkout.session.completed`, `checkout.session.expired`, any other mode | `Bitblocks.Downloads.Purchases` |
  | `charge.refunded` | `Bitblocks.Downloads.Purchases` |
  | `customer.subscription.*`, `invoice.paid`, `invoice.payment_failed` | `Bitblocks.Billing` |

  Anything else is recorded as `ignored`.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Billing
  alias Bitblocks.Downloads.Purchases
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.Payments.StripeEvent
  alias Bitblocks.Repo

  @doc """
  Handles one verified event, exactly once by its id. Returns `{:ok, outcome}`
  (`"duplicate"` for an id seen before), or `{:error, reason}` when the
  database failed, so Stripe tries again.
  """
  @spec handle(map()) :: {:ok, String.t()} | {:error, term()}
  def handle(%{"id" => id, "type" => type} = event) when is_binary(id) and is_binary(type) do
    livemode = event["livemode"] == true
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        {inserted, _} =
          Repo.insert_all(
            StripeEvent,
            [%{id: id, type: type, livemode: livemode, outcome: "pending", received_at: now}],
            on_conflict: :nothing,
            conflict_target: :id
          )

        if inserted == 0 do
          {"duplicate", nil}
        else
          {outcome, subject} =
            if livemode == Stripe.livemode?(),
              do: route(type, event, now),
              else: {"wrong_mode", nil}

          Repo.update_all(from(e in StripeEvent, where: e.id == ^id),
            set: [outcome: outcome] ++ subject_ids(subject)
          )

          {outcome, subject}
        end
      end)

    case result do
      {:ok, {outcome, subject}} ->
        after_commit(outcome, subject)
        Logger.info("Stripe event #{id} #{type}: #{outcome}")
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(_), do: {:error, :invalid_event}

  defp route(type, event, now) do
    object = event_object(event)

    case owner(type, object) do
      :purchases -> tag(:purchase, Purchases.apply_stripe_event(type, object, now))
      :billing -> tag(:plan, Billing.apply_stripe_event(type, event, now))
      :none -> {"ignored", nil}
    end
  end

  @doc "Which line handles an event: `:purchases`, `:billing` or `:none`."
  @spec owner(String.t(), map()) :: :purchases | :billing | :none
  def owner(type, object)
      when type in ["checkout.session.completed", "checkout.session.expired"] do
    if object["mode"] == "subscription", do: :billing, else: :purchases
  end

  def owner("charge.refunded", _object), do: :purchases
  def owner("customer.subscription." <> _, _object), do: :billing
  def owner(type, _object) when type in ["invoice.paid", "invoice.payment_failed"], do: :billing
  def owner(_type, _object), do: :none

  defp tag(_kind, {outcome, nil}), do: {outcome, nil}
  defp tag(kind, {outcome, record}), do: {outcome, {kind, record}}

  defp subject_ids({:purchase, p}), do: [purchase_id: p.id]
  defp subject_ids({:plan, s}), do: [plan_subscription_id: s.id]
  defp subject_ids(nil), do: []

  defp after_commit(outcome, {:purchase, p}), do: Purchases.after_stripe_event(outcome, p)
  defp after_commit(outcome, {:plan, s}), do: Billing.after_stripe_event(outcome, s)
  defp after_commit(_outcome, nil), do: :ok

  defp event_object(%{"data" => %{"object" => %{} = object}}), do: object
  defp event_object(_), do: %{}
end
