defmodule FullCircleWeb.TaxCodeLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting.TaxCode
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
        %{"_target" => ["tax_code", "account_name"], "tax_code" => params},
        socket
      ) do
    terms = params["account_name"]

    socket =
      assign(
        socket,
        :account_names,
        FullCircle.Accounting.account_names(
          terms,
          socket.assigns.current_user,
          socket.assigns.current_company
        )
      )

    account =
      Enum.find(socket.assigns[:account_names], fn x ->
        x.value == params["account_name"]
      end)

    params = Map.merge(params, %{"account_id" => Util.attempt(account, :id) || -1})

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"tax_code" => params}, socket) do
    object = if(socket.assigns[:object], do: socket.assigns.object, else: %TaxCode{})

    changeset =
      StdInterface.changeset(TaxCode, object, params, socket.assigns.current_company)
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"tax_code" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           TaxCode,
           "tax_code",
           socket.assigns.object,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           TaxCode,
           "tax_code",
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           TaxCode,
           "tax_code",
           socket.assigns.object,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp validate(params, socket) do
    object = if(socket.assigns[:object], do: socket.assigns.object, else: %TaxCode{})

    changeset =
      StdInterface.changeset(TaxCode, object, params, socket.assigns.current_company)
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
        class="max-w-md mx-auto"
      >
        <.input field={@form[:code]} label={gettext("Code")} />

        <.input
          field={@form[:tax_type]}
          label={gettext("TaxCode Type")}
          type="select"
          options={FullCircle.Accounting.tax_types()}
        />
        <.input field={@form[:rate]} label={gettext("Rate (example:- 6% = 0.06, 10% = 0.1)")} />
        <.input field={@form[:account_id]} type="hidden" />
        <.input
          field={@form[:account_name]}
          label={gettext("Account")}
          list="account_names"
          phx-debounce={500}
        />
        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All TaxCode Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={JS.push("delete", target: "#object-form")}
              cancel={JS.push("cancel_delete", target: "#object-form")}
            />
          <% end %>
          <.link phx-click={JS.push("modal_cancel")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
      <%= datalist_with_ids(@account_names, "account_names") %>
    </div>
    """
  end
end
