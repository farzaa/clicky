"""Chat backend abstraction — lets the companion run Claude (via Worker
proxy) or OpenAI GPT vision (direct) interchangeably.

Mirrors how the Swift app produces ClaudeAPI/OpenAIAPI lazily inside
CompanionManager, but as an explicit factory so the panel can switch
.backends at runtime without rebuilding the manager.
"""

from __future__ import annotations

from typing import Callable, Optional, Protocol

from .config import CompanionSettings


class CompanionChatClient(Protocol):
    """Common surface both backends satisfy (ClaudeAPI already does;
    OpenAIAPI.analyze_image adapts to it)."""

    model: str

    def analyze_image_streaming(
        self,
        images: list,
        system_prompt: str,
        conversation_history: list[tuple[str, str]],
        user_prompt: str,
        on_text_chunk: Optional[Callable[[str], None]],
        http_client=None,
        is_cancelled_fn: Optional[Callable[[], bool]] = None,
    ) -> tuple[str, float]: ...


# Backend identifiers stored in settings/UI_lowercase
BACKEND_CLAUDE = "claude"
BACKEND_OPENAI = "openai"


def resolve_chat_client(settings: CompanionSettings) -> CompanionChatClient:
    """Builds the chat client for settings.selected_chat_backend. Falls back
    to Claude when the requested backend is unavailable (missing key), so a
    misconfigured preference never dead-ends the companion."""
    backend = (getattr(settings, "selected_chat_backend", None) or BACKEND_CLAUDE).lower()

    if backend == BACKEND_OPENAI:
        from .openai_api import OpenAIAPI

        try:
            return OpenAIAPI.from_environment(model=settings.selected_model)
        except RuntimeError as missing_key_error:
            print(f"⚠️ {missing_key_error} Falling back to Claude.")
            # fall through to Claude

    from .claude_api import ClaudeAPI

    return ClaudeAPI(
        proxy_url=f"{settings.proxy_base_url.rstrip('/')}/chat",
        model=settings.selected_model,
    )


def available_models_for_backend(settings: CompanionSettings, backend: str) -> tuple[str, ...]:
    """Per-backend model lists — Claude keeps its two model names, OpenAI
    exposes the gpt-5.2 dated snapshot like the Swift default."""
    normalized = (backend or BACKEND_CLAUDE).lower()
    if normalized == BACKEND_OPENAI:
        return ("gpt-5.2-2025-12-11", "gpt-5.2-mini-2025-12-11")
    return settings.available_models_claude


def default_model_for_backend(settings: CompanionSettings, backend: str) -> str:
    return available_models_for_backend(settings, backend)[0]
