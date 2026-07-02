defmodule FullCircleWeb.StatutoryCalcLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  defp first_script_line(script) do
    script
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
    |> List.first()
    |> Kernel.||("")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} text-center bg-gray-200 dark:bg-gray-700 border-gray-500 hover:bg-gray-300 dark:hover:bg-gray-600 border-b py-1"}
    >
      <.link
        class="hover:font-bold text-blue-600 dark:text-blue-300"
        navigate={
          ~p"/companies/#{@current_company.id}/statutory_calcs/new?#{%{"code" => @obj.code}}"
        }
      >
        {@obj.code}
      </.link>
      &#8226; {@obj.name}
      &#8226; {@obj.effective_from}
      &#8226; <span class="font-mono text-sm">{first_script_line(@obj.script)}</span>
    </div>
    """
  end
end