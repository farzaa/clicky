from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.contracts import (
    AbortAgentRunResponse,
    AgentLoopRequest,
    AgentLoopResponse,
    AgentToolDefinition,
)
from app.agent.bash_tool import build_workspace_bash_tool_definition
from app.agent.loop.abort_registry import AgentAbortRegistry
from app.agent.loop.service import run_agent_loop
from app.auth import get_current_user
from app.database import get_database_session
from app.models import User

agent_router = APIRouter(prefix="/agent", tags=["agent"])


def build_workspace_toc_search_tool_definition() -> AgentToolDefinition:
    return AgentToolDefinition(
        name="workspace.search_toc",
        description=(
            "Search TOC entries from ingested workspace document bundles. "
            "Use this when the user asks for a topic, chapter, lecture, or other "
            "document section and the workspace contains `__ingested/toc.json` artifacts. "
            "This tool only searches headings/TOC labels and does not verify page body text."
        ),
        input_json_schema={
            "type": "object",
            "properties": {
                "workspace_id": {"type": "string"},
                "query": {"type": "string"},
                "max_results": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 20,
                },
            },
            "required": ["workspace_id", "query"],
            "additionalProperties": False,
        },
    )


@agent_router.get("/tools", response_model=list[AgentToolDefinition])
async def list_backend_agent_tools(
    current_user: User = Depends(get_current_user),
) -> list[AgentToolDefinition]:
    _ = current_user
    return [
        AgentToolDefinition(
            name="companion.point",
            description=(
                "Record a cursor pointing target on a specific screen image using pixel "
                "coordinates."
            ),
            input_json_schema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "minimum": 0},
                    "y": {"type": "integer", "minimum": 0},
                    "label": {"type": "string"},
                    "screen_number": {"type": "integer", "minimum": 1},
                    "pixel_width": {"type": "integer", "minimum": 1},
                    "pixel_height": {"type": "integer", "minimum": 1},
                },
                "required": [
                    "x",
                    "y",
                    "label",
                    "screen_number",
                    "pixel_width",
                    "pixel_height",
                ],
                "additionalProperties": False,
            },
        ),
        AgentToolDefinition(
            name="companion.speak",
            description="Speak a short response out loud on the client.",
            input_json_schema={
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                },
                "required": ["text"],
                "additionalProperties": False,
            },
        ),
        build_workspace_bash_tool_definition(),
        build_workspace_toc_search_tool_definition(),
    ]


@agent_router.post("/runs", response_model=AgentLoopResponse)
async def create_agent_run(
    fastapi_request: Request,
    agent_loop_request: AgentLoopRequest,
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> AgentLoopResponse:
    return await run_agent_loop(
        fastapi_request=fastapi_request,
        agent_loop_request=agent_loop_request,
        current_user=current_user,
        database_session=database_session,
    )


@agent_router.post("/runs/{run_id}/abort", response_model=AbortAgentRunResponse)
async def abort_agent_run(
    run_id: str,
    fastapi_request: Request,
    current_user: User = Depends(get_current_user),
) -> AbortAgentRunResponse:
    _ = current_user
    abort_registry: AgentAbortRegistry = fastapi_request.app.state.agent_abort_registry
    was_found = await abort_registry.abort_run(run_id)
    return AbortAgentRunResponse(
        run_id=run_id,
        was_found=was_found,
        is_abort_requested=was_found,
    )
