from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.contracts import (
    AbortAgentRunResponse,
    AgentLoopRequest,
    AgentLoopResponse,
    AgentSessionMessageResponse,
    AgentSessionMessagesListResponse,
    AgentSessionResponse,
    AgentSessionsListResponse,
    AgentToolDefinition,
)
from app.agent.bash_tool import build_workspace_bash_tool_definition
from app.agent.loop.abort_registry import AgentAbortRegistry
from app.agent.loop.service import run_agent_loop
from app.auth import get_current_user
from app.database import get_database_session
from app.models import AgentSession, AgentSessionMessage, User, Workspace, WorkspaceMembership

agent_router = APIRouter(prefix="/agent", tags=["agent"])


async def require_accessible_workspace(
    *,
    workspace_id: UUID,
    current_user: User,
    database_session: AsyncSession,
) -> Workspace:
    accessible_workspace_query = (
        select(Workspace)
        .join(WorkspaceMembership, WorkspaceMembership.workspace_id == Workspace.id)
        .where(
            and_(
                Workspace.id == workspace_id,
                WorkspaceMembership.user_id == current_user.id,
            )
        )
    )
    workspace = (await database_session.execute(accessible_workspace_query)).scalar_one_or_none()
    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )
    return workspace


def build_agent_session_response(agent_session: AgentSession) -> AgentSessionResponse:
    return AgentSessionResponse(
        id=str(agent_session.id),
        workspace_id=str(agent_session.workspace_id),
        agent_id=str(agent_session.agent_id) if agent_session.agent_id else None,
        created_by_user_id=(
            str(agent_session.created_by_user_id)
            if agent_session.created_by_user_id
            else None
        ),
        display_name=agent_session.display_name,
        last_message_at=agent_session.last_message_at,
        created_at=agent_session.created_at,
        updated_at=agent_session.updated_at,
        session_metadata=agent_session.session_metadata,
    )


def build_agent_session_message_response(
    agent_session_message: AgentSessionMessage,
) -> AgentSessionMessageResponse:
    return AgentSessionMessageResponse(
        id=str(agent_session_message.id),
        workspace_id=str(agent_session_message.workspace_id),
        agent_session_id=str(agent_session_message.agent_session_id),
        created_by_user_id=(
            str(agent_session_message.created_by_user_id)
            if agent_session_message.created_by_user_id
            else None
        ),
        run_id=agent_session_message.run_id,
        sequence_index=agent_session_message.sequence_index,
        role=agent_session_message.role,
        name=agent_session_message.name,
        tool_call_id=agent_session_message.tool_call_id,
        provider_response_id=agent_session_message.provider_response_id,
        content=agent_session_message.content,
        images_payload=agent_session_message.images_payload,
        tool_calls_payload=agent_session_message.tool_calls_payload,
        message_metadata=agent_session_message.message_metadata,
        created_at=agent_session_message.created_at,
        updated_at=agent_session_message.updated_at,
    )


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


@agent_router.get(
    "/workspaces/{workspace_id}/sessions",
    response_model=AgentSessionsListResponse,
)
async def list_workspace_agent_sessions(
    workspace_id: UUID,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> AgentSessionsListResponse:
    workspace = await require_accessible_workspace(
        workspace_id=workspace_id,
        current_user=current_user,
        database_session=database_session,
    )
    agent_sessions_query = (
        select(AgentSession)
        .where(AgentSession.workspace_id == workspace.id)
        .order_by(
            AgentSession.last_message_at.desc().nulls_last(),
            AgentSession.created_at.desc(),
        )
        .limit(limit)
        .offset(offset)
    )
    agent_sessions = (await database_session.execute(agent_sessions_query)).scalars().all()
    return AgentSessionsListResponse(
        workspace_id=str(workspace.id),
        sessions=[
            build_agent_session_response(agent_session)
            for agent_session in agent_sessions
        ],
    )


@agent_router.get(
    "/workspaces/{workspace_id}/sessions/{agent_session_id}/messages",
    response_model=AgentSessionMessagesListResponse,
)
async def list_workspace_agent_session_messages(
    workspace_id: UUID,
    agent_session_id: UUID,
    limit: int = Query(default=200, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> AgentSessionMessagesListResponse:
    workspace = await require_accessible_workspace(
        workspace_id=workspace_id,
        current_user=current_user,
        database_session=database_session,
    )
    agent_session_query = select(AgentSession).where(
        and_(
            AgentSession.id == agent_session_id,
            AgentSession.workspace_id == workspace.id,
        )
    )
    agent_session = (await database_session.execute(agent_session_query)).scalar_one_or_none()
    if agent_session is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Agent session not found.",
        )

    total_count_query = select(func.count(AgentSessionMessage.id)).where(
        AgentSessionMessage.agent_session_id == agent_session.id
    )
    total_count = int((await database_session.execute(total_count_query)).scalar_one())

    agent_session_messages_query = (
        select(AgentSessionMessage)
        .where(AgentSessionMessage.agent_session_id == agent_session.id)
        .order_by(AgentSessionMessage.sequence_index.asc())
        .limit(limit)
        .offset(offset)
    )
    agent_session_messages = (
        await database_session.execute(agent_session_messages_query)
    ).scalars().all()

    return AgentSessionMessagesListResponse(
        workspace_id=str(workspace.id),
        agent_session_id=str(agent_session.id),
        messages=[
            build_agent_session_message_response(agent_session_message)
            for agent_session_message in agent_session_messages
        ],
        total_count=total_count,
    )
