defmodule FullCircleWeb.TradingTransportAgentLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.TransportAgent
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
        cs =
          TransportAgent.changeset(%TransportAgent{}, %{
            "company_id" => company.id,
            "active" => true
          })

        {:ok,
         socket
         |> assign(page_title: gettext("New Transport Agent"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))}

      true ->
        agent = Trading.get_transport_agent!(params["id"], company, user)

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Transport Agent"))
         |> assign(live_action: :edit)
         |> assign(agent: agent)
         |> assign(form: to_form(TransportAgent.changeset(agent, %{})))}
    end
  end

  @impl true
  def handle_event("validate", %{"transport_agent" => params}, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> TransportAgent.changeset(%TransportAgent{}, params)
        :edit -> TransportAgent.changeset(socket.assigns.agent, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"transport_agent" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_transport_agent(params, company, user)
        :edit -> Trading.update_transport_agent(socket.assigns.agent, params, company, user)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Transport agent saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/transport_agents")}

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
        id="transport-agent-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded"
      >
        <.input field={@form[:name]} label={gettext("Name")} />
        <.input field={@form[:phone]} label={gettext("Phone")} />
        <.input field={@form[:active]} type="checkbox" label={gettext("Active")} />
        <div class="text-center mt-4">
          <.button>{gettext("Save")}</.button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/transport_agents"}
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
