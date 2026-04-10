from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.parsing.router import parse_router
from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(connect=15.0, read=300.0, write=120.0, pool=120.0),
        follow_redirects=False,
    )
    try:
        yield
    finally:
        await app.state.http_client.aclose()


settings = get_settings()
allowed_origins = [
    origin.strip()
    for origin in settings.clicky_allowed_origins.split(",")
    if origin.strip()
]

app = FastAPI(
    title="Clicky Backend",
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
app.include_router(parse_router)
