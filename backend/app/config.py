from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    anthropic_api_key: str | None = Field(default=None, alias="ANTHROPIC_API_KEY")
    elevenlabs_api_key: str = Field(alias="ELEVENLABS_API_KEY")
    elevenlabs_voice_id: str = Field(alias="ELEVENLABS_VOICE_ID")
    openai_api_key: str | None = Field(default=None, alias="OPENAI_API_KEY")
    openrouter_api_key: str | None = Field(default=None, alias="OPENROUTER_API_KEY")
    database_url: str = Field(alias="DATABASE_URL")
    clicky_allowed_origins: str = Field(default="", alias="CLICKY_ALLOWED_ORIGINS")
    clicky_auto_create_database_schema: bool = Field(
        default=True,
        alias="CLICKY_AUTO_CREATE_DATABASE_SCHEMA",
    )
    clicky_database_echo: bool = Field(default=False, alias="CLICKY_DATABASE_ECHO")

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
