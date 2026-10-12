defmodule FullCircleWeb.BankPaymentProfileLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Profile

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_bank_payment_config,
         com
       ) do
      profile =
        case params["id"] do
          nil -> %Profile{params: %{}}
          id -> BankPayment.get_profile(id, com) || raise(Ecto.NoResultsError, queryable: Profile)
        end

      {:ok,
       socket
       |> assign(
         page_title:
           if(profile.id,
             do: gettext("Edit Bank Payment Profile"),
             else: gettext("New Bank Payment Profile")
           )
       )
       |> assign(
         profile: profile,
         bank_accounts: BankPayment.bank_accounts(com),
         format_codes: BankPayment.format_codes(com.id),
         errors: []
       )
       |> assign(
         form: %{
           "account_id" => profile.account_id,
           "format_code" => profile.format_code || "",
           "our_account_no" => profile.our_account_no || "",
           "start_date" => Date.to_iso8601(profile.start_date || BankPayment.today(com)),
           "params_text" => Profile.params_text(profile.params)
         }
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket),
    do: {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params))}

  @impl true
  def handle_event("save", %{"profile" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)

    attrs =
      form
      |> Map.put("params", Profile.parse_params(form["params_text"]))
      |> Map.delete("params_text")

    com = socket.assigns.current_company

    case BankPayment.save_profile(socket.assigns.profile, attrs, com, socket.assigns.current_user) do
      {:ok, profile} ->
        socket =
          case BankPayment.profile_warnings(profile, com) do
            [] ->
              put_flash(socket, :info, gettext("Bank payment profile saved."))

            :no_format ->
              put_flash(
                socket,
                :warn,
                gettext("Saved. No file format '%{code}' is in force yet.",
                  code: profile.format_code
                )
              )

            warnings ->
              put_flash(socket, :warn, gettext("Saved, but: %{w}", w: Enum.join(warnings, "; ")))
          end

        {:noreply, push_navigate(socket, to: ~p"/companies/#{com.id}/bank_payment_profiles")}

      {:error, cs} ->
        {:noreply, assign(socket, form: form, errors: changeset_errors(cs))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={%{}} id="profile-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Bank Account (GL)")}</label>
            <select
              name="profile[account_id]"
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            >
              <option value="">{gettext("-- choose --")}</option>
              <option
                :for={{name, id} <- @bank_accounts}
                value={id}
                selected={id == @form["account_id"]}
              >
                {name}
              </option>
            </select>
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Format Code")}</label>
            <input
              type="text"
              name="profile[format_code]"
              value={@form["format_code"]}
              list="format-codes"
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
            <datalist id="format-codes"><option :for={c <- @format_codes} value={c} /></datalist>
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Our Account No")}</label>
            <input
              type="text"
              name="profile[our_account_no]"
              value={@form["our_account_no"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Start Date")}</label>
            <input
              type="date"
              name="profile[start_date]"
              value={@form["start_date"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-12">
            <label class="block text-sm font-medium">{gettext("Bank params (one key=value per line)")}</label>
            <textarea
              name="profile[params_text]"
              rows="4"
              class="w-full font-mono text-sm border rounded px-2 py-1 dark:bg-gray-800"
            >{@form["params_text"]}</textarea>
          </div>
        </div>
        <p :for={msg <- @errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>
        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"}
            class="blue button"
          >{gettext("Cancel")}</.link>
        </div>
      </.form>
    </div>
    """
  end
end
