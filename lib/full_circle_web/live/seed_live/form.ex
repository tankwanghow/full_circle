defmodule FullCircleWeb.SeedLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.Transaction
  alias FullCircle.{StdInterface, Seeding}

  @impl true
  def mount(params, _session, socket) do
    dtype = params["doc_type"]
    don = params["doc_no"]

    seeds =
      Seeding.get_transactions(dtype, don, socket.assigns.current_company.id)
      |> Enum.map(fn x ->
        StdInterface.changeset(
          Transaction,
          x,
          %{},
          socket.assigns.current_company,
          :seed_changeset
        )
      end)

    {:ok,
     socket
     |> assign(live_action: :edit)
     |> assign(page_title: gettext("Edit Seed") <> " #{dtype} #{don}")
     |> assign(seeds: seeds |> Enum.map(fn x -> to_form(x) end))}
  end

  @impl true
  def handle_event("save", %{"_target" => ["transaction", _], "transaction" => params}, socket) do
    obj = StdInterface.get!(Transaction, params["id"])

    case StdInterface.update(
           Transaction,
           "seed",
           obj,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(
           to:
             ~p"/companies/#{socket.assigns.current_company.id}/seeds/#{obj.doc_type}/#{obj.doc_no}/edit"
         )
         |> put_flash(:info, "#{gettext("Seed updated successfully.")}")}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
        <div class="detail-header w-[10%]">{gettext("Date")}</div>
        <div class="detail-header w-[20%]">{gettext("Account")}</div>
        <div class="detail-header w-[20%]">{gettext("Contact")}</div>
        <div class="detail-header w-[30%]">{gettext("Particulars")}</div>
        <div class="detail-header w-[20%]">{gettext("Amount")}</div>
      </div>
      <%= for dtl <- @seeds do %>
        <.form for={dtl} id={"object-form-#{dtl.source.data.id}"} autocomplete="off" phx-change="save">
          <div class="flex flex-row flex-wrap">
            <.input type="hidden" field={dtl[:id]} />
            <.input type="hidden" field={dtl[:account_id]} />
            <.input type="hidden" field={dtl[:contact_id]} />
            <.input type="hidden" field={dtl[:doc_type]} />
            <.input type="hidden" field={dtl[:doc_no]} />
            <div class="w-[10%]"><.input type="date" field={dtl[:doc_date]} /></div>
            <div class="w-[20%]"><.input readonly={true} field={dtl[:account_name]} /></div>
            <div class="w-[20%]"><.input field={dtl[:contact_name]} readonly={true} /></div>
            <div class="w-[30%]"><.input field={dtl[:particulars]} /></div>
            <div class="w-[20%]">
              <.input type="number" step="0.01" field={dtl[:amount]} />
            </div>
          </div>
        </.form>
      <% end %>
      <div class="flex justify-center gap-x-1 mt-1">
        <a onclick="history.back();" class="blue button">{gettext("Done")}</a>
      </div>
    </div>
    """
  end
end
