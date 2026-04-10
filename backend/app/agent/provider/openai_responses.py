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


class OpenAIResponsesProvider(AgentProvider):
    endpoint_url = "https://api.openai.com/v1/responses"

    async def create_assistant_turn(
        self,
        *,
        http_client: AsyncClient,
        request: AgentLoopRequest,
        messages: list[AgentMessage],
        tools: list[AgentToolDefinition],
    ) -> AgentAssistantTurn:
        settings = get_settings()
        if not settings.openai_api_key:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="OPENAI_API_KEY is not configured.",
            )

        (
            original_to_provider_tool_names,
            provider_to_original_tool_names,
        ) = self.build_provider_tool_name_maps(tools)
        previous_response_id, message_index_after_previous_response = (
            self._find_previous_response_id(messages)
        )
        request_body: dict = {
            "model": request.model,
            "input": self._build_input_items(
                messages[message_index_after_previous_response:],
                original_to_provider_tool_names=original_to_provider_tool_names,
            ),
            "store": True,
            "tool_choice": request.tool_choice,
        }
        if previous_response_id:
            request_body["previous_response_id"] = previous_response_id
        if request.system_message:
            request_body["instructions"] = request.system_message
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
            request_body["max_output_tokens"] = request.max_output_tokens

        response = await http_client.post(
            self.endpoint_url,
            json=request_body,
            headers={
                "Authorization": f"Bearer {settings.openai_api_key}",
                "Content-Type": "application/json",
            },
        )
        self._raise_for_provider_error(response, provider_name="OpenAI Responses")

        return self._parse_response_payload(
            response.json(),
            provider_to_original_tool_names=provider_to_original_tool_names,
        )

    def _find_previous_response_id(
        self,
        messages: list[AgentMessage],
    ) -> tuple[str | None, int]:
        for message_index in range(len(messages) - 1, -1, -1):
            provider_response_id = messages[message_index].provider_response_id
            if provider_response_id:
                return provider_response_id, message_index + 1

        return None, 0

    def _build_input_items(
        self,
        messages: list[AgentMessage],
        *,
        original_to_provider_tool_names: dict[str, str],
    ) -> list[dict]:
        input_items: list[dict] = []

        for message in messages:
            if message.role == "tool":
                if not message.tool_call_id:
                    continue
                input_items.append(
                    {
                        "type": "function_call_output",
                        "call_id": message.tool_call_id,
                        "output": message.content,
                    },
                )
                continue

            if message.role == "user" and message.images:
                user_content: list[dict] = []
                if message.content:
                    user_content.append(
                        {
                            "type": "input_text",
                            "text": message.content,
                        },
                    )
                for agent_input_image in message.images:
                    user_content.append(
                        {
                            "type": "input_image",
                            "image_url": (
                                f"data:{agent_input_image.mime_type};base64,"
                                f"{agent_input_image.image_base64}"
                            ),
                        },
                    )

                input_items.append(
                    {
                        "role": "user",
                        "content": user_content,
                    },
                )
                continue

            if message.role == "assistant" and message.tool_calls:
                if message.content:
                    input_items.append(
                        {
                            "role": "assistant",
                            "content": message.content,
                        },
                    )

                for tool_call in message.tool_calls:
                    provider_tool_name = original_to_provider_tool_names.get(
                        tool_call.name,
                        tool_call.name,
                    )
                    input_items.append(
                        {
                            "type": "function_call",
                            "call_id": tool_call.id,
                            "name": provider_tool_name,
                            "arguments": tool_call.arguments_json,
                        },
                    )
                continue

            input_items.append(
                {
                    "role": message.role,
                    "content": message.content,
                },
            )

        return input_items

    def _build_tool_definition(
        self,
        tool: AgentToolDefinition,
        *,
        provider_tool_name: str,
    ) -> dict:
        return {
            "type": "function",
            "name": provider_tool_name,
            "description": tool.description,
            "parameters": tool.input_json_schema or {"type": "object", "properties": {}},
            "strict": tool.strict,
        }

    def _parse_response_payload(
        self,
        response_payload: dict,
        *,
        provider_to_original_tool_names: dict[str, str],
    ) -> AgentAssistantTurn:
        output_items = response_payload.get("output", [])
        assistant_text_chunks: list[str] = []
        tool_calls: list[AgentToolCall] = []

        for output_item in output_items:
            output_type = output_item.get("type")

            if output_type == "message":
                for content_item in output_item.get("content", []):
                    content_text = content_item.get("text")
                    if isinstance(content_text, str):
                        assistant_text_chunks.append(content_text)

            if output_type == "function_call":
                provider_tool_name = output_item.get("name") or ""
                tool_calls.append(
                    AgentToolCall(
                        id=output_item.get("call_id") or output_item.get("id") or "",
                        name=provider_to_original_tool_names.get(
                            provider_tool_name,
                            provider_tool_name,
                        ),
                        arguments_json=output_item.get("arguments") or "{}",
                    ),
                )

        assistant_message = AgentMessage(
            role="assistant",
            content="".join(assistant_text_chunks),
            provider_response_id=response_payload.get("id"),
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
