from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.agent.loop.abort_registry import AgentAbortRegistry
from app.agent.router import agent_router
from app.auth_router import auth_router
from app.config import get_settings
from app.database import (
    create_database_engine,
    create_database_session_factory,
    initialize_database_schema,
    verify_database_connection,
)
from app.parsing.router import parse_router
from app.routes import router
from app.workspaces_router import workspaces_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.agent_abort_registry = AgentAbortRegistry()
    app.state.http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(connect=15.0, read=300.0, write=120.0, pool=120.0),
        follow_redirects=False,
    )
    app.state.database_engine = create_database_engine(
        settings.database_url,
        echo_sql_statements=settings.deb_database_echo,
    )
    app.state.database_session_factory = create_database_session_factory(
        app.state.database_engine,
    )
    await verify_database_connection(app.state.database_engine)
    if settings.deb_auto_create_database_schema:
        await initialize_database_schema(app.state.database_engine)
    try:
        yield
    finally:
        await app.state.http_client.aclose()
        await app.state.database_engine.dispose()


settings = get_settings()
allowed_origins = [
    origin.strip()
    for origin in settings.deb_allowed_origins.split(",")
    if origin.strip()
]

app = FastAPI(
    title="Deb Backend",
    version="0.1.0",
    lifespan=lifespan,
)

if allowed_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

app.include_router(router)
app.include_router(auth_router)
app.include_router(workspaces_router)
app.include_router(agent_router)
app.include_router(parse_router)
