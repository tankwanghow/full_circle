defmodule FullCircleWeb.OrderLive.Form do
  use FullCircleWeb, :live_view
  import FullCircleWeb.Helpers

  alias FullCircle.Product
  alias FullCircle.Product.{Order}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["order_id"]

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
    |> assign(page_title: gettext("New Order"))
    |> assign(order_map: nil)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Order,
          %Order{},
          %{order_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      Product.get_order!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    order_map =
      Product.get_order_full_map!(
        id,
        socket.assigns.current_company
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(order_map: order_map)
    |> assign(page_title: gettext("Edit Order") <> " " <> object.order_no)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Order,
          object,
          %{},
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:order_details)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :order_details)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["order", "customer_name"], "order" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "customer_name",
        "customer_id",
        &FullCircle.Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["order", "order_details", id, "good_name"],
          "order" => params
        },
        socket
      ) do
    detail = params["order_details"][id]

    {detail, socket, good} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "good_name",
        "good_id",
        &FullCircle.Product.get_good_by_name/3
      )

    detail =
      Map.merge(detail, %{
        "package_name" => Util.attempt(good, :package_name),
        "package_id" => Util.attempt(good, :package_id),
        "unit" => Util.attempt(good, :unit),
        "unit_multiplier" => Util.attempt(good, :unit_multiplier) || 0,
        "order_pack_qty" => 0,
        "load_pack_qty" => 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("order_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["order", "order_details", id, "package_name"],
          "order" => params
        },
        socket
      ) do
    detail = params["order_details"][id]
    terms = detail["package_name"]

    pack =
      FullCircle.Product.get_packaging_by_name(
        String.trim(terms),
        detail["good_id"]
      )

    detail =
      Map.merge(detail, %{
        "package_id" => Util.attempt(pack, :id) || nil,
        "unit_multiplier" => Util.attempt(pack, :unit_multiplier) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("order_details", id, detail)

    validate(params, socket)
  end

  def handle_event("validate", %{"order" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"order" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(cancel_url: uri)}
  end

  defp save(socket, :new, params) do
    case Product.create_order(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_order: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Order/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Order created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case Product.update_order(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_order: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Order/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Order updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Order,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4 mb-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:order_no]} />
        <div class="flex flex-row flex-nowarp gap-2">
          <div class="w-1/2 grow shrink">
            <.input type="hidden" field={@form[:customer_id]} />
            <.input
              field={@form[:customer_name]}
              label={gettext("Contact")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:order_date]} label={gettext("Order Date")} type="date" />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:etd_date]} label={gettext("Deliver Date")} type="date" />
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.OrderLive.DetailComponent}
          id="order_details"
          klass=""
          doc_name="Order"
          detail_name={:order_details}
          form={@form}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row flex-nowrap gap-2">
          <div class="w-[42.5%]">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
        </div>

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Order"
          />
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Order"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Order"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="orders"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    <div :if={@order_map} class="text-center tracking-tighter">
      <div class="flex w-6/12 mx-auto border rounded-lg bg-blue-400 font-bold">
        <div class="w-[16%]">{gettext("Load Date")}</div>
        <div class="w-[18%]">{gettext("Load No")}</div>
        <div class="w-[16%]">{gettext("Lorry")}</div>
        <div class="w-[18%]">{gettext("Good")}</div>
        <div class="w-[16%]">{gettext("Load Qty")}</div>
        <div class="w-[16%]">{gettext("Load Status")}</div>
      </div>
      <%= for odd <- @order_map.order_details do %>
        <%= for ldd <- odd.load_details do %>
          <div class="flex w-6/12 mx-auto border rounded-lg bg-blue-200">
            <div class="w-[16%]">{ldd.load.load_date}</div>
            <div class="w-[18%]">
              <.doc_link
                current_company={@current_company}
                doc_obj={%{doc_type: "Load", doc_id: ldd.load.id, doc_no: ldd.load.load_no}}
              />
            </div>
            <div class="w-[16%]">{ldd.load.lorry}</div>
            <div class="w-[18%]">{odd.good.name}</div>
            <div class="w-[16%]">{ldd.load_qty |> int_or_float_format} {odd.good.unit}</div>
            <div class="w-[16%]">{ldd.status}</div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
