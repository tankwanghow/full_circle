defmodule FullCircleWeb.FixedAssetLive.CalAllDepre do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(ddate: Timex.today())
      |> assign(page_title: gettext("Calculate All Fixed Assets Depreciations"))
      |> assign(generated_depreciations: [])
      |> assign(live_action: :new)
      |> assign(valid?: false)

    {:ok, socket}
  end

  @impl true
  def handle_event("generate_depreciation", params, socket) do
    deps =
      Accounting.generate_depreciations_for_all_fixed_assets(
        Date.from_iso8601!(params["ddate"]),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket =
      if Enum.empty?(deps) do
        put_flash(socket, :warn, gettext("No depreciation calculated!!"))
      else
        put_flash(socket, :info, gettext("Finish calculating depreciations!!"))
      end

    {:noreply, socket |> assign(generated_depreciations: deps) |> assign(valid?: false)}
  end

  @impl true
  def handle_event("save_generated_depreciations", _, socket) do
    Accounting.save_generated_all_fixed_asset_depreciation(
      socket.assigns.generated_depreciations,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply,
     socket
     |> assign(generated_depreciations: [])
     |> assign(live_action: :new)
     |> put_flash(:success, gettext("Depreciations Saved!!"))
     |> assign(valid?: false)}
  end

  @impl true
  def handle_event("validate", %{"ddate" => ddate}, socket) do
    socket =
      if ddate != "" do
        assign(socket, valid?: true)
      else
        assign(socket, valid?: false)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="text-center m-4">
        <a onclick="history.back();" class="blue button">{gettext("Back")}</a>
      </div>

      <div class="my-4 border rounded bg-purple-200 p-5 text-center">
        <.form for={%{}} phx-submit="generate_depreciation" autocomplete="off" phx-change="validate">
          <div class="flex gap-2">
            <div class="font-bold mt-2">{gettext("Until")}</div>
            <div class="mt-1">
              <.input name="ddate" type="date" value={@ddate} id="ddate" />
            </div>
            <div>
              <.button disabled={!@valid?}>{gettext("Generate Depreciations")}</.button>
            </div>
          </div>
        </.form>

        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-2/12">{gettext("Date")}</div>
          <div class="detail-header w-6/12">{gettext("Asset")}</div>
          <div class="detail-header w-2/12">{gettext("Cost Basis")}</div>
          <div class="detail-header w-2/12">
            {gettext("Depreciation")}
          </div>
        </div>
        <div id="generated_depreciation_list">
          <%= for obj <- @generated_depreciations do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-2/12 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                {obj.depre_date}
              </div>
              <div class="w-6/12 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                {obj.fixed_asset.name}
              </div>
              <div class="w-2/12 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                {obj.cost_basis |> Number.Delimit.number_to_delimited()}
              </div>
              <div class="w-2/12 border rounded bg-amber-200 border-amber-400 text-center px-2 py-1">
                {obj.amount |> Number.Delimit.number_to_delimited()}
              </div>
            </div>
          <% end %>
        </div>
        <div class="mt-4">
          <.link
            :if={Enum.count(@generated_depreciations) > 0}
            phx-click={:save_generated_depreciations}
            class="blue button"
          >
            {gettext("Save Generated Depreciations")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
