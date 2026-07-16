defmodule FullCircleWeb.TradingLocationLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Location
  alias FullCircle.Authorization

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not Authorization.can?(user, :manage_trading, company) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      socket.assigns.live_action == :new ->
        cs = Location.changeset(%Location{}, %{"company_id" => company.id, "active" => true})

        {:ok,
         socket
         |> assign(page_title: gettext("New Location"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))}

      true ->
        loc = Trading.get_location!(params["id"], company, user)
        cs = Location.changeset(loc, %{})

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Location"))
         |> assign(live_action: :edit)
         |> assign(location: loc)
         |> assign(form: to_form(cs))}
    end
  end

  @impl true
  def handle_event("validate", %{"location" => params}, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> Location.changeset(%Location{}, params)
        :edit -> Location.changeset(socket.assigns.location, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"location" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_location(params, company, user)
        :edit -> Trading.update_location(socket.assigns.location, params, company, user)
      end

    case result do
      {:ok, _loc} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/locations")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="location-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded"
      >
        <.input field={@form[:name]} label={gettext("Name")} />
        <.input
          field={@form[:kind]}
          type="select"
          label={gettext("Kind")}
          options={Enum.map(Location.kinds(), &{&1, &1})}
        />
        <.input field={@form[:address_note]} type="textarea" label={gettext("Address note")} />
        <.input field={@form[:active]} type="checkbox" label={gettext("Active")} />
        <div class="text-center mt-4">
          <.button>{gettext("Save")}</.button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/locations"}
            class="gray button"
          >
            {gettext("Back")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
