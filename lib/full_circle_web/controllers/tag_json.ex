defmodule FullCircleWeb.TagJSON do

  def index(%{tags: tags}) do
    Enum.map(tags, fn x -> %{value: x} end)
  end

end
