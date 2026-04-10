from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.models import Base


def create_database_engine(
    database_url: str,
    *,
    echo_sql_statements: bool,
) -> AsyncEngine:
    return create_async_engine(
        database_url,
        echo=echo_sql_statements,
        pool_pre_ping=True,
    )


def create_database_session_factory(
    database_engine: AsyncEngine,
) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(
        bind=database_engine,
        expire_on_commit=False,
    )


async def verify_database_connection(database_engine: AsyncEngine) -> None:
    async with database_engine.connect() as database_connection:
        await database_connection.execute(text("SELECT 1"))


async def initialize_database_schema(database_engine: AsyncEngine) -> None:
    async with database_engine.begin() as database_connection:
        await database_connection.run_sync(Base.metadata.create_all)


async def get_database_session(request: Request) -> AsyncIterator[AsyncSession]:
    database_session_factory = request.app.state.database_session_factory
    async with database_session_factory() as database_session:
        yield database_session
