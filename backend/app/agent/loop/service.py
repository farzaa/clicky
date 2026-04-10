import asyncio
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
from app.models import User
from sqlalchemy.ext.asyncio import AsyncSession


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


async def run_agent_loop(
    *,
    fastapi_request: Request,
    agent_loop_request: AgentLoopRequest,
    current_user: User,
    database_session: AsyncSession,
) -> AgentLoopResponse:
    run_id = agent_loop_request.run_id or str(uuid4())
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
        for iteration_index in range(agent_loop_request.max_iterations):
            await _raise_if_run_should_abort(run_id, abort_registry)

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

            if not assistant_turn.tool_calls:
                return AgentLoopResponse(
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

            if companion_tool_calls:
                return AgentLoopResponse(
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

        final_output_text = messages[-1].content if messages else ""
        return AgentLoopResponse(
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
    except asyncio.CancelledError as error:
        if await abort_registry.is_abort_requested(run_id):
            return AgentLoopResponse(
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
        raise error
    finally:
        await abort_registry.unregister_run(run_id)


async def _raise_if_run_should_abort(
    run_id: str,
    abort_registry: AgentAbortRegistry,
) -> None:
    if await abort_registry.is_abort_requested(run_id):
        raise AgentLoopAbortError()
