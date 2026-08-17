defmodule FullCircleWeb.QueryLive.Form do
  alias FullCircle.UserQueries
  use FullCircleWeb, :live_view

  alias FullCircle.UserQueries.Query
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["query_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(result: waiting_for_async_action_map())
     |> assign(ai_prompt: "", generating?: false, generate_task: nil)
     |> assign(llm_settings: load_llm_settings(socket))}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Query"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Query, %Query{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    query = StdInterface.get!(Query, id)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Query"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Query, query, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("update_ai_prompt", params, socket) do
    prompt = params["value"] || params["prompt"] || ""
    {:noreply, assign(socket, ai_prompt: prompt)}
  end

  @impl true
  def handle_event("generate_sql", _params, socket) do
    prompt = String.trim(socket.assigns.ai_prompt || "")

    cond do
      prompt == "" ->
        {:noreply, put_flash(socket, :error, gettext("Describe the query first."))}

      not llm_configured?(socket.assigns.llm_settings) ->
        {:noreply, put_flash(socket, :error, gettext("LLM is not configured for this company."))}

      true ->
        settings = socket.assigns.llm_settings
        company_id = socket.assigns.current_company.id

        task =
          Task.async(fn ->
            UserQueries.generate_sql(prompt, settings, company_id: company_id)
          end)

        {:noreply, assign(socket, ai_prompt: prompt, generating?: true, generate_task: task)}
    end
  end

  @impl true
  def handle_event("validate", %{"query" => params} = all, socket) do
    changeset =
      StdInterface.changeset(
        Query,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    {:noreply,
     socket
     |> assign(form: to_form(changeset))
     |> assign(ai_prompt: all["prompt"] || socket.assigns.ai_prompt)}
  end

  @impl true
  def handle_event("execute_query", _, socket) do
    current_company = socket.assigns.current_company
    current_user = socket.assigns.current_user
    sql_string = Ecto.Changeset.fetch_field!(socket.assigns.form.source, :sql_string)

    {:noreply,
     socket
     |> assign_async(
       :result,
       fn ->
         {:ok,
          %{
            result: UserQueries.execute(sql_string, current_company, current_user)
          }}
       end
     )}
  end

  @impl true
  def handle_event("save", %{"query" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Query,
           "query",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/queries")
         |> put_flash(:info, "#{gettext("Query deleted successfully.")}")}

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
           Query,
           "query",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/queries/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Query created successfully.")}")}

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
           Query,
           "query",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/queries/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Query updated successfully.")}")}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "This record was changed or deleted by someone else. Please reload and try again."
           )
         )}

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
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if socket.assigns.generate_task && ref == socket.assigns.generate_task.ref do
      case result do
        {:ok, sql} ->
          {:noreply,
           socket
           |> assign(generating?: false, generate_task: nil)
           |> put_sql(sql)
           |> put_flash(:info, gettext("SQL drafted. Review it, then Execute Query."))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(generating?: false, generate_task: nil)
           |> put_flash(:error, to_string(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket), do: {:noreply, socket}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(generating?: false, generate_task: nil)
     |> put_flash(:error, "SQL generation failed: #{inspect(reason)}")}
  end

  defp put_sql(socket, sql) do
    name = Ecto.Changeset.fetch_field!(socket.assigns.form.source, :qry_name) || ""

    changeset =
      StdInterface.changeset(
        Query,
        socket.assigns.form.data,
        %{"qry_name" => name, "sql_string" => sql},
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    assign(socket, form: to_form(changeset))
  end

  defp load_llm_settings(socket) do
    defaults = %{
      "llm-provider" => "none",
      "llm-endpoint" => "",
      "llm-model" => "",
      "llm-api-key" => ""
    }

    saved = FullCircle.Sys.get_company_settings(socket.assigns.current_company, "llm")
    Map.merge(defaults, saved)
  end

  defp llm_configured?(settings) do
    settings["llm-provider"] not in [nil, "", "none"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="query-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="w-full"
      >
        <div class="flex">
          <div class="w-[70%]">
            <.input field={@form[:qry_name]} label={gettext("Query Name")} />
          </div>
          <div
            :if={
              Ecto.Changeset.fetch_field!(@form.source, :sql_string) != "" and
                !is_nil(Ecto.Changeset.fetch_field!(@form.source, :sql_string))
            }
            class="w-[15%] mt-7 ml-1"
          >
            <.link class="blue button" id="exec_query" phx-click="execute_query">
              {gettext("Execute Query")}
            </.link>
          </div>
          <div :if={@form.source.changes == %{}} class="w-[15%] mt-7 ml-1">
            <.link
              class="red button"
              id="csv"
              phx-click="download_csv"
              navigate={~p"/companies/#{@current_company.id}/csv?report=queries&id=#{@form.data.id}"}
              target="_blank"
            >
              {gettext("Download CSV")}
            </.link>
          </div>
        </div>

        <div
          :if={llm_configured?(@llm_settings)}
          class="mt-2 mb-2 border border-purple-400 rounded bg-purple-50 p-2"
        >
          <label class="block text-sm font-semibold mb-1">{gettext("Ask AI to draft SQL")}</label>
          <textarea
            name="prompt"
            id="ai-query-prompt"
            rows="3"
            phx-blur="update_ai_prompt"
            class="w-full border border-gray-300 rounded px-2 py-1 text-sm"
            placeholder={gettext("e.g. debtors ageing at 31 Dec 2025, exclude related companies")}
          >{@ai_prompt}</textarea>
          <div class="flex items-center gap-2 mt-1">
            <button
              type="button"
              id="generate-sql"
              phx-click="generate_sql"
              disabled={@generating?}
              class="bg-purple-600 text-white px-3 py-1 rounded text-sm hover:bg-purple-700 disabled:opacity-50"
            >
              {if @generating?, do: gettext("Generating..."), else: gettext("Generate SQL")}
            </button>
            <span class="text-xs text-gray-600">
              {gettext("Fills the SQL box only. Review, then Execute Query.")}
            </span>
          </div>
        </div>

        <.input
          field={@form[:sql_string]}
          label={gettext("SQL")}
          type="textarea"
          rows="30"
          spellcheck="false"
          klass="font-mono leading-4 text-sm"
        />

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="queries"
          />
          <%= if @live_action == :edit and
                 FullCircle.Authorization.can?(@current_user, :delete_query, @current_company) do %>
            <.delete_confirm_modal
              id="delete-query"
              msg1={gettext("This Query, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={JS.push("delete", target: "#query-form") |> JS.hide(to: "#delete-query-modal")}
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="queries"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    <div class="w-11/12 mx-auto mt-2 mb-5">
      <table class="w-full table-auto border-collapse">
        <.async_html result={@result}>
          <:result_html>
            <% {col, row} = @result.result %>
            <thead :if={Enum.count(col) > 0}>
              <tr>
                <%= for h <- col do %>
                  <th class="text-center font-bold border rounded bg-gray-200 border-gray-500">
                    {h}
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for r <- row do %>
                <tr>
                  <%= for c <- r do %>
                    <td class="text-center border rounded bg-blue-200 border-blue-500">
                      {c}
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </:result_html>
        </.async_html>
      </table>
    </div>
    """
  end
end
