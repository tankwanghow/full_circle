defmodule FullCircleWeb.FixedAssetLive.Depreciations do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.{FixedAsset, FixedAssetDepreciation}
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

    {dates, _} = Accounting.depreciation_dates(ass, socket.assigns.current_company)
    dates = dates |> Enum.map(fn x -> Date.to_string(x) end)

    socket =
      socket
      |> assign(title: gettext("Depreciations"))
      |> assign(saved_depreciations: Accounting.depreciations_query(ass.id))
      |> assign(generated_depreciations: [])
      |> assign(depre_dates: dates)
      |> assign(ass: ass)
      |> assign(live_action: :new)
      |> assign(
        :form,
        to_form(
          StdInterface.changeset(
            FixedAssetDepreciation,
            %FixedAssetDepreciation{},
            %{fixed_asset_id: ass.id, cost_basis: ass.pur_price, amount: 0.00},
            socket.assigns.current_company
          )
        )
      )

    {:ok, socket}
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
  def handle_event("save", %{"fixed_asset_depreciation" => params}, socket) do
    save_depreciation(socket, socket.assigns.live_action, params)
  end

  defp save_depreciation(socket, :new, params) do
    case StdInterface.create(
           FixedAssetDepreciation,
           "fixed_asset_depreciation",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        send(self(), {:created, ac})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save_depreciation(socket, :edit, params) do
    case StdInterface.update(
           FixedAssetDepreciation,
           "fixed_asset_depreciation",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        send(self(), {:updated, ac})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        assign(socket, form: to_form(changeset))
        |> put_flash(
          :error,
          "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
        )

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-2xl text-center font-medium"><%= "#{@title} for #{@ass.name}" %></p>
      <div class="text-center m-4">
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets"} class="nav-btn">
          <%= gettext("Back Fixed Assets Listing") %>
        </.link>
      </div>
      <p class="text-center">
        <span class="font-bold"><%= gettext("Depreciation info:") %></span>
        <%= @ass.depre_ac_name %> &#9679; <%= @ass.depre_start_date %> &#9679; <%= @ass.depre_method %> &#9679; <%= Number.Percentage.number_to_percentage(
          Decimal.mult(@ass.depre_rate, 100)
        ) %> &#9679; <%= @ass.depre_interval %>
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
            <div class="w-4/12 grow shrink">
              <.input
                type="select"
                options={@depre_dates}
                field={@form[:depre_date]}
                label={gettext("Depreciation Date")}
              />
            </div>
            <div class="w-4/12 grow shrink">
              <.input type="number" field={@form[:cost_basis]} label={gettext("Cost Basis")} />
            </div>
            <div class="w-4/12 grow shrink">
              <.input type="number" field={@form[:amount]} label={gettext("Depreciation")} />
            </div>
          </div>
          <div class="flex justify-center gap-x-1 mt-1">
            <.button class="mx-auto" disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          </div>
        </.form>
      </div>

      <div class="mt-4 border rounded bg-rose-200 p-5">
        <p class="w-full text-xl text-center font-medium"><%= gettext("Saved Depreciations") %></p>
        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-36"><%= gettext("Date") %></div>
          <div class="detail-header w-36"><%= gettext("Cost Basis") %></div>
          <div class="detail-header w-40">
            <%= gettext("Depreciation") %>
          </div>
          <div class="detail-header w-40">
            <%= gettext("Cume Depreciation") %>
          </div>
          <div class="detail-header w-40">
            <%= gettext("Net Book Value") %>
          </div>
        </div>
        <div id="saved_depreciation_list">
          <%= for obj <- @saved_depreciations do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-36 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.depre_date %>
              </div>
              <div class="w-36 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.cost_basis |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.amount |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.cume_depre |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= Decimal.sub(obj.cost_basis, obj.cume_depre)
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div class="mt-4 border rounded bg-purple-200 p-5 text-center">
        <.form :let={f} for={%{}} phx-submit="generate_depreciation" autocomplete="off">
          <%= Phoenix.HTML.Form.select(f, :ddate, @depre_dates,
            class: "rounded py-2 pl-3 pr-10 border bg-indigo-50 text-xl"
          ) %>
          <.button><%= gettext("Generate Depreciations") %></.button>
        </.form>

        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-36"><%= gettext("Date") %></div>
          <div class="detail-header w-36"><%= gettext("Cost Basis") %></div>
          <div class="detail-header w-40">
            <%= gettext("Depreciation") %>
          </div>
          <div class="detail-header w-40">
            <%= gettext("Cume Depreciation") %>
          </div>
          <div class="detail-header w-40">
            <%= gettext("Net Book Value") %>
          </div>
        </div>
        <div id="generated_depreciation_list">
          <%= for obj <- @generated_depreciations do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-36 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.depre_date %>
              </div>
              <div class="w-36 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.cost_basis |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.amount |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= obj.cume_depre |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-40 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                <%= (obj.cost_basis - obj.cume_depre) |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
