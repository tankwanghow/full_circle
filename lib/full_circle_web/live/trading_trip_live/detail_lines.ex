defmodule FullCircleWeb.TradingTripLive.DetailLines do
  @moduledoc """
  Invoice-style load/drop detail rows for trip forms (demand-first).

  - **Drops first** (sales demand), then **loads** (sources).
  - Drop columns: Sales → Good → Location → Supply.
  - Load columns: Supply → Good → Location.
  - Drop good is readonly when sales is set; typeahead when sales empty (warehouse drop).
  - Load good is readonly when supply is set; typeahead when supply empty (warehouse Out).
  - Load supply typeahead is filtered by the line good, or by all drop goods.
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircleWeb.CoreComponents

  # Fixed height for all load/drop line controls (typeahead, number, note).
  @field_h "h-16 box-border"

  # Textareas so typeahead labels wrap (inputs cannot wrap).
  @text_class "block w-full #{@field_h} rounded border border-zinc-300 bg-white text-zinc-900 " <>
                "text-sm focus:ring-0 focus:border-zinc-400 leading-snug py-1.5 px-1.5 " <>
                "whitespace-pre-wrap break-words resize-none overflow-y-auto"

  @text_ro_class "block w-full #{@field_h} rounded border border-zinc-200 bg-zinc-100 text-zinc-700 " <>
                   "text-sm leading-snug py-1.5 px-1.5 whitespace-pre-wrap break-words " <>
                   "resize-none overflow-y-auto cursor-default"

  @num_class "block w-full #{@field_h} rounded border border-zinc-300 bg-white text-zinc-900 " <>
               "text-sm focus:ring-0 focus:border-zinc-400 py-1.5 px-1 text-right"

  @doc "Unique good_ids from non-deleted drop lines (drives load supply filter)."
  def drop_good_ids(form) do
    form.source
    |> Ecto.Changeset.get_assoc(:drops)
    |> List.wrap()
    |> Enum.reject(&line_deleted?/1)
    |> Enum.map(&line_good_id/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  attr :form, :any, required: true
  attr :company_id, :string, required: true
  attr :user_id, :string, required: true
  attr :phx_target, :any, default: nil
  attr :show_errors, :boolean, default: false
  attr :show_crew, :boolean, default: false

  def drops_section(assigns) do
    ~H"""
    <div
      id="trip-drops"
      class="text-center border bg-violet-100 dark:bg-violet-950/40 mt-2 p-3 rounded-lg border-violet-400"
    >
      <p class="text-left text-xs text-violet-900 dark:text-violet-100 mb-1 font-medium">
        {gettext("Drops")}
        <span class="font-normal text-violet-800/80">
          — {gettext("demand first: pick sales (or leave empty for warehouse In + choose good)")}
        </span>
      </p>
      <div class="font-medium flex flex-row text-center tracking-tighter sticky top-0 z-10">
        <div class="detail-header w-[3%]">{gettext("#")}</div>
        <div class="detail-header w-[20%]">{gettext("Sales")}</div>
        <div class="detail-header w-[13%]">{gettext("Good")}</div>
        <div class="detail-header w-[19%]">{gettext("Location")}</div>
        <div class="detail-header w-[14%]">{gettext("Supply")}</div>
        <div class="detail-header w-[8%]">{gettext("Plan")}</div>
        <div class="detail-header w-[8%]">{gettext("Actual")}</div>
        <div class="detail-header w-[9%]">{gettext("Variance")}</div>
        <div class="detail-header w-[3%]"></div>
        <div class="detail-header w-[3%]"></div>
      </div>

      <.inputs_for :let={drop} field={@form[:drops]}>
        <div class={[
          if(drop[:delete].value in [true, "true"], do: "hidden"),
          if(!drop.source.valid?, do: "bg-rose-50 border-l-2 border-l-rose-500")
        ]}>
          <div class="flex flex-row">
            <.input type="hidden" field={drop[:delete]} value={"#{drop[:delete].value}"} />
            <.input type="hidden" field={drop[:seq]} />
            <.input type="hidden" field={drop[:good_id]} />
            <.input type="hidden" field={drop[:good_unit]} />
            <.input type="hidden" field={drop[:location_id]} />
            <.input type="hidden" field={drop[:sales_position_id]} />
            <.input type="hidden" field={drop[:supply_position_id]} />
            <.input type="hidden" field={drop[:party_contact_id]} />
            <div class="w-[3%] font-semibold text-violet-900 shrink-0 pt-4">
              {drop[:seq].value || drop.index + 1}
            </div>
            <div class="w-[20%]">
              <.line_typeahead
                field={drop[:sales_title]}
                error_fields={[drop[:sales_title], drop[:sales_position_id]]}
                show_errors={@show_errors}
                url={ac_url(@company_id, @user_id, "opensales")}
                title={drop[:sales_title].value}
              />
            </div>
            <div class="w-[13%]">
              <.line_typeahead
                field={drop[:good_name]}
                error_fields={[drop[:good_name], drop[:good_id]]}
                show_errors={@show_errors}
                url={ac_url(@company_id, @user_id, "good")}
                title={drop[:good_name].value}
                readonly={sales_set?(drop)}
              />
            </div>
            <div class="w-[19%]">
              <.line_typeahead
                field={drop[:location_name]}
                error_fields={[drop[:location_name], drop[:location_id]]}
                show_errors={@show_errors}
                url={
                  ac_url(
                    @company_id,
                    @user_id,
                    "tradinglocation",
                    contact_id: drop[:party_contact_id].value
                  )
                }
                title={drop[:location_name].value}
              />
            </div>
            <div class="w-[14%]">
              <.line_typeahead
                field={drop[:supply_title]}
                error_fields={[drop[:supply_title], drop[:supply_position_id]]}
                show_errors={@show_errors}
                url={ac_url(@company_id, @user_id, "opensupply", good_id: drop[:good_id].value)}
                title={drop[:supply_title].value}
              />
            </div>
            <div class="w-[8%]">
              <.line_number
                field={drop[:planned]}
                show_errors={@show_errors}
                unit={drop[:good_unit].value}
              />
            </div>
            <div class="w-[8%]">
              <.line_number
                field={drop[:actual]}
                show_errors={@show_errors}
                unit={drop[:good_unit].value}
              />
            </div>
            <div class="w-[9%]">
              <.line_text field={drop[:variance_note]} />
            </div>
            <div class="w-[3%] flex flex-col items-center justify-center gap-0 text-violet-800 shrink-0">
              <.link
                phx-click="move_drop"
                phx-value-index={drop.index}
                phx-value-dir="up"
                phx-target={@phx_target}
                tabindex="-1"
                title={gettext("Move up (deliver earlier)")}
                class="hover:text-violet-950"
              >
                <.icon name="hero-chevron-up" class="h-4 w-4" />
              </.link>
              <.link
                phx-click="move_drop"
                phx-value-index={drop.index}
                phx-value-dir="down"
                phx-target={@phx_target}
                tabindex="-1"
                title={gettext("Move down (deliver later)")}
                class="hover:text-violet-950"
              >
                <.icon name="hero-chevron-down" class="h-4 w-4" />
              </.link>
            </div>
            <div class="w-[3%] text-rose-500 shrink-0">
              <.link
                phx-click="delete_drop"
                phx-value-index={drop.index}
                phx-target={@phx_target}
                tabindex="-1"
              >
                <.icon name="hero-trash-solid" class="h-5 w-5 mt-5" />
              </.link>
            </div>
          </div>
          <.crew_row
            :if={@show_crew}
            line={drop}
            crew_field={:trip_drop_employees}
            label={gettext("Drop crew")}
            remove_event="remove_drop_crew"
            tone={:drop}
            company_id={@company_id}
            user_id={@user_id}
            phx_target={@phx_target}
          />
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

  attr :form, :any, required: true
  attr :company_id, :string, required: true
  attr :user_id, :string, required: true
  attr :phx_target, :any, default: nil
  attr :drop_good_ids, :list, default: []
  attr :show_errors, :boolean, default: false
  attr :show_crew, :boolean, default: false

  def loads_section(assigns) do
    ~H"""
    <div
      id="trip-loads"
      class="text-center border bg-sky-100 dark:bg-sky-950/40 mt-2 p-3 rounded-lg border-sky-400"
    >
      <div class="flex flex-row items-center justify-between mb-1 gap-2">
        <p class="text-left text-xs text-sky-900 dark:text-sky-100 font-medium">
          {gettext("Loads")}
          <span class="font-normal text-sky-800/80">
            — {gettext("sources for drop goods · order = loading sequence (1 = first onto truck)")}
          </span>
        </p>
        <.link
          phx-click="reverse_loads"
          phx-target={@phx_target}
          class="text-xs text-sky-800 hover:font-bold shrink-0"
          title={gettext("Reverse load order (FILO helper: last onto truck / first unload)")}
        >
          {gettext("Reverse order")}
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter sticky top-0 z-10">
        <div class="detail-header w-[3%]">{gettext("#")}</div>
        <div class="detail-header w-[23%]">{gettext("Supply")}</div>
        <div class="detail-header w-[14%]">{gettext("Good")}</div>
        <div class="detail-header w-[24%]">{gettext("Location")}</div>
        <div class="detail-header w-[9%]">{gettext("Plan")}</div>
        <div class="detail-header w-[9%]">{gettext("Actual")}</div>
        <div class="detail-header w-[12%]">{gettext("Note")}</div>
        <div class="detail-header w-[3%]"></div>
        <div class="detail-header w-[3%]"></div>
      </div>

      <.inputs_for :let={load} field={@form[:loads]}>
        <div class={[
          if(load[:delete].value in [true, "true"], do: "hidden"),
          if(!load.source.valid?, do: "bg-rose-50 border-l-2 border-l-rose-500")
        ]}>
          <div class="flex flex-row">
            <.input type="hidden" field={load[:delete]} value={"#{load[:delete].value}"} />
            <.input type="hidden" field={load[:seq]} />
            <.input type="hidden" field={load[:good_id]} />
            <.input type="hidden" field={load[:good_unit]} />
            <.input type="hidden" field={load[:location_id]} />
            <.input type="hidden" field={load[:supply_position_id]} />
            <.input type="hidden" field={load[:party_contact_id]} />
            <div class="w-[3%] font-semibold text-sky-900 shrink-0 pt-4">
              {load[:seq].value || load.index + 1}
            </div>
            <div class="w-[23%]">
              <.line_typeahead
                field={load[:supply_title]}
                error_fields={[load[:supply_title], load[:supply_position_id]]}
                show_errors={@show_errors}
                url={
                  ac_url(
                    @company_id,
                    @user_id,
                    "opensupply",
                    supply_filter_opts(load[:good_id].value, @drop_good_ids)
                  )
                }
                title={load[:supply_title].value}
              />
            </div>
            <div class="w-[14%]">
              <.line_typeahead
                field={load[:good_name]}
                error_fields={[load[:good_name], load[:good_id]]}
                show_errors={@show_errors}
                url={ac_url(@company_id, @user_id, "good")}
                title={load[:good_name].value}
                readonly={supply_set?(load)}
              />
            </div>
            <div class="w-[24%]">
              <.line_typeahead
                field={load[:location_name]}
                error_fields={[load[:location_name], load[:location_id]]}
                show_errors={@show_errors}
                url={
                  ac_url(
                    @company_id,
                    @user_id,
                    "tradinglocation",
                    contact_id: load[:party_contact_id].value
                  )
                }
                title={load[:location_name].value}
              />
            </div>
            <div class="w-[9%]">
              <.line_number
                field={load[:planned]}
                show_errors={@show_errors}
                unit={load[:good_unit].value}
              />
            </div>
            <div class="w-[9%]">
              <.line_number
                field={load[:actual]}
                show_errors={@show_errors}
                unit={load[:good_unit].value}
              />
            </div>
            <div class="w-[12%]">
              <.line_text field={load[:location_note]} />
            </div>
            <div class="w-[3%] flex flex-col items-center justify-center gap-0 text-sky-800 shrink-0">
              <.link
                phx-click="move_load"
                phx-value-index={load.index}
                phx-value-dir="up"
                phx-target={@phx_target}
                tabindex="-1"
                title={gettext("Move up (load earlier)")}
                class="hover:text-sky-950"
              >
                <.icon name="hero-chevron-up" class="h-4 w-4" />
              </.link>
              <.link
                phx-click="move_load"
                phx-value-index={load.index}
                phx-value-dir="down"
                phx-target={@phx_target}
                tabindex="-1"
                title={gettext("Move down (load later)")}
                class="hover:text-sky-950"
              >
                <.icon name="hero-chevron-down" class="h-4 w-4" />
              </.link>
            </div>
            <div class="w-[3%] text-rose-500 shrink-0">
              <.link
                phx-click="delete_load"
                phx-value-index={load.index}
                phx-target={@phx_target}
                tabindex="-1"
              >
                <.icon name="hero-trash-solid" class="h-5 w-5 mt-5" />
              </.link>
            </div>
          </div>
          <.crew_row
            :if={@show_crew}
            line={load}
            crew_field={:trip_load_employees}
            label={gettext("Load crew")}
            remove_event="remove_load_crew"
            tone={:load}
            company_id={@company_id}
            user_id={@user_id}
            phx_target={@phx_target}
          />
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

  attr :line, :any, required: true
  attr :crew_field, :atom, required: true
  attr :label, :string, required: true
  attr :remove_event, :string, required: true
  attr :tone, :atom, default: :load
  attr :company_id, :string, required: true
  attr :user_id, :string, required: true
  attr :phx_target, :any, default: nil

  defp crew_row(assigns) do
    tone_cls =
      case assigns.tone do
        :drop -> "bg-violet-50/80 border-violet-200 text-violet-900"
        _ -> "bg-sky-50/80 border-sky-200 text-sky-900"
      end

    assigns = assign(assigns, :tone_cls, tone_cls)

    ~H"""
    <div class={["mx-1 mb-1.5 mt-0.5 rounded border px-2 py-1.5 text-left", @tone_cls]}>
      <.input type="hidden" field={@line[:crew_locked]} value={"#{@line[:crew_locked].value}"} />
      <div class="flex flex-wrap items-center gap-1.5">
        <span class="inline-flex items-center gap-1 text-[11px] font-semibold shrink-0">
          <.icon name="hero-user-group" class="w-3.5 h-3.5" />
          {@label}
        </span>
        <.inputs_for :let={crew} field={@line[@crew_field]}>
          <div class={crew[:delete].value in [true, "true"] && "hidden"}>
            <.input type="hidden" field={crew[:delete]} value={"#{crew[:delete].value}"} />
            <.input type="hidden" field={crew[:employee_id]} />
            <.input type="hidden" field={crew[:employee_name]} />
            <span class="inline-flex items-center gap-0.5 rounded-full border border-zinc-300 bg-white px-2 py-0.5 text-xs text-zinc-800 shadow-sm">
              {crew[:employee_name].value || gettext("Worker")}
              <.link
                phx-click={@remove_event}
                phx-value-line={@line.index}
                phx-value-crew={crew.index}
                phx-target={@phx_target}
                tabindex="-1"
                class="ml-0.5 text-zinc-400 hover:text-rose-600"
                title={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </.link>
            </span>
          </div>
        </.inputs_for>
        <div class="min-w-[10rem] flex-1 max-w-xs">
          <input
            type="text"
            id={"#{@line.id}_crew_add_name"}
            name={@line[:crew_add_name].name}
            value={Phoenix.HTML.Form.normalize_value("text", @line[:crew_add_name].value)}
            phx-hook="tributeAutoComplete"
            url={ac_url(@company_id, @user_id, "employee")}
            placeholder={gettext("Add worker…")}
            autocomplete="off"
            class="block w-full h-7 rounded border border-zinc-300 bg-white px-2 text-xs text-zinc-900 focus:ring-0 focus:border-zinc-400"
          />
        </div>
      </div>
      <p class="text-[10px] text-zinc-500 mt-0.5 leading-tight">
        {gettext(
          "Each person gets the full line actual for payroll. Crew fills down to following lines until you change them."
        )}
      </p>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :url, :string, required: true
  attr :title, :any, default: nil
  attr :readonly, :boolean, default: false
  # Include hidden id fields so "can't be blank" on good_id/location_id shows under the typeahead
  attr :error_fields, :list, default: []
  attr :show_errors, :boolean, default: false

  defp line_typeahead(assigns) do
    errors = collect_line_errors(assigns.error_fields, assigns.field, assigns.show_errors)

    assigns =
      assigns
      |> assign(:text_class, @text_class)
      |> assign(:text_ro_class, @text_ro_class)
      |> assign(:errors, errors)
      |> assign(:has_error, errors != [])

    ~H"""
    <div class="w-full min-w-0 flex flex-col">
      <textarea
        id={@field.id}
        name={@field.name}
        phx-hook={if(@readonly, do: nil, else: "tributeAutoComplete")}
        url={@url}
        title={@title}
        autocomplete="off"
        readonly={@readonly}
        tabindex={if(@readonly, do: "-1", else: nil)}
        rows="2"
        wrap="soft"
        class={[
          if(@readonly, do: @text_ro_class, else: @text_class),
          @has_error && "border-rose-400 focus:border-rose-400"
        ]}
      >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :show_errors, :boolean, default: false
  attr :unit, :any, default: nil

  defp line_number(assigns) do
    errors = collect_line_errors([assigns.field], assigns.field, assigns.show_errors)
    unit = unit_label(assigns.unit)

    assigns =
      assigns
      |> assign(:num_class, @num_class)
      |> assign(:errors, errors)
      |> assign(:has_error, errors != [])
      |> assign(:unit_label, unit)

    ~H"""
    <div class="w-full min-w-0 flex flex-col">
      <input
        type="number"
        step="any"
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value("number", @field.value)}
        class={[
          @num_class,
          @has_error && "border-rose-400 focus:border-rose-400"
        ]}
      />
      <span
        :if={@unit_label}
        class="text-[10px] leading-none text-zinc-500 text-right mt-0.5 tabular-nums"
      >
        {@unit_label}
      </span>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp unit_label(nil), do: nil
  defp unit_label(""), do: nil
  defp unit_label(u) when is_binary(u), do: String.trim(u) |> then(fn s -> if s == "", do: nil, else: s end)
  defp unit_label(_), do: nil

  attr :field, Phoenix.HTML.FormField, required: true

  defp line_text(assigns) do
    assigns = assign(assigns, :text_class, @text_class)

    ~H"""
    <textarea id={@field.id} name={@field.name} rows="2" wrap="soft" class={@text_class}>{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
    """
  end

  # Show errors after parent validate/save, mapping hidden id errors onto typeaheads.
  defp collect_line_errors(error_fields, primary_field, show_errors?) do
    fields =
      case error_fields do
        [] -> [primary_field]
        list -> list
      end

    fields
    |> Enum.flat_map(fn
      %Phoenix.HTML.FormField{} = f ->
        if show_errors? or Phoenix.Component.used_input?(f) do
          Enum.map(f.errors, &FullCircleWeb.CoreComponents.translate_error/1)
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp sales_set?(drop) do
    sid = drop[:sales_position_id].value
    title = drop[:sales_title].value

    (is_binary(sid) and sid != "") or
      (is_binary(title) and String.trim(title) != "")
  end

  defp supply_set?(load) do
    sid = load[:supply_position_id].value
    title = load[:supply_title].value

    (is_binary(sid) and sid != "") or
      (is_binary(title) and String.trim(title) != "")
  end

  defp supply_filter_opts(line_good_id, drop_good_ids) do
    cond do
      is_binary(line_good_id) and line_good_id != "" ->
        [good_id: line_good_id]

      is_list(drop_good_ids) and drop_good_ids != [] ->
        [good_ids: drop_good_ids]

      true ->
        []
    end
  end

  defp ac_url(company_id, user_id, schema, opts \\ []) do
    base = "/list/companies/#{company_id}/#{user_id}/autocomplete?schema=#{schema}"

    base =
      case Keyword.get(opts, :good_id) do
        id when is_binary(id) and id != "" -> "#{base}&good_id=#{id}"
        _ -> base
      end

    base =
      case Keyword.get(opts, :good_ids) do
        ids when is_list(ids) ->
          ids = Enum.filter(ids, &(is_binary(&1) and &1 != ""))

          if ids == [] do
            base
          else
            "#{base}&good_ids=#{Enum.join(ids, ",")}"
          end

        _ ->
          base
      end

    base =
      case Keyword.get(opts, :contact_id) do
        id when is_binary(id) and id != "" -> "#{base}&contact_id=#{id}"
        _ -> base
      end

    "#{base}&name="
  end

  defp line_deleted?(%Ecto.Changeset{} = cs),
    do: Ecto.Changeset.get_field(cs, :delete) in [true, "true"]

  defp line_deleted?(%{delete: d}), do: d in [true, "true"]
  defp line_deleted?(_), do: false

  defp line_good_id(%Ecto.Changeset{} = cs), do: Ecto.Changeset.get_field(cs, :good_id)
  defp line_good_id(%{good_id: id}), do: id
  defp line_good_id(_), do: nil
end
