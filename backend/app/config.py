from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    anthropic_api_key: str = Field(alias="ANTHROPIC_API_KEY")
    assemblyai_api_key: str = Field(alias="ASSEMBLYAI_API_KEY")
    elevenlabs_api_key: str = Field(alias="ELEVENLABS_API_KEY")
    elevenlabs_voice_id: str = Field(alias="ELEVENLABS_VOICE_ID")
    clicky_allowed_origins: str = Field(default="", alias="CLICKY_ALLOWED_ORIGINS")

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
