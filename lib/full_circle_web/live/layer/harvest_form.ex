defmodule FullCircleWeb.LayerLive.HarvestForm do
  use FullCircleWeb, :live_view
  alias FullCircle.StdInterface
  alias FullCircle.Layer.Harvest

  @impl true
  def mount(params, _session, socket) do
    id = params["harvest_id"]

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
    |> assign(page_title: gettext("New Harvest"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Harvest, %Harvest{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    obj = FullCircle.Layer.get_harvest!(id, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Harvest"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Harvest, obj, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:harvest_details)
      |> Map.put(:action, socket.assigns.live_action)

    # |> Good.validate_has_movement()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :harvest_details)
      |> Map.put(:action, socket.assigns.live_action)

    # |> Good.validate_has_movement()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  def handle_event(
        "validate",
        %{"_target" => ["harvest", "employee_name"], "harvest" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "employee_name",
        "employee_id",
        &FullCircle.HR.get_employee_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["harvest", "harvest_details", id, "house_no"], "harvest" => params},
        socket
      ) do
    detail = params["harvest_details"][id]

    dt =
      if(params["har_date"] != "",
        do: params["har_date"] |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date(),
        else: Timex.today()
      )

    h_no = detail["house_no"] |> String.trim()

    info = FullCircle.Layer.get_house_info_at(dt, h_no, socket.assigns.current_company.id)

    info_str =
      cond do
        is_nil(info) ->
          nil

        info.qty > 0 ->
          "At #{dt} House #{info.house_no} has Flock No #{info.flock_no} with quantity #{Integer.to_string(info.qty)}."

        info.qty <= 0 ->
          "At #{dt} House #{info.house_no} is empty."
      end

    detail =
      Map.merge(detail, %{
        "house_id" => Util.attempt(info, :id),
        "flock_id" => Util.attempt(info, :flock_id),
        "flock_no" => Util.attempt(info, :flock_no),
        "house_info" => info_str,
        "company_id" => socket.assigns.current_company.id
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("harvest_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"harvest" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"harvest" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Harvest,
           "harvest",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/harvests")
         |> put_flash(:info, "#{gettext("Harvest deleted successfully.")}")}

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
           Harvest,
           "harvest",
           params
           |> Map.merge(%{"harvest_no" => FullCircle.Helpers.gen_temp_id(6) |> String.upcase()}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/harvests/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Harvest created successfully.")}")}

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
           Harvest,
           "harvest",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/harvests/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Harvest updated successfully.")}")}

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
        Harvest,
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
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:har_date]} label={gettext("DOB")} type="date" />
          </div>
          <div class="col-span-5">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
        </div>

        <div class="font-bold flex flex-row text-center mt-2">
          <div class="w-[16%]"><%= gettext("House") %></div>
          <div class="w-[16%]"><%= gettext("Flock") %></div>
          <div class="w-[13%]"><%= gettext("Harvest 1") %></div>
          <div class="w-[13%]"><%= gettext("Harvest 2") %></div>
          <div class="w-[13%]"><%= gettext("Harvest 3") %></div>
          <div class="w-[13%]"><%= gettext("Death 1") %></div>
          <div class="w-[13%]"><%= gettext("Death 2") %></div>
          <div class="w-[3%]" />
        </div>
        <.inputs_for :let={dtl} field={@form[:harvest_details]}>
          <div class={"flex flex-row  #{if(dtl[:delete].value == true and Enum.count(dtl.errors) == 0, do: "hidden", else: "")}"}>
            <div class="w-[16%]">
              <%= Phoenix.HTML.Form.hidden_input(dtl, :house_id) %>
              <%= Phoenix.HTML.Form.hidden_input(dtl, :company_id) %>
              <.input
                field={dtl[:house_no]}
                phx-hook="tributeAutoComplete"
                phx-debounce="blur"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=house&name="}
              />
            </div>
            <div class="w-[16%]">
              <%= Phoenix.HTML.Form.hidden_input(dtl, :flock_id) %>
              <.input field={dtl[:flock_no]} readonly tabindex="-1" />
            </div>
            <div class="w-[13%]">
              <.input type="number" field={dtl[:har_1]} />
            </div>
            <div class="w-[13%]">
              <.input type="number" field={dtl[:har_2]} />
            </div>
            <div class="w-[13%]">
              <.input type="number" field={dtl[:har_3]} />
            </div>
            <div class="w-[13%]">
              <.input type="number" field={dtl[:dea_1]} />
            </div>
            <div class="w-[13%]">
              <.input type="number" field={dtl[:dea_2]} />
            </div>

            <div class="w-[3%] mt-1.5 text-rose-500">
              <.link phx-click={:delete_detail} phx-value-index={dtl.index}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
            </div>
          </div>
          <span class="text-sm text-gray-500">
            <%= Phoenix.HTML.Form.input_value(dtl, :house_info) %>
          </span>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_detail} class="text-orange-500 hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Detail") %>
          </.link>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/harvests/new"}
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_harvest, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Harvest Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="harvests"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
