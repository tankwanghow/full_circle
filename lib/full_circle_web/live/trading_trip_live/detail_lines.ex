defmodule FullCircleWeb.TradingTripLive.DetailLines do
  @moduledoc """
  Invoice-style load/drop detail rows for trip forms (sticky headers, trash/add icons).
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircleWeb.CoreComponents

  attr :form, :any, required: true
  attr :goods, :list, default: []
  attr :locations, :list, default: []
  attr :supplies, :list, default: []
  attr :sales, :list, default: []
  attr :phx_target, :any, default: nil

  def loads_section(assigns) do
    ~H"""
    <div
      id="trip-loads"
      class="text-center border bg-sky-100 dark:bg-sky-950/40 mt-2 p-3 rounded-lg border-sky-400"
    >
      <div class="font-medium flex flex-row text-center tracking-tighter sticky top-0 z-10">
        <div class="detail-header w-[17%]">{gettext("Good")}</div>
        <div class="detail-header w-[18%]">{gettext("Location")}</div>
        <div class="detail-header w-[18%]">{gettext("Supply")}</div>
        <div class="detail-header w-[15%]">{gettext("Planned MT")}</div>
        <div class="detail-header w-[15%]">{gettext("Actual MT")}</div>
        <div class="detail-header w-[16%]">{gettext("Note")}</div>
        <div class="w-[2%]"></div>
      </div>

      <.inputs_for :let={load} field={@form[:loads]}>
        <div class={[
          "flex flex-row",
          if(load[:delete].value in [true, "true"], do: "hidden"),
          if(!load.source.valid?, do: "bg-rose-50 border-l-4 border-l-rose-500")
        ]}>
          <.input type="hidden" field={load[:delete]} value={"#{load[:delete].value}"} />
          <div class="w-[17%]">
            <.input
              field={load[:good_id]}
              type="select"
              options={good_options(@goods)}
              prompt={gettext("Select…")}
            />
          </div>
          <div class="w-[18%]">
            <.input
              field={load[:location_id]}
              type="select"
              options={location_options(@locations)}
              prompt={gettext("Select…")}
            />
          </div>
          <div class="w-[18%]">
            <.input
              field={load[:supply_position_id]}
              type="select"
              options={supply_options(@supplies)}
            />
          </div>
          <div class="w-[15%]">
            <.input field={load[:planned_mt]} type="number" step="any" klass="text-right" />
          </div>
          <div class="w-[15%]">
            <.input field={load[:actual_mt]} type="number" step="any" klass="text-right" />
          </div>
          <div class="w-[16%]">
            <.input field={load[:location_note]} />
          </div>
          <div class="w-[2%] mt-1 text-rose-500">
            <.link
              phx-click="delete_load"
              phx-value-index={load.index}
              phx-target={@phx_target}
              tabindex="-1"
            >
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
          </div>
        </div>
      </.inputs_for>

      <div class="flex flex-row">
        <div class="mt-1 w-full text-orange-500 text-left font-medium">
          <.link phx-click="add_load" phx-target={@phx_target} class="hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" />{gettext("Add Load")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :goods, :list, default: []
  attr :locations, :list, default: []
  attr :supplies, :list, default: []
  attr :sales, :list, default: []
  attr :phx_target, :any, default: nil

  def drops_section(assigns) do
    ~H"""
    <div
      id="trip-drops"
      class="text-center border bg-violet-100 dark:bg-violet-950/40 mt-2 p-3 rounded-lg border-violet-400"
    >
      <div class="font-medium flex flex-row text-center tracking-tighter sticky top-0 z-10">
        <div class="detail-header w-[14%]">{gettext("Good")}</div>
        <div class="detail-header w-[14%]">{gettext("Location")}</div>
        <div class="detail-header w-[14%]">{gettext("Sales")}</div>
        <div class="detail-header w-[15%]">{gettext("Supply")}</div>
        <div class="detail-header w-[13%]">{gettext("Planned MT")}</div>
        <div class="detail-header w-[13%]">{gettext("Actual MT")}</div>
        <div class="detail-header w-[15%]">{gettext("Variance")}</div>
        <div class="w-[2%]"></div>
      </div>

      <.inputs_for :let={drop} field={@form[:drops]}>
        <div class={[
          "flex flex-row",
          if(drop[:delete].value in [true, "true"], do: "hidden"),
          if(!drop.source.valid?, do: "bg-rose-50 border-l-4 border-l-rose-500")
        ]}>
          <.input type="hidden" field={drop[:delete]} value={"#{drop[:delete].value}"} />
          <div class="w-[14%]">
            <.input
              field={drop[:good_id]}
              type="select"
              options={good_options(@goods)}
              prompt={gettext("Select…")}
            />
          </div>
          <div class="w-[14%]">
            <.input
              field={drop[:location_id]}
              type="select"
              options={location_options(@locations)}
              prompt={gettext("Select…")}
            />
          </div>
          <div class="w-[14%]">
            <.input
              field={drop[:sales_position_id]}
              type="select"
              options={sales_options(@sales)}
            />
          </div>
          <div class="w-[15%]">
            <.input
              field={drop[:supply_position_id]}
              type="select"
              options={supply_options(@supplies)}
            />
          </div>
          <div class="w-[13%]">
            <.input field={drop[:planned_mt]} type="number" step="any" klass="text-right" />
          </div>
          <div class="w-[13%]">
            <.input field={drop[:actual_mt]} type="number" step="any" klass="text-right" />
          </div>
          <div class="w-[15%]">
            <.input field={drop[:variance_note]} />
          </div>
          <div class="w-[2%] mt-1 text-rose-500">
            <.link
              phx-click="delete_drop"
              phx-value-index={drop.index}
              phx-target={@phx_target}
              tabindex="-1"
            >
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
          </div>
        </div>
      </.inputs_for>

      <div class="flex flex-row">
        <div class="mt-1 w-full text-orange-500 text-left font-medium">
          <.link phx-click="add_drop" phx-target={@phx_target} class="hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" />{gettext("Add Drop")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp good_options(goods) do
    Enum.map(goods || [], &{&1.name, &1.id})
  end

  defp location_options(locations) do
    Enum.map(locations || [], fn l ->
      label =
        if l.kind && l.kind != "",
          do: "#{l.name} (#{l.kind})",
          else: l.name

      {label, l.id}
    end)
  end

  defp supply_options(supplies) do
    [
      {gettext("(none)"), ""}
      | Enum.map(supplies || [], fn s ->
          label =
            case s.status do
              "open" -> "#{s.title} (open)"
              "hold" -> "#{s.title} (hold)"
              "collect" -> "#{s.title} (collect)"
              other -> "#{s.title} (#{other})"
            end

          {label, s.id}
        end)
    ]
  end

  defp sales_options(sales) do
    [{gettext("(none)"), ""} | Enum.map(sales || [], &{&1.title, &1.id})]
  end
end
