from fastapi import HTTPException, status
from httpx import AsyncClient, Response

from app.agent.contracts import (
    AgentAssistantTurn,
    AgentLoopRequest,
    AgentMessage,
    AgentToolCall,
    AgentToolDefinition,
)
from app.agent.provider.base import AgentProvider
from app.config import get_settings


class OpenRouterChatCompletionsProvider(AgentProvider):
    endpoint_url = "https://openrouter.ai/api/v1/chat/completions"

    async def create_assistant_turn(
        self,
        *,
        http_client: AsyncClient,
        request: AgentLoopRequest,
        messages: list[AgentMessage],
        tools: list[AgentToolDefinition],
    ) -> AgentAssistantTurn:
        settings = get_settings()
        if not settings.openrouter_api_key:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="OPENROUTER_API_KEY is not configured.",
            )

        (
            original_to_provider_tool_names,
            provider_to_original_tool_names,
        ) = self.build_provider_tool_name_maps(tools)
        request_body: dict = {
            "model": request.model,
            "messages": self._build_chat_messages(
                system_message=request.system_message,
                messages=messages,
                original_to_provider_tool_names=original_to_provider_tool_names,
            ),
            "tool_choice": request.tool_choice,
        }
        if tools:
            request_body["tools"] = [
                self._build_tool_definition(
                    tool,
                    provider_tool_name=original_to_provider_tool_names[tool.name],
                )
                for tool in tools
            ]
        if request.temperature is not None:
            request_body["temperature"] = request.temperature
        if request.max_output_tokens is not None:
            request_body["max_tokens"] = request.max_output_tokens

        response = await http_client.post(
            self.endpoint_url,
            json=request_body,
            headers={
                "Authorization": f"Bearer {settings.openrouter_api_key}",
                "Content-Type": "application/json",
            },
        )
        self._raise_for_provider_error(response, provider_name="OpenRouter")

        return self._parse_response_payload(
            response.json(),
            provider_to_original_tool_names=provider_to_original_tool_names,
        )

    def _build_chat_messages(
        self,
        *,
        system_message: str | None,
        messages: list[AgentMessage],
        original_to_provider_tool_names: dict[str, str],
    ) -> list[dict]:
        chat_messages: list[dict] = []

        if system_message:
            chat_messages.append({"role": "system", "content": system_message})

        for message in messages:
            if message.role == "tool":
                chat_messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": message.tool_call_id,
                        "content": message.content,
                    },
                )
                continue

            if message.role == "assistant" and message.tool_calls:
                chat_messages.append(
                    {
                        "role": "assistant",
                        "content": message.content or None,
                        "tool_calls": [
                            {
                                "id": tool_call.id,
                                "type": "function",
                                "function": {
                                    "name": original_to_provider_tool_names.get(
                                        tool_call.name,
                                        tool_call.name,
                                    ),
                                    "arguments": tool_call.arguments_json,
                                },
                            }
                            for tool_call in message.tool_calls
                        ],
                    },
                )
                continue

            if message.role == "user" and message.images:
                user_content_parts: list[dict] = []
                if message.content:
                    user_content_parts.append(
                        {
                            "type": "text",
                            "text": message.content,
                        },
                    )
                for agent_input_image in message.images:
                    user_content_parts.append(
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": (
                                    f"data:{agent_input_image.mime_type};base64,"
                                    f"{agent_input_image.image_base64}"
                                ),
                            },
                        },
                    )

                chat_messages.append(
                    {
                        "role": "user",
                        "content": user_content_parts,
                    },
                )
                continue

            chat_messages.append(
                {
                    "role": message.role,
                    "content": message.content,
                },
            )

        return chat_messages

    def _build_tool_definition(
        self,
        tool: AgentToolDefinition,
        *,
        provider_tool_name: str,
    ) -> dict:
        return {
            "type": "function",
            "function": {
                "name": provider_tool_name,
                "description": tool.description,
                "parameters": tool.input_json_schema
                or {"type": "object", "properties": {}},
                "strict": tool.strict,
            },
        }

    def _parse_response_payload(
        self,
        response_payload: dict,
        *,
        provider_to_original_tool_names: dict[str, str],
    ) -> AgentAssistantTurn:
        choices = response_payload.get("choices", [])
        if not choices:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail="OpenRouter returned no choices.",
            )

        first_message = choices[0].get("message", {})
        tool_calls: list[AgentToolCall] = []
        for tool_call in first_message.get("tool_calls", []):
            function_payload = tool_call.get("function", {})
            provider_tool_name = function_payload.get("name") or ""
            tool_calls.append(
                AgentToolCall(
                    id=tool_call.get("id") or "",
                    name=provider_to_original_tool_names.get(
                        provider_tool_name,
                        provider_tool_name,
                    ),
                    arguments_json=function_payload.get("arguments") or "{}",
                ),
            )

        assistant_message = AgentMessage(
            role="assistant",
            content=first_message.get("content") or "",
        )
        return AgentAssistantTurn(
            assistant_message=assistant_message,
            tool_calls=tool_calls,
        )

    def _raise_for_provider_error(
        self,
        response: Response,
        *,
        provider_name: str,
    ) -> None:
        if 200 <= response.status_code < 300:
            return

        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=(
                f"{provider_name} request failed with status "
                f"{response.status_code}: {response.text}"
            ),
        )
