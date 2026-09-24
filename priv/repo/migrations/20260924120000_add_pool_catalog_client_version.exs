defmodule CodexPooler.Repo.Migrations.AddPoolCatalogClientVersion do
  use Ecto.Migration

  def change do
    alter table(:pools) do
      add :catalog_client_version, :string
    end
  end
end
