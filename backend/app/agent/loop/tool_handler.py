import json
import posixpath
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import and_, or_, select
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
        "workspace.search_toc": _search_workspace_toc,
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


async def _search_workspace_toc(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        tool_execution_context=tool_execution_context,
    )
    query_text = arguments.get("query")
    if not isinstance(query_text, str) or not query_text.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`query` must be a non-empty string.",
        )

    max_results_value = arguments.get("max_results", 8)
    if not isinstance(max_results_value, int) or max_results_value < 1 or max_results_value > 20:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`max_results` must be an integer between 1 and 20.",
        )

    ingestion_artifacts_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.file,
            or_(
                WorkspaceEntry.entry_path.like("%__ingested/toc.json"),
                WorkspaceEntry.entry_path.like("%__ingested/manifest.json"),
            ),
        )
    )
    ingestion_artifacts = list(
        (
            await tool_execution_context.database_session.execute(ingestion_artifacts_query)
        ).scalars().all()
    )

    bundle_manifests_by_directory_path: dict[str, dict[str, Any]] = {}
    bundle_toc_payloads_by_directory_path: dict[str, list[dict[str, Any]]] = {}

    for ingestion_artifact in ingestion_artifacts:
        if ingestion_artifact.text_content is None:
            continue
        try:
            artifact_payload = json.loads(ingestion_artifact.text_content)
        except json.JSONDecodeError:
            continue

        bundle_directory_path = ingestion_artifact.entry_path.rsplit("/", 1)[0]
        if ingestion_artifact.entry_path.endswith("/manifest.json"):
            if isinstance(artifact_payload, dict):
                bundle_manifests_by_directory_path[bundle_directory_path] = artifact_payload
            continue
        if ingestion_artifact.entry_path.endswith("/toc.json") and isinstance(artifact_payload, list):
            bundle_toc_payloads_by_directory_path[bundle_directory_path] = artifact_payload

    query_tokens = _tokenize_workspace_search_text(query_text)
    normalized_query_text = _normalize_workspace_search_text(query_text)

    matched_toc_entries: list[dict[str, Any]] = []
    searched_documents: list[dict[str, Any]] = []
    for bundle_directory_path in sorted(bundle_toc_payloads_by_directory_path.keys()):
        manifest_payload = bundle_manifests_by_directory_path.get(bundle_directory_path, {})
        source_payload = manifest_payload.get("source", {})
        searched_documents.append(
            {
                "bundle_directory_path": bundle_directory_path,
                "source_entry_path": source_payload.get("entry_path"),
                "source_entry_name": source_payload.get("entry_name"),
                "toc_entry_path": f"{bundle_directory_path}/toc.json",
            }
        )

        toc_nodes = bundle_toc_payloads_by_directory_path[bundle_directory_path]
        matched_toc_entries.extend(
            _collect_workspace_toc_matches(
                toc_nodes=toc_nodes,
                bundle_directory_path=bundle_directory_path,
                source_payload=source_payload,
                normalized_query_text=normalized_query_text,
                query_tokens=query_tokens,
            )
        )

    matched_toc_entries.sort(
        key=lambda matched_toc_entry: (
            -matched_toc_entry["score"],
            matched_toc_entry["page_start"] if matched_toc_entry["page_start"] is not None else 10**9,
            matched_toc_entry["title"].lower(),
        )
    )

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "query": query_text,
            "searched_document_count": len(searched_documents),
            "results": matched_toc_entries[:max_results_value],
            "searched_documents": searched_documents,
        }
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

    raw_entry_path = entry_path_value.strip().replace("\\", "/")
    if raw_entry_path in {".", "./"}:
        return "/"

    absolute_entry_path = raw_entry_path if raw_entry_path.startswith("/") else f"/{raw_entry_path}"
    normalized_entry_path = posixpath.normpath(absolute_entry_path)
    return "/" if normalized_entry_path in {".", "/"} else normalized_entry_path


def _collect_workspace_toc_matches(
    *,
    toc_nodes: list[dict[str, Any]],
    bundle_directory_path: str,
    source_payload: dict[str, Any],
    normalized_query_text: str,
    query_tokens: list[str],
) -> list[dict[str, Any]]:
    matched_toc_entries: list[dict[str, Any]] = []
    for toc_node in toc_nodes:
        matched_toc_entries.extend(
            _collect_workspace_toc_matches_from_node(
                toc_node=toc_node,
                bundle_directory_path=bundle_directory_path,
                source_payload=source_payload,
                normalized_query_text=normalized_query_text,
                query_tokens=query_tokens,
            )
        )
    return matched_toc_entries


def _collect_workspace_toc_matches_from_node(
    *,
    toc_node: dict[str, Any],
    bundle_directory_path: str,
    source_payload: dict[str, Any],
    normalized_query_text: str,
    query_tokens: list[str],
) -> list[dict[str, Any]]:
    matched_toc_entries: list[dict[str, Any]] = []

    title = str(toc_node.get("title") or "")
    heading_path = [
        str(heading_path_part)
        for heading_path_part in toc_node.get("heading_path", [])
        if isinstance(heading_path_part, str)
    ]
    match_score = _score_workspace_toc_match(
        title=title,
        heading_path=heading_path,
        normalized_query_text=normalized_query_text,
        query_tokens=query_tokens,
    )
    if match_score > 0:
        matched_toc_entries.append(
            {
                "score": match_score,
                "title": title,
                "heading_path": heading_path,
                "section_id": toc_node.get("section_id"),
                "heading_level": toc_node.get("heading_level"),
                "page_start": toc_node.get("page_start"),
                "page_end": toc_node.get("page_end"),
                "bundle_directory_path": bundle_directory_path,
                "toc_entry_path": f"{bundle_directory_path}/toc.json",
                "source_entry_path": source_payload.get("entry_path"),
                "source_entry_name": source_payload.get("entry_name"),
            }
        )

    child_toc_nodes = toc_node.get("children", [])
    if isinstance(child_toc_nodes, list):
        for child_toc_node in child_toc_nodes:
            if not isinstance(child_toc_node, dict):
                continue
            matched_toc_entries.extend(
                _collect_workspace_toc_matches_from_node(
                    toc_node=child_toc_node,
                    bundle_directory_path=bundle_directory_path,
                    source_payload=source_payload,
                    normalized_query_text=normalized_query_text,
                    query_tokens=query_tokens,
                )
            )

    return matched_toc_entries


def _score_workspace_toc_match(
    *,
    title: str,
    heading_path: list[str],
    normalized_query_text: str,
    query_tokens: list[str],
) -> int:
    if not normalized_query_text:
        return 0

    normalized_title = _normalize_workspace_search_text(title)
    normalized_heading_path = _normalize_workspace_search_text(" ".join(heading_path))
    normalized_combined_text = _normalize_workspace_search_text(
        " ".join([title, *heading_path])
    )
    if not normalized_combined_text:
        return 0

    score = 0
    if normalized_query_text == normalized_title:
        score += 120
    elif normalized_query_text == normalized_heading_path:
        score += 110
    elif normalized_query_text in normalized_title:
        score += 90
    elif normalized_query_text in normalized_heading_path:
        score += 80
    elif normalized_query_text in normalized_combined_text:
        score += 70

    if not query_tokens:
        return score

    combined_tokens = set(_tokenize_workspace_search_text(normalized_combined_text))
    title_tokens = set(_tokenize_workspace_search_text(normalized_title))
    matched_query_token_count = sum(1 for query_token in query_tokens if query_token in combined_tokens)
    if matched_query_token_count == 0 and score == 0:
        return 0

    score += matched_query_token_count * 12
    if all(query_token in combined_tokens for query_token in query_tokens):
        score += 24
    if all(query_token in title_tokens for query_token in query_tokens):
        score += 12

    return score


def _normalize_workspace_search_text(value: str) -> str:
    normalized_characters = [
        character.lower() if character.isalnum() else " "
        for character in value
    ]
    return " ".join("".join(normalized_characters).split())


def _tokenize_workspace_search_text(value: str) -> list[str]:
    normalized_value = _normalize_workspace_search_text(value)
    return normalized_value.split() if normalized_value else []
