defmodule FullCircleWeb.GoodLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Product
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["good_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
        :copy -> mount_copy(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(title: gettext("New Good"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Good, %Good{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    obj =
      Product.get_good!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(title: gettext("Edit Good"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Good, obj, %{}, socket.assigns.current_company))
    )
  end

  defp mount_copy(socket, id) do
    obj = Product.get_good!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(title: gettext("Copying Good"))
    |> assign(current_company: socket.assigns.current_company)
    |> assign(current_user: socket.assigns.current_user)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(Good, %Good{}, dup_good(obj), socket.assigns.current_company)
      )
    )
  end

  @impl true
  def handle_event("add_packaging", _, socket) do
    {:noreply, socket |> FullCircleWeb.Helpers.add_line(:packagings, %Packaging{})}
  end

  @impl true
  def handle_event("delete_packaging", %{"index" => index}, socket) do
    {:noreply, socket |> FullCircleWeb.Helpers.delete_line(String.to_integer(index), :packagings)}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["good", "purchase_account_name"], "good" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "purchase_account_name",
        "purchase_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "sales_account_name"], "good" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "sales_account_name",
        "sales_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "sales_tax_code_name"], "good" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "sales_tax_code_name",
        "sales_tax_code_id",
        &FullCircle.Accounting.get_tax_code_by_code/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "purchase_tax_code_name"], "good" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "purchase_tax_code_name",
        "purchase_tax_code_id",
        &FullCircle.Accounting.get_tax_code_by_code/3
      )

    validate(params, socket)
  end

  def handle_event("validate", %{"good" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"good" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Good,
           "good",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/goods")
         |> put_flash(:info, "#{gettext("Good deleted successfully.")}")}

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
           Good,
           "good",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/goods/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Good created successfully.")}")}

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
           Good,
           "good",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/goods/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Good updated successfully.")}")}

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
        Good,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  defp dup_good(object) do
    %{
      name: object.name <> " - COPY",
      purchase_account_name: object.purchase_account_name,
      sales_account_name: object.sales_account_name,
      purchase_tax_code_name: object.purchase_tax_code_name,
      sales_tax_code_name: object.sales_tax_code_name,
      purchase_account_id: object.purchase_account_id,
      sales_account_id: object.sales_account_id,
      purchase_tax_code_id: object.purchase_tax_code_id,
      sales_tax_code_id: object.sales_tax_code_id,
      unit: object.unit,
      descriptions: object.descriptions,
      packagings: dup_packages(object.packagings)
    }
  end

  defp dup_packages(objects) do
    objects
    |> Enum.map(fn x ->
      %{
        cost_per_package: x.cost_per_package,
        name: x.name,
        unit_multiplier: x.unit_multiplier
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-4/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:unit]} label={gettext("Unit")} />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <%= Phoenix.HTML.Form.hidden_input(@form, :sales_account_id) %>
            <.input
              field={@form[:sales_account_name]}
              label={gettext("Sales Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <div class="col-span-3">
            <%= Phoenix.HTML.Form.hidden_input(@form, :sales_tax_code_id) %>
            <.input
              field={@form[:sales_tax_code_name]}
              label={gettext("Sales TaxCode")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=saltaxcode&name="}
            />
          </div>
        </div>

        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <%= Phoenix.HTML.Form.hidden_input(@form, :purchase_account_id) %>
            <.input
              field={@form[:purchase_account_name]}
              label={gettext("Purchase Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <div class="col-span-3">
            <%= Phoenix.HTML.Form.hidden_input(@form, :purchase_tax_code_id) %>
            <.input
              field={@form[:purchase_tax_code_name]}
              label={gettext("Purchase TaxCode")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=purtaxcode&name="}
            />
          </div>
        </div>

        <div class="font-bold grid grid-cols-12 gap-2 mt-2">
          <div class="col-span-4">
            <%= gettext("Package Name") %>
          </div>
          <div class="col-span-3">
            <%= gettext("Unit Multiplier") %>
          </div>
          <div class="col-span-4">
            <%= gettext("Cost Per Pack") %>
          </div>
        </div>
        <.inputs_for :let={pack} field={@form[:packagings]}>
          <div class={"grid grid-cols-12 gap-2 #{if(pack[:delete].value == true and Enum.count(pack.errors) == 0, do: "hidden", else: "")}"}>
            <div class="col-span-4">
              <.input field={pack[:name]} />
            </div>
            <div class="col-span-3">
              <.input type="number" field={pack[:unit_multiplier]} step="0.0001" />
            </div>
            <div class="col-span-4">
              <.input type="number" field={pack[:cost_per_package]} step="0.0001" />
            </div>
            <div class="col-span-1 mt-2.5 text-rose-500">
              <.link phx-click={:delete_packaging} phx-value-index={pack.index}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(pack, :delete) %>
            </div>
          </div>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_packaging} class="blue_button">
            <%= gettext("Add Packaging") %>
          </.link>
        </div>

        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />
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
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Good Transactions, will be LOST!!!")}
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
            entity="goods"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end