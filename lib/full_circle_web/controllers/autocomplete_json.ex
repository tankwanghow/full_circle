defmodule FullCircleWeb.AutoCompleteJSON do
  def index(%{values: values}) do
    Enum.map(values, fn %{id: _id, value: name} -> %{value: name} end)
  end
end
