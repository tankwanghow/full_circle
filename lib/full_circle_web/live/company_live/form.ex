defmodule FullCircleWeb.CompanyLive.Form do
  use FullCircleWeb, :live_view
  alias FullCircle.Sys
  alias FullCircle.Sys.Company

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <.form
      for={@form}
      id="company"
      autocomplete="off"
      phx-change="validate"
      phx-submit="save"
      phx-trigger-action={@trigger_submit}
      action={@trigger_action}
      method={@trigger_method}
      class="max-w-2xl mx-auto"
    >
      <div class="grid grid-cols-12 gap-2">
        <div class="col-span-12">
          <.input field={@form[:name]} label={gettext("Name")} />
        </div>
        <div class="col-span-6">
          <.input field={@form[:address1]} label={gettext("Address Line 1")} />
        </div>
        <div class="col-span-6">
          <.input field={@form[:address2]} label={gettext("Address Line 2")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:city]} label={gettext("City")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:zipcode]} label={gettext("Postal Code")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:state]} label={gettext("State")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:country]} label={gettext("Country")} list="countries" />
        </div>
        <div class="col-span-4">
          <.input field={@form[:timezone]} label={gettext("Time Zone")} list="timezones" />
        </div>
        <div class="col-span-4">
          <.input field={@form[:tel]} label={gettext("Tel")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:fax]} label={gettext("Fax")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:email]} type="email" label={gettext("Email")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:reg_no]} label={gettext("Reg No")} />
        </div>
        <div class="col-span-4">
          <.input field={@form[:tax_id]} label={gettext("Tax No")} />
        </div>
        <div class="col-span-4">
          <.input
            field={@form[:closing_month]}
            options={[
              January: 1,
              February: 2,
              March: 3,
              April: 4,
              May: 5,
              June: 6,
              July: 7,
              August: 8,
              September: 9,
              October: 10,
              November: 11,
              December: 12
            ]}
            type="select"
            label={gettext("Closing Month")}
          />
        </div>
        <div class="col-span-4">
          <.input
            field={@form[:closing_day]}
            options={Enum.to_list(1..31)}
            type="select"
            label={gettext("Closing Day")}
          />
        </div>
        <div class="col-span-12">
          <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
        </div>
      </div>
      <%= datalist(FullCircle.Sys.countries(), "countries") %>
      <%= datalist(Tzdata.zone_list(), "timezones") %>
      <div class="flex justify-center gap-x-1 mt-2">
        <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
        <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_company, @company) do %>
          <.delete_confirm_modal
            id="delete-company"
            msg1={gettext("All Company Data, will be LOST!!!")}
            msg2={gettext("Cannot Be Recover!!!")}
            confirm={JS.push("delete")}
          />
        <% end %>
        <.link_button navigate="/companies">
          <%= gettext("Back") %>
        </.link_button>
      </div>
    </.form>
    """
  end

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign(:current_company, session["current_company"])
      |> assign(:current_role, session["current_role"])

    case socket.assigns.live_action do
      :new -> mount_new(socket)
      :edit -> mount_edit(params, socket)
    end
  end

  defp mount_new(socket) do
    form = to_form(Sys.company_changeset(%Company{}, %{}, socket.assigns.current_user))

    {:ok,
     socket
     |> assign(:page_title, gettext("Creating Company"))
     |> assign(:form, form)
     |> assign(:trigger_submit, false)
     |> assign(:trigger_action, nil)
     |> assign(:trigger_method, nil)}
  end

  defp mount_edit(%{"id" => id}, socket) do
    company = Sys.get_company!(id)
    form = to_form(Sys.company_changeset(company, %{}, socket.assigns.current_user))

    {:ok,
     socket
     |> assign(:page_title, gettext("Editing Company"))
     |> assign(:form, form)
     |> assign(:trigger_submit, false)
     |> assign(:trigger_action, ~p"/update_active_company?id=#{company.id}")
     |> assign(:trigger_method, "post")
     |> assign(:company, company)}
  end

  @impl true
  def handle_event("validate", %{"company" => params}, socket) do
    company = if(socket.assigns[:company], do: socket.assigns.company, else: %Company{})

    changeset =
      company
      |> Sys.company_changeset(params, socket.assigns.current_user)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"company" => company_params}, socket) do
    save_company(socket, socket.assigns.live_action, company_params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Sys.delete_company(socket.assigns.company, socket.assigns.current_user) do
      {:ok, com} ->
        if com.id == Util.attempt(socket.assigns.current_company, :id) do
          {:noreply,
           socket
           |> redirect(to: ~p"/delete_active_company")}
        else
          {:noreply,
           socket
           |> put_flash(:success, gettext("Company Deleted!"))
           |> push_navigate(to: ~p"/companies")}
        end

      {:error, _, changeset, _} ->
        {:noreply,
         assign(socket, form: to_form(changeset))
         |> put_flash(:error, gettext("Failed to Delete Company"))}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No Authorization"))}
    end
  end

  defp save_company(socket, :edit, company_params) do
    case Sys.update_company(socket.assigns.company, company_params, socket.assigns.current_user) do
      {:ok, com} ->
        if com.id == Util.attempt(socket.assigns.current_company, :id) do
          {:noreply,
           socket
           |> assign(:trigger_submit, true)}
        else
          {:noreply,
           socket
           |> assign(:trigger_submit, false)
           |> push_navigate(to: ~p"/companies")}
        end

      {:error, _, changeset, _} ->
        {:noreply,
         assign(socket, form: to_form(changeset))
         |> put_flash(:error, gettext("Failed to Update Company"))}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No Authorization"))}
    end
  end

  defp save_company(socket, :new, company_params) do
    case Sys.create_company(company_params, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies")}

      {:error, _, changeset, _} ->
        {:noreply,
         assign(socket, form: to_form(changeset))
         |> put_flash(:error, gettext("Failed to Create Company"))}
    end
  end
end
