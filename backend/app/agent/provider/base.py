from abc import ABC, abstractmethod
import re

from httpx import AsyncClient

from app.agent.contracts import (
    AgentAssistantTurn,
    AgentLoopRequest,
    AgentMessage,
    AgentToolDefinition,
)


class AgentProvider(ABC):
    @staticmethod
    def build_provider_tool_name_maps(
        tools: list[AgentToolDefinition],
    ) -> tuple[dict[str, str], dict[str, str]]:
        original_to_provider_tool_names: dict[str, str] = {}
        provider_to_original_tool_names: dict[str, str] = {}

        for tool in tools:
            sanitized_tool_name = re.sub(r"[^a-zA-Z0-9_-]", "_", tool.name).strip("_")
            provider_tool_name = sanitized_tool_name or "tool"
            duplicate_index = 1
            while provider_tool_name in provider_to_original_tool_names:
                duplicate_index += 1
                provider_tool_name = f"{sanitized_tool_name or 'tool'}_{duplicate_index}"

            original_to_provider_tool_names[tool.name] = provider_tool_name
            provider_to_original_tool_names[provider_tool_name] = tool.name

        return original_to_provider_tool_names, provider_to_original_tool_names

    @abstractmethod
    async def create_assistant_turn(
        self,
        *,
        http_client: AsyncClient,
        request: AgentLoopRequest,
        messages: list[AgentMessage],
        tools: list[AgentToolDefinition],
    ) -> AgentAssistantTurn:
        raise NotImplementedError
