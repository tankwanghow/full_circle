# PDF previews shell out to pdftoppm (poppler-utils, in the prod image). Skip
# those tests where it is not installed rather than fail them.
ExUnit.start(exclude: if(System.find_executable("pdftoppm"), do: [], else: [:pdftoppm]))
Ecto.Adapters.SQL.Sandbox.mode(FullCircle.Repo, :manual)
