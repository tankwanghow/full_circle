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
  def handle_event("cancel_delete", _, socket) do
    {:noreply, socket}
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
        %{"_target" => ["fixed_asset", "cume_depre_ac_name"], "fixed_asset" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "cume_depre_ac_name",
        :account_names,
        "cume_depre_ac_id",
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
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-8">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="col-span-4">
            <.input field={@form[:pur_date]} label={gettext("Purchase Date")} type="date" />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-8">
            <%= Phoenix.HTML.Form.hidden_input(@form, :asset_ac_id) %>
            <.input
              field={@form[:asset_ac_name]}
              label={gettext("Asset Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="col-span-4">
            <.input
              type="number"
              step="0.01"
              field={@form[:pur_price]}
              label={gettext("Purchase Price")}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-4">
            <.input
              field={@form[:depre_start_date]}
              label={gettext("Depreciation Start Date")}
              type="date"
            />
          </div>
          <div class="col-span-4">
            <.input
              type="number"
              step="0.01"
              field={@form[:depre_rate]}
              label={gettext("Depreciation Rate (10% = 0.1)")}
            />
          </div>
          <div class="col-span-4">
            <.input
              type="number"
              step="0.01"
              field={@form[:residual_value]}
              label={gettext("Residual Value")}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-7">
            <%= Phoenix.HTML.Form.hidden_input(@form, :depre_ac_id) %>
            <.input
              field={@form[:depre_ac_name]}
              label={gettext("Depreciation Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="col-span-5">
            <.input
              field={@form[:depre_method]}
              label={gettext("Depreciation Methods")}
              type="select"
              options={FullCircle.Accounting.depreciation_methods()}
            />
          </div>
        </div>
        <%= Phoenix.HTML.Form.hidden_input(@form, :cume_depre_ac_id) %>
        <.input
          field={@form[:cume_depre_ac_name]}
          label={gettext("Cumalitive Depreciation Account")}
          list="account_names"
          phx-debounce={500}
        />

        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

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
