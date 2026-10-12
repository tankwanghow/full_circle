defmodule FullCircleWeb.BankFileFormatLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_bank_payment_config,
         com
       ) do
      {:ok,
       socket
       |> assign(page_title: gettext("Bank File Formats"))
       |> assign(formats: BankPayment.list_formats(com.id))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new"}
          class="blue button"
          id="new_format"
        >{gettext("New Version")}</.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"}
          class="blue button"
        >{gettext("Bank Payment Profiles")}</.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Code")}</div>
        <div class="col-span-5">{gettext("Name")}</div>
        <div class="col-span-3">{gettext("Effective From")}</div>
      </div>
      <div :for={f <- @formats} id={"format-#{f.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link
            navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new?#{[code: f.code]}"}
            class="text-blue-600 dark:text-blue-400 hover:font-bold"
          >{f.code}</.link>
        </div>
        <div class="col-span-5">{f.name}</div>
        <div class="col-span-3">{FullCircleWeb.Helpers.format_date(f.effective_from)}</div>
      </div>
    </div>
    """
  end
end
