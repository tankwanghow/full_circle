defmodule FullCircleWeb.TradingComponents do
  @moduledoc """
  Shared UI pieces for grain trading LiveViews.
  """
  use FullCircleWeb, :html

  attr :title, :string, default: nil
  attr :rows, :list, required: true
  attr :company_id, :string, required: true
  attr :empty_text, :string, default: nil
  attr :base_qty, :any, default: nil
  attr :unit, :string, default: nil
  # :load — remaining = base − total load (supply)
  # :drop — remaining = base − total drop (sales)
  attr :remaining_from, :atom, default: :load
  # Optional print URL for the history document
  attr :print_href, :string, default: nil

  @doc """
  Trip movement history — one colored line per trip: load(s) → drop(s) with unit.

  Header summary: total load, total drop, remaining from `base_qty` minus
  load (`remaining_from={:load}`, supply) or drop (`remaining_from={:drop}`, sales).
  """
  def movement_history(assigns) do
    unit = assigns[:unit] || default_unit(assigns.rows)
    totals = sum_history(assigns.rows)
    remaining_from = assigns[:remaining_from] || :load

    remaining =
      remaining_qty(assigns[:base_qty], totals.load, totals.drop, remaining_from)

    assigns =
      assigns
      |> assign_new(:title, fn -> gettext("Movement history") end)
      |> assign_new(:empty_text, fn -> gettext("No loads or drops yet.") end)
      |> assign_new(:print_href, fn -> nil end)
      |> assign(:unit, unit)
      |> assign(:total_load, totals.load)
      |> assign(:total_drop, totals.drop)
      |> assign(:remaining, remaining)

    ~H"""
    <div class="mt-4 border rounded overflow-hidden">
      <div class="bg-zinc-100 dark:bg-zinc-800 px-3 py-1.5 border-b flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <div class="flex items-center gap-2 font-semibold text-sm">
          <span>
            {@title}
            <span class="font-normal text-zinc-500 ml-1">({length(@rows)})</span>
          </span>
          <.link
            :if={@print_href}
            href={@print_href}
            class="blue button text-xs py-0.5 px-2 font-medium"
            target="_blank"
          >
            {gettext("Print")}
          </.link>
        </div>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-sm tabular-nums">
          <span>
            <span class="text-zinc-500 font-normal">{gettext("Load")}</span>
            <span class="text-teal-800 dark:text-teal-200 font-semibold ml-1">
              {fmt_dec(@total_load)}
            </span>
            <span :if={present?(@unit)} class="text-teal-600 dark:text-teal-400 text-xs ml-0.5">
              {@unit}
            </span>
          </span>
          <span class="text-zinc-300">|</span>
          <span>
            <span class="text-zinc-500 font-normal">{gettext("Drop")}</span>
            <span class="text-violet-800 dark:text-violet-200 font-semibold ml-1">
              {fmt_dec(@total_drop)}
            </span>
            <span :if={present?(@unit)} class="text-violet-600 dark:text-violet-400 text-xs ml-0.5">
              {@unit}
            </span>
          </span>
          <span class="text-zinc-300">|</span>
          <span>
            <span class="text-zinc-500 font-normal">{gettext("Remaining")}</span>
            <span class={[
              "font-semibold ml-1",
              remaining_color(@remaining)
            ]}>
              {fmt_dec(@remaining)}
            </span>
            <span :if={present?(@unit)} class="text-zinc-500 text-xs ml-0.5">{@unit}</span>
          </span>
        </div>
      </div>

      <div class="max-h-72 overflow-y-auto divide-y text-sm">
        <.link
          :for={row <- @rows}
          navigate={~p"/companies/#{@company_id}/trading/trips/#{row.trip_id}/edit"}
          class={[
            "block px-3 py-1.5 whitespace-normal break-words leading-snug hover:bg-blue-50 dark:hover:bg-blue-950/30",
            row.status == "cancelled" && "line-through opacity-70"
          ]}
          id={"movement-trip-#{row.trip_id}"}
          title={line_title(row)}
        >
          <span class="text-sky-700 dark:text-sky-400 font-medium">{row.date}</span>
          <span class="text-zinc-300 mx-0.5">·</span>
          <span class="text-indigo-700 dark:text-indigo-300 font-semibold">
            {row.reference_no || "—"}
          </span>
          <span class="text-zinc-300 mx-0.5">·</span>
          <span class={status_color(row.status)}>{row.status}</span>
          <span class="text-zinc-300 mx-0.5">·</span>
          <span class="text-amber-800 dark:text-amber-300">{row.vehicle_number || "—"}</span>
          <span class="text-zinc-300 mx-0.5">·</span>
          <.side_parts parts={row.loads} unit={row.unit || @unit} tone={:load} />
          <span class="text-zinc-400 mx-1 font-bold">→</span>
          <.side_parts parts={row.drops} unit={row.unit || @unit} tone={:drop} />
          <span :if={present?(row.notes)} class="text-zinc-300 mx-0.5">·</span>
          <span :if={present?(row.notes)} class="text-zinc-500 italic">{row.notes}</span>
        </.link>
      </div>

      <p :if={@rows == []} class="text-center text-sm text-zinc-500 p-3">{@empty_text}</p>
    </div>
    """
  end

  attr :parts, :list, required: true
  attr :unit, :string, default: nil
  attr :tone, :atom, required: true

  defp side_parts(assigns) do
    place_cls =
      case assigns.tone do
        :load -> "text-teal-700 dark:text-teal-300"
        :drop -> "text-violet-700 dark:text-violet-300"
      end

    qty_cls =
      case assigns.tone do
        :load -> "text-teal-900 dark:text-teal-100 font-semibold tabular-nums"
        :drop -> "text-violet-900 dark:text-violet-100 font-semibold tabular-nums"
      end

    unit_cls =
      case assigns.tone do
        :load -> "text-teal-600 dark:text-teal-400 text-xs"
        :drop -> "text-violet-600 dark:text-violet-400 text-xs"
      end

    assigns =
      assigns
      |> assign(:place_cls, place_cls)
      |> assign(:qty_cls, qty_cls)
      |> assign(:unit_cls, unit_cls)

    ~H"""
    <span :if={@parts == []} class="text-zinc-400">—</span>
    <span :for={{part, i} <- Enum.with_index(@parts)}>
      <span :if={i > 0} class="text-zinc-400 mx-0.5">+</span>
      <span class={@place_cls}>{part.place}</span>
      <span :if={part.qty} class={@qty_cls}> {part.qty}</span>
      <span :if={part.qty && present?(@unit)} class={@unit_cls}> {@unit}</span>
    </span>
    """
  end

  # Sum load/drop qtys across history. Cancelled trips are excluded.
  defp sum_history(rows) when is_list(rows) do
    Enum.reduce(rows, %{load: Decimal.new(0), drop: Decimal.new(0)}, fn row, acc ->
      if row.status == "cancelled" do
        acc
      else
        %{
          load: Decimal.add(acc.load, sum_parts(row.loads)),
          drop: Decimal.add(acc.drop, sum_parts(row.drops))
        }
      end
    end)
  end

  defp sum_history(_), do: %{load: Decimal.new(0), drop: Decimal.new(0)}

  defp sum_parts(parts) when is_list(parts) do
    Enum.reduce(parts, Decimal.new(0), fn part, acc ->
      case parse_qty(part.qty) do
        nil -> acc
        d -> Decimal.add(acc, d)
      end
    end)
  end

  defp sum_parts(_), do: Decimal.new(0)

  # Remaining from position qty. Supply uses load; sales uses drop.
  # Without base_qty, fall back to load − drop.
  defp remaining_qty(nil, load, drop, _), do: Decimal.sub(load, drop)
  defp remaining_qty(base, _load, drop, :drop), do: Decimal.sub(to_dec(base), drop)
  defp remaining_qty(base, load, _drop, _), do: Decimal.sub(to_dec(base), load)

  defp parse_qty(nil), do: nil
  defp parse_qty(%Decimal{} = d), do: d

  defp parse_qty(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_qty(n) when is_integer(n), do: Decimal.new(n)
  defp parse_qty(n) when is_float(n), do: Decimal.from_float(n)
  defp parse_qty(_), do: nil

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_integer(n), do: Decimal.new(n)
  defp to_dec(n) when is_float(n), do: Decimal.from_float(n)

  defp to_dec(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp to_dec(_), do: Decimal.new(0)

  defp fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  defp fmt_dec(other), do: to_string(other)

  defp remaining_color(%Decimal{} = d) do
    case Decimal.compare(d, 0) do
      :lt -> "text-red-700 dark:text-red-400"
      :eq -> "text-zinc-600 dark:text-zinc-300"
      :gt -> "text-emerald-700 dark:text-emerald-400"
    end
  end

  defp remaining_color(_), do: "text-zinc-600"

  defp default_unit(rows) when is_list(rows) do
    Enum.find_value(rows, fn r -> if present?(r.unit), do: r.unit end)
  end

  defp default_unit(_), do: nil

  defp line_title(row) do
    unit = if present?(row.unit), do: " #{row.unit}", else: ""

    load =
      row.loads
      |> Enum.map(fn p ->
        if p.qty, do: "#{p.place} #{p.qty}#{unit}", else: p.place
      end)
      |> Enum.join(" + ")
      |> blank_to_dash()

    drop =
      row.drops
      |> Enum.map(fn p ->
        if p.qty, do: "#{p.place} #{p.qty}#{unit}", else: p.place
      end)
      |> Enum.join(" + ")
      |> blank_to_dash()

    [
      to_string(row.date),
      row.reference_no,
      row.status,
      row.vehicle_number,
      "#{load} → #{drop}",
      row.notes
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp blank_to_dash(""), do: "—"
  defp blank_to_dash(s), do: s

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp status_color("completed"), do: "text-green-700 dark:text-green-400 font-medium"
  defp status_color("planned"), do: "text-blue-700 dark:text-blue-400 font-medium"
  defp status_color("draft"), do: "text-zinc-500 font-medium"
  defp status_color("cancelled"), do: "text-red-600 dark:text-red-400 font-medium"
  defp status_color(_), do: "text-zinc-600"
end
