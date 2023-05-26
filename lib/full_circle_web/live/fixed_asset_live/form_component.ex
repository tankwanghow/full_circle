defmodule FullCircleWeb.FixedAssetLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting.FixedAsset
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:account_names, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["fixed_asset", "asset_ac_name"], "fixed_asset" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "asset_ac_name",
        :account_names,
        "asset_ac_id",
        &FullCircle.Accounting.account_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["fixed_asset", "depre_ac_name"], "fixed_asset" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "depre_ac_name",
        :account_names,
        "depre_ac_id",
        &FullCircle.Accounting.account_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["fixed_asset", "disp_fund_ac_name"], "fixed_asset" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "disp_fund_ac_name",
        :account_names,
        "disp_fund_ac_id",
        &FullCircle.Accounting.account_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"fixed_asset" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"fixed_asset" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           FixedAsset,
           "fixed_asset",
           socket.assigns.form.data,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           FixedAsset,
           "fixed_asset",
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           FixedAsset,
           "fixed_asset",
           socket.assigns.form.data,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        FixedAsset,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-2xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class=""
      >
        <div class="flex flex-row gap-1">
          <div class="w-[35rem]">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="w-[9.5rem]">
            <.input type="date" field={@form[:pur_date]} label={gettext("Purchase Date")} />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-[35rem]">
            <%= Phoenix.HTML.Form.hidden_input(@form, :asset_ac_id) %>
            <.input
              field={@form[:asset_ac_name]}
              label={gettext("Asset Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>

          <div class="w-[9.5rem]">
            <.input
              type="number"
              step="0.01"
              field={@form[:pur_price]}
              label={gettext("Purchase Price")}
            />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-[9.5rem]">
            <.input
              type="date"
              field={@form[:depre_start_date]}
              label={gettext("Depreciation Start")}
            />
          </div>
          <div class="w-[9.5rem]">
            <.input
              type="number"
              step="0.01"
              field={@form[:depre_rate]}
              label={gettext("Dep Rate(0.1 = 10%)")}
            />
          </div>
          <div class="w-[8rem]">
            <.input
              type="number"
              step="0.01"
              field={@form[:residual_value]}
              label={gettext("Residual Value")}
            />
          </div>
          <div class="w-[18rem]">
            <.input
              field={@form[:depre_method]}
              label={gettext("Depreciation Methods")}
              type="select"
              options={FullCircle.Accounting.depreciation_methods()}
            />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-6/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :depre_ac_id) %>
            <.input
              field={@form[:depre_ac_name]}
              label={gettext("Depreciation Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="w-6/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :disp_fund_ac_id) %>
            <.input
              field={@form[:disp_fund_ac_name]}
              label={gettext("Disposal Fund Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
        </div>

        <.input field={@form[:descriptions]} type="textarea" label={gettext("Descriptions")} />

        <%!-- <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Date") %></div>
          <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Cost Basis") %></div>
          <div class="detail-header w-3/12 shrink-[1] grow-[1]">
            <%= gettext("Cume Depreciation") %>
          </div>
          <div class="detail-header w-3/12 shrink-[1] grow-[1]">
            <%= gettext("YTD Depreciation") %>
          </div>
        </div>

        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Date") %></div>
          <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Dispose Amount") %></div>
          <div class="detail-header w-3/12 shrink-[1] grow-[1]"><%= gettext("Disposal Fund Account") %></div>
        </div> --%>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_fixed_asset, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Fixed Asset Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.remove_attribute("class", to: "#phx-feedback-for-fixed_asset_name")
                |> JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.link phx-click={JS.exec("phx-remove", to: "#object-crud-modal")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
      <%= datalist_with_ids(@account_names, "account_names") %>
    </div>
    """
  end
end
