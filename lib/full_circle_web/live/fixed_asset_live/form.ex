defmodule FullCircleWeb.FixedAssetLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.FixedAsset
  alias FullCircle.Accounting
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["asset_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(title: gettext("New Fixed Asset"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(FixedAsset, %FixedAsset{}, %{}, socket.assigns.current_company)
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      Accounting.get_fixed_asset!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(title: gettext("Edit Fixed Asset"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(FixedAsset, obj, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["fixed_asset", "asset_ac_name"], "fixed_asset" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "asset_ac_name",
        "asset_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
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
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "cume_depre_ac_name",
        "cume_depre_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
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
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "depre_ac_name",
        "depre_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
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
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "disp_fund_ac_name",
        "disp_fund_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
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
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/fixed_assets")
         |> put_flash(:info, "#{gettext("Fixed Asset deleted successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           FixedAsset,
           "fixed_asset",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/fixed_assets/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Fixed Asset created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           FixedAsset,
           "fixed_asset",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/fixed_assets/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Fixed Asset updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
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
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-2xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class=""
      >
        <div class="flex flex-row gap-1">
          <div class="w-[50%]">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="w-[20%]">
            <.input type="date" field={@form[:pur_date]} label={gettext("Purchase Date")} />
          </div>
          <div :if={@live_action != :new} class="w-[30%] text-center">
            <p>
              <.link
                :if={@form.data.depre_method != "No Depreciation"}
                navigate={
                  ~p"/companies/#{@current_company.id}/fixed_assets/#{@form.data.id}/depreciations"
                }
                class="hover:font-bold text-blue-700"
              >
                <%= gettext("Depreciations") %> - <%= Number.Currency.number_to_currency(
                  @form.data.cume_depre
                ) %>
              </.link>
            </p>
            <p>
              <.link
                navigate={
                  ~p"/companies/#{@current_company.id}/fixed_assets/#{@form.data.id}/disposals"
                }
                class="hover:font-bold text-blue-700"
              >
                <%= gettext("Disposal") %> - <%= Number.Currency.number_to_currency(
                  @form.data.cume_disp
                ) %>
              </.link>
            </p>
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-3/12">
            <.input
              type="number"
              step="0.01"
              field={@form[:pur_price]}
              label={gettext("Purchase Price")}
            />
          </div>
          <div class="w-3/12">
            <.input
              type="date"
              field={@form[:depre_start_date]}
              label={gettext("Depreciation Start")}
            />
          </div>
          <div class="w-3/12">
            <.input
              type="number"
              step="0.01"
              field={@form[:depre_rate]}
              label={gettext("Dep Rate(0.1 = 10%)")}
            />
          </div>
          <div class="w-3/12">
            <.input
              type="number"
              step="0.01"
              field={@form[:residual_value]}
              label={gettext("Residual Value")}
            />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-3/12">
            <.input
              field={@form[:depre_method]}
              label={gettext("Depreciation Method")}
              type="select"
              options={FullCircle.Accounting.depreciation_methods()}
            />
          </div>
          <div class="w-3/12">
            <.input
              field={@form[:depre_interval]}
              label={gettext("Depreciation Interval")}
              type="select"
              options={FullCircle.Accounting.depreciation_intervals()}
            />
          </div>
          <div class="w-6/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :asset_ac_id) %>
            <.input
              field={@form[:asset_ac_name]}
              label={gettext("Asset Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-4/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :depre_ac_id) %>
            <.input
              field={@form[:depre_ac_name]}
              label={gettext("Depreciation Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <div class="w-4/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :cume_depre_ac_id) %>
            <.input
              field={@form[:cume_depre_ac_name]}
              label={gettext("Cume Depreciation Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <div class="w-4/12">
            <%= Phoenix.HTML.Form.hidden_input(@form, :disp_fund_ac_id) %>
            <.input
              field={@form[:disp_fund_ac_name]}
              label={gettext("Disposal Fund Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
        </div>

        <.input field={@form[:descriptions]} type="textarea" label={gettext("Descriptions")} />

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link
            :if={Enum.any?(@form.source.changes) and @live_action != :new}
            navigate=""
            class="orange_button"
          >
            <%= gettext("Cancel") %>
          </.link>
          <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_fixed_asset, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Fixed Asset Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="fixed_assets"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
