"""Відкриває SQLite сховище й застосовує розширювальні оновлення схеми.

Нова колонка · підняти `SCHEMA_VERSION` і дописати `ALTER TABLE … ADD COLUMN …`
в `UPGRADES`.
"""

from typing import Any

from sqlalchemy import Engine, create_engine, event
from sqlmodel import SQLModel

from bdo_translate.settings import Settings
from bdo_translate.store.models import ModelCapability, RoleThink  # noqa: F401

SCHEMA_VERSION = 3
UPGRADES: dict[int, tuple[str, ...]] = {
    2: ("ALTER TABLE model_capabilities ADD COLUMN efforts TEXT",),
    3: ("ALTER TABLE run_checkpoints ADD COLUMN ctx_json TEXT",),
}


def open_db(settings: Settings) -> Engine:
    """Створює SQLite engine, таблиці й піднімає версію схеми."""
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    engine = create_engine(
        f"sqlite:///{settings.db_path}",
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(engine, "connect")
    def _configure_sqlite(dbapi_connection: Any, connection_record: Any) -> None:
        cursor = dbapi_connection.cursor()
        try:
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.execute("PRAGMA busy_timeout=5000")
        finally:
            cursor.close()

    with engine.begin() as connection:
        current_version = int(connection.exec_driver_sql("PRAGMA user_version").scalar_one())
        if current_version > SCHEMA_VERSION:
            raise RuntimeError(
                f"Версія SQLite схеми {current_version} новіша за підтримувану {SCHEMA_VERSION}"
            )
        for version in range(current_version + 1, SCHEMA_VERSION + 1):
            for statement in UPGRADES.get(version, ()):
                if statement == "ALTER TABLE model_capabilities ADD COLUMN efforts TEXT":
                    columns = connection.exec_driver_sql(
                        "PRAGMA table_info(model_capabilities)"
                    ).all()
                    if not columns or any(column[1] == "efforts" for column in columns):
                        continue
                if statement == "ALTER TABLE run_checkpoints ADD COLUMN ctx_json TEXT":
                    columns = connection.exec_driver_sql("PRAGMA table_info(run_checkpoints)").all()
                    if not columns or any(column[1] == "ctx_json" for column in columns):
                        continue
                connection.exec_driver_sql(statement)

    SQLModel.metadata.create_all(engine)
    with engine.begin() as connection:
        connection.exec_driver_sql(f"PRAGMA user_version = {SCHEMA_VERSION}")
    return engine
