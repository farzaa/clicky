import json
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.bash_tool import execute_workspace_bash_tool
from app.agent.contracts import AgentToolCall, AgentToolDefinition, AgentToolResult
from app.models import (
    User,
    Workspace,
    WorkspaceContentType,
    WorkspaceEntry,
    WorkspaceEntryType,
    WorkspaceMembership,
)


@dataclass
class ToolExecutionContext:
    current_user: User
    database_session: AsyncSession
    declared_tools_by_name: dict[str, AgentToolDefinition]


async def execute_tool_call(
    tool_call: AgentToolCall,
    tool_execution_context: ToolExecutionContext,
) -> AgentToolResult:
    if tool_call.name not in tool_execution_context.declared_tools_by_name:
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=f"Tool `{tool_call.name}` was not declared for this run.",
            is_error=True,
        )

    try:
        arguments = json.loads(tool_call.arguments_json or "{}")
    except json.JSONDecodeError as error:
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=f"Invalid tool arguments JSON: {error}",
            is_error=True,
        )

    tool_handlers = {
        "workspace.list_entries": _list_workspace_entries,
        "workspace.read_entry": _read_workspace_entry,
        "workspace.write_entry": _write_workspace_entry,
        "workspace.run_bash": _run_workspace_bash,
    }
    tool_handler = tool_handlers.get(tool_call.name)

    if tool_handler is None:
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=f"Tool `{tool_call.name}` is not implemented by the backend.",
            is_error=True,
        )

    try:
        output_text = await tool_handler(arguments, tool_execution_context)
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=output_text,
        )
    except HTTPException as error:
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=error.detail if isinstance(error.detail, str) else str(error.detail),
            is_error=True,
        )
    except Exception as error:
        return AgentToolResult(
            tool_call_id=tool_call.id,
            tool_name=tool_call.name,
            output_text=f"Tool execution failed: {error}",
            is_error=True,
        )


async def _list_workspace_entries(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        tool_execution_context=tool_execution_context,
    )
    parent_entry_path = arguments.get("parent_entry_path", "/")
    normalized_parent_entry_path = _normalize_entry_path(parent_entry_path)

    parent_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_path == normalized_parent_entry_path,
        ),
    )
    parent_entry = (
        await tool_execution_context.database_session.execute(parent_entry_query)
    ).scalar_one_or_none()

    if parent_entry is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Parent path `{normalized_parent_entry_path}` was not found.",
        )

    child_entries_query = (
        select(WorkspaceEntry)
        .where(
            and_(
                WorkspaceEntry.workspace_id == workspace.id,
                WorkspaceEntry.parent_entry_id == parent_entry.id,
            ),
        )
        .order_by(WorkspaceEntry.entry_type.asc(), WorkspaceEntry.entry_name.asc())
    )
    child_entries = (
        await tool_execution_context.database_session.execute(child_entries_query)
    ).scalars().all()

    serialized_entries = [
        {
            "entry_name": child_entry.entry_name,
            "entry_path": child_entry.entry_path,
            "entry_type": child_entry.entry_type.value,
            "content_type": child_entry.content_type.value
            if child_entry.content_type
            else None,
            "size_bytes": child_entry.size_bytes,
        }
        for child_entry in child_entries
    ]
    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "parent_entry_path": normalized_parent_entry_path,
            "entries": serialized_entries,
        },
    )


async def _read_workspace_entry(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        tool_execution_context=tool_execution_context,
    )
    normalized_entry_path = _normalize_entry_path(arguments.get("entry_path"))
    workspace_entry = await _get_workspace_entry_by_path(
        workspace_id=workspace.id,
        entry_path=normalized_entry_path,
        tool_execution_context=tool_execution_context,
    )

    if workspace_entry.entry_type != WorkspaceEntryType.file:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{normalized_entry_path}` is not a file.",
        )

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "entry_path": normalized_entry_path,
            "content_type": workspace_entry.content_type.value
            if workspace_entry.content_type
            else None,
            "mime_type": workspace_entry.mime_type,
            "text_content": workspace_entry.text_content,
            "size_bytes": workspace_entry.size_bytes,
            "has_binary_content": workspace_entry.binary_content is not None,
            "entry_metadata": workspace_entry.entry_metadata,
        },
    )


async def _write_workspace_entry(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        tool_execution_context=tool_execution_context,
    )
    normalized_entry_path = _normalize_entry_path(arguments.get("entry_path"))
    if normalized_entry_path == "/":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The root path cannot be overwritten.",
        )

    parent_entry_path = _normalize_entry_path(
        arguments.get("parent_entry_path") or normalized_entry_path.rsplit("/", 1)[0] or "/",
    )
    parent_workspace_entry = await _get_workspace_entry_by_path(
        workspace_id=workspace.id,
        entry_path=parent_entry_path,
        tool_execution_context=tool_execution_context,
    )
    if parent_workspace_entry.entry_type != WorkspaceEntryType.directory:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Parent path `{parent_entry_path}` is not a directory.",
        )

    entry_name = normalized_entry_path.split("/")[-1]
    text_content = arguments.get("text_content")
    content_type_text = arguments.get("content_type", "text")
    try:
        content_type = WorkspaceContentType(content_type_text)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported content type `{content_type_text}`.",
        ) from error

    existing_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_path == normalized_entry_path,
        ),
    )
    existing_entry = (
        await tool_execution_context.database_session.execute(existing_entry_query)
    ).scalar_one_or_none()

    if existing_entry is None:
        existing_entry = WorkspaceEntry(
            workspace_id=workspace.id,
            parent_entry_id=parent_workspace_entry.id,
            created_by_user_id=tool_execution_context.current_user.id,
            entry_name=entry_name,
            entry_path=normalized_entry_path,
            entry_type=WorkspaceEntryType.file,
            content_type=content_type,
            mime_type=arguments.get("mime_type"),
            text_content=text_content,
            size_bytes=len(text_content.encode("utf-8")) if isinstance(text_content, str) else None,
            entry_metadata=arguments.get("entry_metadata") or {},
        )
        tool_execution_context.database_session.add(existing_entry)
    else:
        existing_entry.parent_entry_id = parent_workspace_entry.id
        existing_entry.entry_name = entry_name
        existing_entry.entry_type = WorkspaceEntryType.file
        existing_entry.content_type = content_type
        existing_entry.mime_type = arguments.get("mime_type")
        existing_entry.text_content = text_content
        existing_entry.size_bytes = (
            len(text_content.encode("utf-8"))
            if isinstance(text_content, str)
            else None
        )
        existing_entry.entry_metadata = arguments.get("entry_metadata") or {}

    await tool_execution_context.database_session.commit()
    await tool_execution_context.database_session.refresh(existing_entry)

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "entry_path": existing_entry.entry_path,
            "content_type": existing_entry.content_type.value
            if existing_entry.content_type
            else None,
            "size_bytes": existing_entry.size_bytes,
            "status": "written",
        },
    )


async def _run_workspace_bash(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    return await execute_workspace_bash_tool(
        arguments=arguments,
        current_user=tool_execution_context.current_user,
        database_session=tool_execution_context.database_session,
    )


async def _get_accessible_workspace(
    *,
    workspace_id_text: str | None,
    tool_execution_context: ToolExecutionContext,
) -> Workspace:
    if not workspace_id_text:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`workspace_id` is required.",
        )

    try:
        workspace_id = UUID(workspace_id_text)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid workspace_id `{workspace_id_text}`.",
        ) from error

    accessible_workspace_query = (
        select(Workspace)
        .join(WorkspaceMembership, WorkspaceMembership.workspace_id == Workspace.id)
        .where(
            and_(
                Workspace.id == workspace_id,
                WorkspaceMembership.user_id == tool_execution_context.current_user.id,
            ),
        )
    )
    workspace = (
        await tool_execution_context.database_session.execute(accessible_workspace_query)
    ).scalar_one_or_none()

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found or not accessible.",
        )

    return workspace


async def _get_workspace_entry_by_path(
    *,
    workspace_id: UUID,
    entry_path: str,
    tool_execution_context: ToolExecutionContext,
) -> WorkspaceEntry:
    workspace_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_path == entry_path,
        ),
    )
    workspace_entry = (
        await tool_execution_context.database_session.execute(workspace_entry_query)
    ).scalar_one_or_none()

    if workspace_entry is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Path `{entry_path}` was not found.",
        )

    return workspace_entry


def _normalize_entry_path(entry_path_value: Any) -> str:
    if not isinstance(entry_path_value, str) or not entry_path_value.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="A non-empty path string is required.",
        )

    normalized_entry_path = "/" + entry_path_value.strip().strip("/")
    return "/" if normalized_entry_path == "/" else normalized_entry_path
