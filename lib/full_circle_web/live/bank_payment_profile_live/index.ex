defmodule FullCircleWeb.BankPaymentProfileLive.Index do
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
       |> assign(page_title: gettext("Bank Payment Profiles"))
       |> assign(profiles: BankPayment.list_profiles(com))}
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
    <div class="w-8/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/new"}
          class="blue button"
          id="new_profile"
        >{gettext("New Profile")}</.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats"} class="blue button">{gettext(
          "Bank File Formats"
        )}</.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_batches"} class="blue button">{gettext(
          "Bank Batches"
        )}</.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Bank Account")}</div>
        <div class="col-span-3">{gettext("Format")}</div>
        <div class="col-span-3">{gettext("Our Account No")}</div>
        <div class="col-span-2">{gettext("Start Date")}</div>
      </div>
      <div :for={p <- @profiles} id={"profile-#{p.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link
            navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/#{p.id}/edit"}
            class="text-blue-600 dark:text-blue-400 hover:font-bold"
          >{p.account_name}</.link>
        </div>
        <div class="col-span-3">{p.format_code}</div>
        <div class="col-span-3">{p.our_account_no}</div>
        <div class="col-span-2">{FullCircleWeb.Helpers.format_date(p.start_date)}</div>
      </div>
    </div>
    """
  end
end
