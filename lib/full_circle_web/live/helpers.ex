defmodule FullCircleWeb.Helpers do
  use Phoenix.Component

  defp get_change_or_field(changeset, field) do
    with nil <- Ecto.Changeset.get_change(changeset, field) do
      Ecto.Changeset.get_field(changeset, field, [])
    end
  end

  def delete_lines(socket, index, lines_name) do
    update(socket, :form, fn %{source: changeset} ->
      existing = get_change_or_field(changeset, lines_name)
      {to_delete, rest} = List.pop_at(existing, index)

      lines =
        if Ecto.Changeset.change(to_delete).data.id do
          List.replace_at(existing, index, Ecto.Changeset.change(to_delete, delete: true))
        else
          rest
        end

      changeset
      |> Ecto.Changeset.put_assoc(lines_name, lines)
      |> to_form()
    end)
  end

  def add_lines(socket, lines_name, line_class_struct) do
    update(socket, :form, fn %{source: changeset} ->
      existing = get_change_or_field(changeset, lines_name)

      changeset = Ecto.Changeset.put_assoc(changeset, lines_name, existing ++ [line_class_struct])

      to_form(changeset)
    end)
  end
end
