defmodule FullCircleWeb.FixedAssetLive.Depreciations do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.{FixedAssetDepreciation}
  alias FullCircle.Accounting
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    ass =
      Accounting.get_fixed_asset!(
        params["id"],
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket =
      socket
      |> assign(ass: ass)
      |> assign(terms: params["terms"])
      |> assign(title: gettext("Depreciations"))
      |> assign(generated_depreciations: [])
      |> assign(live_action: :new)
      |> filter_depreciation()
      |> filter_depre_dates()
      |> to_form_fap()

    {:ok, socket}
  end

  defp filter_depreciation(socket) do
    depres = Accounting.depreciations_query(socket.assigns.ass.id)

    socket
    |> assign(saved_depreciations: depres)
  end

  defp filter_depre_dates(socket) do
    {dates, _} = Accounting.depreciation_dates(socket.assigns.ass, socket.assigns.current_company)
    dates = dates |> Enum.map(fn x -> Date.to_string(x) end)
    socket |> assign(depre_dates: dates)
  end

  defp to_form_fap(
         socket,
         obj \\ %FixedAssetDepreciation{},
         attrs \\ %{cost_basis: 0.00, amount: 0.00}
       ) do
    socket
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          FixedAssetDepreciation,
          obj,
          Map.merge(attrs, %{fixed_asset_id: socket.assigns.ass.id}),
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event("generate_depreciation", params, socket) do
    {:noreply,
     socket
     |> assign(
       generated_depreciations:
         Accounting.generate_depreciations(
           socket.assigns.ass,
           Date.from_iso8601!(params["ddate"]),
           socket.assigns.current_company
         )
     )}
  end

  @impl true
  def handle_event("validate", %{"fixed_asset_depreciation" => params}, socket) do
    changeset =
      StdInterface.changeset(
        FixedAssetDepreciation,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_depreciation", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(
           FixedAssetDepreciation,
           %FixedAssetDepreciation{fixed_asset_id: socket.assigns.ass.id},
           %{},
           socket.assigns.current_company
         )
       )
     )}
  end

  @impl true
  def handle_event("edit_depreciation", %{"id" => id}, socket) do
    fad = Accounting.get_fixed_asset_depreciation!(id)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(FixedAssetDepreciation, fad, %{}, socket.assigns.current_company)
       )
     )}
  end

  @impl true
  def handle_event("save_generated_depreciations", _, socket) do
    Accounting.save_generated_fixed_asset_depreciation(
      socket.assigns.generated_depreciations,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply,
     socket
     |> assign(generated_depreciations: [])
     |> assign(live_action: :new)
     |> filter_depreciation()
     |> filter_depre_dates()
     |> to_form_fap()}
  end

  @impl true
  def handle_event("delete_depreciation", %{"id" => id}, socket) do
    fad = Accounting.get_fixed_asset_depreciation!(id)

    case Accounting.delete_fixed_asset_depreciation(
           fad,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket |> filter_depreciation() |> filter_depre_dates() |> assign(live_action: :new)}

      {:error, _fo, _, fv} ->
        {:noreply, socket |> put_flash(:error, fv.message)}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"fixed_asset_depreciation" => params}, socket) do
    save_depreciation(socket, socket.assigns.live_action, params)
  end

  defp save_depreciation(socket, :new, params) do
    case Accounting.create_fixed_asset_depreciation(
           params,
           socket.assigns.ass,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket
         |> filter_depreciation()
         |> filter_depre_dates()
         |> assign(live_action: :new)
         |> to_form_fap()}

      {:error, failed_operation, changeset, _} ->
        {:onreply,
         assign(socket, form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  defp save_depreciation(socket, :edit, params) do
    case Accounting.update_fixed_asset_depreciation(
           socket.assigns.form.data,
           params,
           socket.assigns.ass,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket
         |> filter_depreciation()
         |> filter_depre_dates()
         |> assign(live_action: :new)
         |> to_form_fap()}

      {:error, _fo, _, fv} ->
        {:noreply, socket |> put_flash(:error, fv.message)}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-2xl text-center font-medium"><%= "#{@title} for #{@ass.name}" %></p>
      <div class="text-center m-4">
        <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
      </div>
      <p class="text-center">
        <span class="font-bold"><%= gettext("Depreciation info:") %></span>
        <%= Number.Currency.number_to_currency(@ass.pur_price) %> &#9679; <%= @ass.depre_start_date %> &#9679; <%= @ass.depre_method %> &#9679; <%= Number.Percentage.number_to_percentage(
          Decimal.mult(@ass.depre_rate, 100)
        ) %> &#9679; <%= @ass.depre_interval %><br />

        <span class="font-bold"><%= gettext("Depreciation A/C:") %></span>
        <%= @ass.depre_ac_name %>
        <span class="font-bold"><%= gettext("Cume Depreciation A/C:") %></span>
        <%= @ass.cume_depre_ac_name %>
      </p>

      <div class="border rounded bg-blue-200 p-4">
        <p class="w-full text-xl text-center font-medium">
          <%= gettext("Manual Create Depreciation") %>
        </p>

        <.form
          for={@form}
          id="depre-form"
          autocomplete="off"
          phx-change="validate"
          phx-submit="save"
          class="w-full"
        >
          <%= Phoenix.HTML.Form.hidden_input(@form, :fixed_asset_id) %>
          <div class="flex flex-row flex-nowarp">
            <div class="w-3/12 grow shrink">
              <.input type="date" field={@form[:depre_date]} label={gettext("Depreciation Date")} />
            </div>
            <div class="w-3/12 grow shrink">
              <.input
                type="number"
                field={@form[:cost_basis]}
                label={gettext("Cost Basis")}
                step="0.01"
              />
            </div>
            <div class="w-3/12 grow shrink">
              <.input
                type="number"
                field={@form[:amount]}
                label={gettext("Depreciation")}
                step="0.01"
              />
            </div>
            <div class="w-3/12 grow shrink">
              <.input
                type="select"
                field={@form[:is_seed]}
                label={gettext("Is Seed Data")}
                options={[true, false]}
              />
            </div>
          </div>
          <div class="flex justify-center gap-x-1 mt-1">
            <.link phx-click={:new_depreciation} class="blue_button" id="new_object">
              <%= gettext("New") %>
            </.link>
            <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          </div>
        </.form>
      </div>

      <div class="mt-4 border rounded bg-rose-200 p-5">
        <p class="w-full text-xl text-center font-medium"><%= gettext("Saved Depreciations") %></p>
        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-[17%]"><%= gettext("Date") %></div>
          <div class="detail-header w-[20%]"><%= gettext("Cost Basis") %></div>
          <div class="detail-header w-[20%]">
            <%= gettext("Depreciation") %>
          </div>
          <div class="detail-header w-[20%]">
            <%= gettext("Cume Depreciation") %>
          </div>
          <div class="detail-header w-[20%]">
            <%= gettext("Net Book Value") %>
          </div>
        </div>
        <div id="saved_depreciation_list">
          <%= for obj <- @saved_depreciations do %>
            <div
              class={[
                "flex flex-row text-center tracking-tighter",
                !obj.closed && "hover:cursor-pointer"
              ]}
              phx-click={!obj.closed && :edit_depreciation}
              phx-value-id={obj.id}
            >
              <div class={[
                "w-[17%] border rounded bg-green-200 border-green-400 text-center px-2 py-1",
                !obj.closed && "hover:bg-green-300"
              ]}>
                <%= obj.depre_date %>
              </div>
              <div class={[
                "w-[20%] border rounded bg-green-200 border-green-400 text-center px-2 py-1",
                !obj.closed && "hover:bg-green-300"
              ]}>
                <%= obj.cost_basis |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class={[
                "w-[20%] border rounded bg-green-200 border-green-400 text-center px-2 py-1",
                !obj.closed && "hover:bg-green-300"
              ]}>
                <%= obj.amount |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class={[
                "w-[20%] border rounded bg-green-200 border-green-400 text-center px-2 py-1",
                !obj.closed && "hover:bg-green-300"
              ]}>
                <%= obj.cume_depre |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class={[
                "w-[20%] border rounded bg-green-200 border-green-400 text-center px-2 py-1",
                !obj.closed && "hover:bg-green-300"
              ]}>
                <%= Decimal.sub(obj.cost_basis, obj.cume_depre)
                |> Number.Delimit.number_to_delimited() %>
              </div>

              <div :if={!obj.closed} class="w-[3%] mt-1 text-rose-500  hover:bg-blue-200">
                <.link phx-click={:delete_depreciation} phx-value-id={obj.id} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
              </div>

              <div class="mt-1">
                <.live_component
                  :if={!obj.is_seed}
                  module={FullCircleWeb.JournalEntryViewLive.Component}
                  id={"journal_#{obj.id}"}
                  show_journal={false}
                  doc_type="fixed_asset_depreciations"
                  doc_no={obj.doc_no}
                  company_id={@ass.company_id}
                />
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div class="my-4 border rounded bg-purple-200 p-5 text-center">
        <.form :let={f} for={%{}} phx-submit="generate_depreciation" autocomplete="off">
          <%= Phoenix.HTML.Form.select(f, :ddate, @depre_dates,
            class: "rounded py-2 pl-3 pr-10 border bg-indigo-50 text-xl"
          ) %>
          <.button><%= gettext("Generate Depreciations") %></.button>
        </.form>

        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-[20%]"><%= gettext("Date") %></div>
          <div class="detail-header w-[20%]"><%= gettext("Cost Basis") %></div>
          <div class="detail-header w-[20%]">
            <%= gettext("Depreciation") %>
          </div>
          <div class="detail-header w-[20%]">
            <%= gettext("Cume Depreciation") %>
          </div>
          <div class="detail-header w-[20%]">
            <%= gettext("Net Book Value") %>
          </div>
        </div>
        <div id="generated_depreciation_list">
          <%= for obj <- @generated_depreciations do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-[20%] border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.depre_date %>
              </div>
              <div class="w-[20%] border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.cost_basis |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[20%] border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.amount |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[20%] border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.cume_depre |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[20%] border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= (obj.cost_basis - obj.cume_depre) |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          <% end %>
        </div>
        <div class="mt-4">
          <.link
            :if={Enum.count(@generated_depreciations) > 0}
            phx-click={:save_generated_depreciations}
            class={["blue_button"]}
          >
            <%= gettext("Save Generated Depreciations") %>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
