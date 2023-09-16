defmodule FullCircleWeb.FixedAssetLive.Disposals do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.{FixedAssetDisposal}
  alias FullCircle.Accounting
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(terms: params["terms"])
      |> load_fixed_asset(params["id"])
      |> assign(title: gettext("Disposals"))
      |> assign(live_action: :new)
      |> filter_disposal()
      |> to_form_fap()

    {:ok, socket}
  end

  defp filter_disposal(socket) do
    socket |> assign(saved_disposals: Accounting.disposals_query(socket.assigns.ass.id))
  end

  defp load_fixed_asset(socket, id) do
    socket
    |> assign(
      ass:
        Accounting.get_fixed_asset!(
          id,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
    )
  end

  defp to_form_fap(
         socket,
         obj \\ %FixedAssetDisposal{},
         attrs \\ %{cost_basis: 0.00, amount: 0.00}
       ) do
    socket
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          FixedAssetDisposal,
          obj,
          Map.merge(attrs, %{fixed_asset_id: socket.assigns.ass.id}),
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event("validate", %{"fixed_asset_disposal" => params}, socket) do
    changeset =
      StdInterface.changeset(
        FixedAssetDisposal,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_disposal", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(
           FixedAssetDisposal,
           %FixedAssetDisposal{fixed_asset: socket.assigns.ass},
           %{},
           socket.assigns.current_company
         )
       )
     )}
  end

  @impl true
  def handle_event("edit_disposal", %{"id" => id}, socket) do
    fad = Accounting.get_fixed_asset_disposal!(id)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(FixedAssetDisposal, fad, %{}, socket.assigns.current_company)
       )
     )}
  end

  @impl true
  def handle_event("delete_disposal", %{"id" => id}, socket) do
    fad = Accounting.get_fixed_asset_disposal!(id)

    case StdInterface.delete(
           FixedAssetDisposal,
           "fixed_asset_disposal",
           fad,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket
         |> load_fixed_asset(socket.assigns.ass.id)
         |> filter_disposal
         |> assign(live_action: :new)}

      {:error, _, changeset, _} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"fixed_asset_disposal" => params}, socket) do
    save_disposal(socket, socket.assigns.live_action, params)
  end

  defp save_disposal(socket, :new, params) do
    case StdInterface.create(
           FixedAssetDisposal,
           "fixed_asset_disposal",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket
         |> load_fixed_asset(socket.assigns.ass.id)
         |> filter_disposal()
         |> assign(live_action: :new)
         |> to_form_fap()}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        {:noreply, socket}
    end
  end

  defp save_disposal(socket, :edit, params) do
    case StdInterface.update(
           FixedAssetDisposal,
           "fixed_asset_disposal",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _dep} ->
        {:noreply,
         socket
         |> load_fixed_asset(socket.assigns.ass.id)
         |> filter_disposal()
         |> assign(live_action: :new)
         |> to_form_fap()}

      {:error, failed_operation, changeset, _} ->
        assign(socket, form: to_form(changeset))
        |> put_flash(
          :error,
          "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
        )

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-5/12 mx-auto text-center">
      <p class="w-full text-2xl text-center font-medium"><%= "#{@title} for #{@ass.name}" %></p>
      <div class="text-center m-4">
        <a onclick="history.back();" class="blue button"><%= gettext("Back") %></a>
      </div>
      <p>
        <span class="font-bold"><%= gettext("Assets info:") %></span>
        <%= Number.Currency.number_to_currency(@ass.pur_price) %> &#9679; <%= @ass.depre_start_date %> &#9679; <%= @ass.depre_method %> &#9679; <%= Number.Percentage.number_to_percentage(
          Decimal.mult(@ass.depre_rate, 100)
        ) %> &#9679; <%= @ass.depre_interval %>
      </p>
      <p>
        <span class="font-bold"><%= gettext("Cume Depreciations:") %></span>
        <%= Number.Currency.number_to_currency(@ass.cume_depre) %> &#9679;
        <span class="font-bold"><%= gettext("Cume Disposals:") %></span>
        <%= Number.Currency.number_to_currency(@ass.cume_disp) %> &#9679;
        <span class="font-bold text-purple-800">
          <%= gettext("Net Book Value:") %>
          <%= @ass.pur_price
          |> Decimal.sub(@ass.cume_disp)
          |> Decimal.sub(@ass.cume_depre)
          |> Number.Currency.number_to_currency() %>
        </span>
      </p>

      <div class="border rounded bg-blue-200 p-4">
        <p class="w-full text-xl text-center font-medium">
          <%= gettext("Create Disposal") %>
        </p>

        <.form
          for={@form}
          id="disp-form"
          autocomplete="off"
          phx-change="validate"
          phx-submit="save"
          class="w-full"
        >
          <%= Phoenix.HTML.Form.hidden_input(@form, :fixed_asset_id) %>
          <div class="flex flex-row flex-nowarp">
            <div class="w-4/12 grow shrink">
              <.input type="date" field={@form[:disp_date]} label={gettext("Disposal Date")} />
            </div>
            <div class="w-4/12 grow shrink">
              <.input type="number" field={@form[:amount]} label={gettext("Disposal")} step="0.01" />
            </div>
            <div class="w-4/12 grow shrink">
              <.input
                type="select"
                field={@form[:is_seed]}
                label={gettext("Is Seed Data")}
                options={[true, false]}
              />
            </div>
          </div>

          <div class="flex justify-center gap-x-1 mt-1">
            <.link phx-click={:new_disposal} class="blue button" id="new_object">
              <%= gettext("New") %>
            </.link>
            <.save_button form={@form} />
          </div>
        </.form>
      </div>

      <div class="mt-4 border rounded bg-rose-200 p-5">
        <p class="w-full text-xl text-center font-medium"><%= gettext("Saved Disposals") %></p>
        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-5/12"><%= gettext("Date") %></div>
          <div class="detail-header w-5/12">
            <%= gettext("Disposal") %>
          </div>
        </div>
        <div id="saved_disposal_list">
          <%= for obj <- @saved_disposals do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-5/12 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.disp_date %>
              </div>
              <div class="w-5/12 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.amount |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-5 mt-1 text-blue-500 hover:bg-amber-200">
                <.link phx-click={:edit_disposal} phx-value-id={obj.id} tabindex="-1">
                  <.icon name="hero-pencil-solid" class="h-5 w-5" />
                </.link>
              </div>
              <div class="w-5 mt-1 text-rose-500  hover:bg-blue-200">
                <.link phx-click={:delete_disposal} phx-value-id={obj.id} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
              </div>
              <div class="mt-1">
                <.live_component
                  :if={!obj.is_seed}
                  module={FullCircleWeb.JournalEntryViewLive.Component}
                  id={"journal_#{obj.id}"}
                  show_journal={false}
                  doc_type="fixed_asset_disposals"
                  doc_no={obj.disp_date |> Timex.format!("%Y%m%d", :strftime)}
                  company_id={@ass.company_id}
                />
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
