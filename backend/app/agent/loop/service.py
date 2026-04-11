import asyncio
import json
import logging
from uuid import uuid4

from fastapi import HTTPException, Request, status

from app.agent.contracts import (
    AgentLoopRequest,
    AgentLoopResponse,
    AgentMessage,
    AgentToolCall,
    AgentToolDefinition,
    AgentToolResult,
)
from app.agent.defaults import DEFAULT_AGENT_SYSTEM_PROMPT
from app.agent.loop.abort_registry import AgentAbortRegistry
from app.agent.loop.tool_handler import ToolExecutionContext, execute_tool_call
from app.agent.provider import (
    OpenAIResponsesProvider,
    OpenRouterChatCompletionsProvider,
)
from app.config import get_settings
from app.models import User
from sqlalchemy.ext.asyncio import AsyncSession

agent_loop_logger = logging.getLogger("clicky.agent.loop")


class AgentLoopAbortError(asyncio.CancelledError):
    pass


def _is_client_side_companion_tool(tool_name: str) -> bool:
    return tool_name.startswith("companion.")


def resolve_agent_model_name(agent_loop_request: AgentLoopRequest) -> str:
    if agent_loop_request.model:
        return agent_loop_request.model

    if agent_loop_request.provider == "openai_responses":
        return "gpt-5.4-mini"

    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail=f"`model` is required for provider `{agent_loop_request.provider}`.",
    )


def build_agent_provider_registry() -> dict:
    return {
        "openai_responses": OpenAIResponsesProvider(),
        "openrouter_chat_completions": OpenRouterChatCompletionsProvider(),
    }


def _truncate_for_log(raw_text: str | None, max_characters: int) -> str:
    if not raw_text:
        return ""
    if len(raw_text) <= max_characters:
        return raw_text
    return raw_text[:max_characters].rstrip() + "...[truncated]"


def _build_logged_message_payload(
    agent_message: AgentMessage,
    max_characters: int,
) -> dict:
    return {
        "role": agent_message.role,
        "name": agent_message.name,
        "tool_call_id": agent_message.tool_call_id,
        "provider_response_id": agent_message.provider_response_id,
        "content_character_count": len(agent_message.content or ""),
        "content_preview": _truncate_for_log(agent_message.content, max_characters),
        "image_inputs": [
            {
                "label": input_image.label,
                "mime_type": input_image.mime_type,
                "pixel_width": input_image.pixel_width,
                "pixel_height": input_image.pixel_height,
                "is_primary_focus": input_image.is_primary_focus,
                "image_base64_character_count": len(input_image.image_base64 or ""),
            }
            for input_image in agent_message.images
        ],
        "tool_calls": [
            {
                "id": tool_call.id,
                "name": tool_call.name,
                "arguments_character_count": len(tool_call.arguments_json or ""),
                "arguments_preview": _truncate_for_log(
                    tool_call.arguments_json,
                    max_characters,
                ),
            }
            for tool_call in agent_message.tool_calls
        ],
    }


def _build_logged_tool_result_payload(
    agent_tool_result: AgentToolResult,
    max_characters: int,
) -> dict:
    return {
        "tool_call_id": agent_tool_result.tool_call_id,
        "tool_name": agent_tool_result.tool_name,
        "is_error": agent_tool_result.is_error,
        "output_character_count": len(agent_tool_result.output_text or ""),
        "output_preview": _truncate_for_log(
            agent_tool_result.output_text,
            max_characters,
        ),
    }


def _emit_agent_event_log(
    *,
    event_name: str,
    run_id: str,
    event_payload: dict,
) -> None:
    payload_for_logging = {
        "event": event_name,
        "run_id": run_id,
        **event_payload,
    }
    agent_loop_logger.info("agent_event %s", json.dumps(payload_for_logging, ensure_ascii=False))


async def run_agent_loop(
    *,
    fastapi_request: Request,
    agent_loop_request: AgentLoopRequest,
    current_user: User,
    database_session: AsyncSession,
) -> AgentLoopResponse:
    run_id = agent_loop_request.run_id or str(uuid4())
    settings = get_settings()
    should_log_agent_events = settings.deb_agent_event_logging_enabled
    max_logged_characters = max(200, settings.deb_agent_event_log_max_chars)
    abort_registry: AgentAbortRegistry = fastapi_request.app.state.agent_abort_registry
    http_client = fastapi_request.app.state.http_client

    registered_run = await abort_registry.register_run(run_id)
    await abort_registry.attach_task(run_id, asyncio.current_task())
    resolved_model_name = resolve_agent_model_name(agent_loop_request)
    resolved_agent_loop_request = agent_loop_request.model_copy(
        update={
            "run_id": run_id,
            "model": resolved_model_name,
            "system_message": agent_loop_request.system_message or DEFAULT_AGENT_SYSTEM_PROMPT,
        }
    )

    messages = list(agent_loop_request.messages)
    all_tool_calls: list[AgentToolCall] = []
    all_tool_results: list[AgentToolResult] = []
    declared_tools_by_name = {
        tool_definition.name: tool_definition
        for tool_definition in agent_loop_request.tools
    }
    provider_registry = build_agent_provider_registry()
    provider = provider_registry.get(agent_loop_request.provider)

    if provider is None:
        await abort_registry.unregister_run(run_id)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported provider `{agent_loop_request.provider}`.",
        )

    try:
        if should_log_agent_events:
            _emit_agent_event_log(
                event_name="run_started",
                run_id=run_id,
                event_payload={
                    "provider": agent_loop_request.provider,
                    "model": resolved_model_name,
                    "tool_choice": agent_loop_request.tool_choice,
                    "temperature": agent_loop_request.temperature,
                    "max_output_tokens": agent_loop_request.max_output_tokens,
                    "max_iterations": agent_loop_request.max_iterations,
                    "system_message_preview": _truncate_for_log(
                        resolved_agent_loop_request.system_message,
                        max_logged_characters,
                    ),
                    "declared_tools": [tool_definition.name for tool_definition in agent_loop_request.tools],
                    "input_messages": [
                        _build_logged_message_payload(
                            agent_message=message,
                            max_characters=max_logged_characters,
                        )
                        for message in messages
                    ],
                },
            )

        for iteration_index in range(agent_loop_request.max_iterations):
            await _raise_if_run_should_abort(run_id, abort_registry)
            current_iteration_number = iteration_index + 1

            if should_log_agent_events:
                _emit_agent_event_log(
                    event_name="iteration_started",
                    run_id=run_id,
                    event_payload={
                        "iteration": current_iteration_number,
                        "message_count": len(messages),
                    },
                )

            assistant_turn = await provider.create_assistant_turn(
                http_client=http_client,
                request=resolved_agent_loop_request,
                messages=messages,
                tools=agent_loop_request.tools,
            )
            messages.append(
                assistant_turn.assistant_message.model_copy(
                    update={"tool_calls": assistant_turn.tool_calls}
                )
            )
            all_tool_calls.extend(assistant_turn.tool_calls)

            if should_log_agent_events:
                _emit_agent_event_log(
                    event_name="assistant_turn_received",
                    run_id=run_id,
                    event_payload={
                        "iteration": current_iteration_number,
                        "assistant_message": _build_logged_message_payload(
                            agent_message=assistant_turn.assistant_message.model_copy(
                                update={"tool_calls": assistant_turn.tool_calls}
                            ),
                            max_characters=max_logged_characters,
                        ),
                    },
                )

            if not assistant_turn.tool_calls:
                completed_response = AgentLoopResponse(
                    run_id=run_id,
                    status="completed",
                    provider=agent_loop_request.provider,
                    model=resolved_model_name,
                    iterations_completed=iteration_index + 1,
                    final_output_text=assistant_turn.assistant_message.content,
                    messages=messages,
                    tool_calls=all_tool_calls,
                    tool_results=all_tool_results,
                )
                if should_log_agent_events:
                    _emit_agent_event_log(
                        event_name="run_completed",
                        run_id=run_id,
                        event_payload={
                            "status": completed_response.status,
                            "iterations_completed": completed_response.iterations_completed,
                            "final_output_preview": _truncate_for_log(
                                completed_response.final_output_text,
                                max_logged_characters,
                            ),
                        },
                    )
                return completed_response

            companion_tool_calls = [
                tool_call
                for tool_call in assistant_turn.tool_calls
                if _is_client_side_companion_tool(tool_call.name)
            ]
            backend_tool_calls = [
                tool_call
                for tool_call in assistant_turn.tool_calls
                if not _is_client_side_companion_tool(tool_call.name)
            ]

            tool_execution_context = ToolExecutionContext(
                current_user=current_user,
                database_session=database_session,
                declared_tools_by_name=declared_tools_by_name,
            )
            for tool_call in backend_tool_calls:
                await _raise_if_run_should_abort(run_id, abort_registry)

                if should_log_agent_events:
                    _emit_agent_event_log(
                        event_name="backend_tool_call_started",
                        run_id=run_id,
                        event_payload={
                            "iteration": current_iteration_number,
                            "tool_call_id": tool_call.id,
                            "tool_name": tool_call.name,
                            "arguments_character_count": len(tool_call.arguments_json or ""),
                            "arguments_preview": _truncate_for_log(
                                tool_call.arguments_json,
                                max_logged_characters,
                            ),
                        },
                    )

                tool_result = await execute_tool_call(
                    tool_call=tool_call,
                    tool_execution_context=tool_execution_context,
                )
                all_tool_results.append(tool_result)
                messages.append(
                    AgentMessage(
                        role="tool",
                        tool_call_id=tool_result.tool_call_id,
                        name=tool_result.tool_name,
                        content=tool_result.output_text,
                    ),
                )
                if should_log_agent_events:
                    _emit_agent_event_log(
                        event_name="backend_tool_call_finished",
                        run_id=run_id,
                        event_payload={
                            "iteration": current_iteration_number,
                            "tool_result": _build_logged_tool_result_payload(
                                agent_tool_result=tool_result,
                                max_characters=max_logged_characters,
                            ),
                        },
                    )

            if companion_tool_calls:
                awaiting_client_tools_response = AgentLoopResponse(
                    run_id=run_id,
                    status="awaiting_client_tools",
                    provider=agent_loop_request.provider,
                    model=resolved_model_name,
                    iterations_completed=iteration_index + 1,
                    final_output_text=assistant_turn.assistant_message.content,
                    messages=messages,
                    tool_calls=all_tool_calls,
                    tool_results=all_tool_results,
                )
                if should_log_agent_events:
                    _emit_agent_event_log(
                        event_name="awaiting_client_tools",
                        run_id=run_id,
                        event_payload={
                            "iteration": current_iteration_number,
                            "pending_companion_tools": [
                                {
                                    "id": tool_call.id,
                                    "name": tool_call.name,
                                    "arguments_preview": _truncate_for_log(
                                        tool_call.arguments_json,
                                        max_logged_characters,
                                    ),
                                }
                                for tool_call in companion_tool_calls
                            ],
                        },
                    )
                return awaiting_client_tools_response

        final_output_text = messages[-1].content if messages else ""
        max_iterations_response = AgentLoopResponse(
            run_id=run_id,
            status="max_iterations_exceeded",
            provider=agent_loop_request.provider,
            model=resolved_model_name,
            iterations_completed=agent_loop_request.max_iterations,
            final_output_text=final_output_text,
            messages=messages,
            tool_calls=all_tool_calls,
            tool_results=all_tool_results,
        )
        if should_log_agent_events:
            _emit_agent_event_log(
                event_name="run_completed",
                run_id=run_id,
                event_payload={
                    "status": max_iterations_response.status,
                    "iterations_completed": max_iterations_response.iterations_completed,
                    "final_output_preview": _truncate_for_log(
                        max_iterations_response.final_output_text,
                        max_logged_characters,
                    ),
                },
            )
        return max_iterations_response
    except asyncio.CancelledError as error:
        if await abort_registry.is_abort_requested(run_id):
            aborted_response = AgentLoopResponse(
                run_id=run_id,
                status="aborted",
                provider=agent_loop_request.provider,
                model=resolved_model_name,
                iterations_completed=0,
                final_output_text="",
                messages=messages,
                tool_calls=all_tool_calls,
                tool_results=all_tool_results,
            )
            if should_log_agent_events:
                _emit_agent_event_log(
                    event_name="run_aborted",
                    run_id=run_id,
                    event_payload={
                        "status": aborted_response.status,
                    },
                )
            return aborted_response
        if should_log_agent_events:
            _emit_agent_event_log(
                event_name="run_cancelled",
                run_id=run_id,
                event_payload={"reason": "task_cancelled_without_abort_flag"},
            )
        raise error
    except Exception as error:
        if should_log_agent_events:
            _emit_agent_event_log(
                event_name="run_failed",
                run_id=run_id,
                event_payload={
                    "error_type": type(error).__name__,
                    "error_message": str(error),
                },
            )
        raise
    finally:
        await abort_registry.unregister_run(run_id)


async def _raise_if_run_should_abort(
    run_id: str,
    abort_registry: AgentAbortRegistry,
) -> None:
    if await abort_registry.is_abort_requested(run_id):
        raise AgentLoopAbortError()
