import json
import posixpath
import re
from datetime import UTC, datetime
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.bash_tool import execute_workspace_bash_tool
from app.agent.contracts import AgentToolCall, AgentToolDefinition, AgentToolResult
from app.models import (
    AgentSession,
    AgentSessionMessage,
    Course,
    LearnerObservation,
    LearnerTopicMastery,
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
        "learner.record_topic_update": _record_learner_topic_update,
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


async def _record_learner_topic_update(
    arguments: dict[str, Any],
    tool_execution_context: ToolExecutionContext,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        tool_execution_context=tool_execution_context,
    )

    course_root_entry_path = _normalize_entry_path(arguments.get("course_root_entry_path"))
    course_root_workspace_entry = await _get_workspace_entry_by_path(
        workspace_id=workspace.id,
        entry_path=course_root_entry_path,
        tool_execution_context=tool_execution_context,
    )
    if course_root_workspace_entry.entry_type != WorkspaceEntryType.directory:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`course_root_entry_path` must point to a directory.",
        )

    topic_key = _normalize_topic_key(arguments.get("topic_key"))
    topic_title = _optional_clean_string(arguments.get("topic_title"))
    mastery_score = _validate_integer_range(
        value=arguments.get("mastery_score"),
        field_name="mastery_score",
        minimum=0,
        maximum=4,
    )
    confidence_score = _validate_integer_range(
        value=arguments.get("confidence_score", 50),
        field_name="confidence_score",
        minimum=0,
        maximum=100,
    )
    strength_notes = _optional_clean_string(arguments.get("strength_notes"))
    gap_notes = _optional_clean_string(arguments.get("gap_notes"))
    explanation_strategy = _optional_clean_string(arguments.get("explanation_strategy"))
    evidence_summary = _optional_clean_string(arguments.get("evidence_summary"))

    prerequisite_topic_keys = arguments.get("prerequisite_topic_keys") or []
    if not isinstance(prerequisite_topic_keys, list):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`prerequisite_topic_keys` must be an array of strings.",
        )
    normalized_prerequisite_topic_keys = [
        _normalize_topic_key(prerequisite_topic_key)
        for prerequisite_topic_key in prerequisite_topic_keys
    ]

    should_append_observation = arguments.get("should_append_observation", True)
    if not isinstance(should_append_observation, bool):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`should_append_observation` must be a boolean.",
        )

    observation_text = _optional_clean_string(arguments.get("observation_text"))
    evidence_excerpt = _optional_clean_string(arguments.get("evidence_excerpt"))
    topic_update_metadata = arguments.get("metadata") or {}
    if not isinstance(topic_update_metadata, dict):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`metadata` must be an object.",
        )

    now = datetime.now(UTC)
    course_display_name = _optional_clean_string(arguments.get("course_display_name"))
    if not course_display_name:
        course_display_name = (
            course_root_workspace_entry.entry_name
            if course_root_workspace_entry.entry_path != "/"
            else "Workspace Course"
        )

    existing_course_query = select(Course).where(
        and_(
            Course.workspace_id == workspace.id,
            Course.root_entry_path == course_root_entry_path,
        )
    )
    course = (
        await tool_execution_context.database_session.execute(existing_course_query)
    ).scalar_one_or_none()
    if course is None:
        course = Course(
            workspace_id=workspace.id,
            created_by_user_id=tool_execution_context.current_user.id,
            display_name=course_display_name,
            root_entry_path=course_root_entry_path,
            last_activity_at=now,
            course_metadata={},
        )
        tool_execution_context.database_session.add(course)
        await tool_execution_context.database_session.flush()
    else:
        course.display_name = course_display_name
        course.last_activity_at = now

    existing_topic_mastery_query = select(LearnerTopicMastery).where(
        and_(
            LearnerTopicMastery.course_id == course.id,
            LearnerTopicMastery.topic_key == topic_key,
        )
    )
    topic_mastery = (
        await tool_execution_context.database_session.execute(existing_topic_mastery_query)
    ).scalar_one_or_none()
    if topic_mastery is None:
        topic_mastery = LearnerTopicMastery(
            workspace_id=workspace.id,
            course_id=course.id,
            created_by_user_id=tool_execution_context.current_user.id,
            updated_by_user_id=tool_execution_context.current_user.id,
            topic_key=topic_key,
            topic_title=topic_title or topic_key,
            mastery_score=mastery_score,
            confidence_score=confidence_score,
            strength_notes=strength_notes,
            gap_notes=gap_notes,
            explanation_strategy=explanation_strategy,
            prerequisite_topic_keys=normalized_prerequisite_topic_keys,
            evidence_summary=evidence_summary,
            times_assessed=1,
            last_assessed_at=now,
            mastery_metadata=topic_update_metadata,
        )
        tool_execution_context.database_session.add(topic_mastery)
    else:
        topic_mastery.updated_by_user_id = tool_execution_context.current_user.id
        topic_mastery.topic_title = topic_title or topic_mastery.topic_title or topic_key
        topic_mastery.mastery_score = mastery_score
        topic_mastery.confidence_score = confidence_score
        topic_mastery.strength_notes = strength_notes
        topic_mastery.gap_notes = gap_notes
        topic_mastery.explanation_strategy = explanation_strategy
        topic_mastery.prerequisite_topic_keys = normalized_prerequisite_topic_keys
        topic_mastery.evidence_summary = evidence_summary
        topic_mastery.times_assessed = int(topic_mastery.times_assessed) + 1
        topic_mastery.last_assessed_at = now
        topic_mastery.mastery_metadata = topic_update_metadata

    await tool_execution_context.database_session.flush()

    agent_session_id = await _validate_optional_agent_session_id(
        value=arguments.get("agent_session_id"),
        workspace=workspace,
        tool_execution_context=tool_execution_context,
    )
    agent_session_message_id = await _validate_optional_agent_session_message_id(
        value=arguments.get("agent_session_message_id"),
        workspace=workspace,
        tool_execution_context=tool_execution_context,
    )

    learner_observation: LearnerObservation | None = None
    if should_append_observation:
        final_observation_text = observation_text or _build_default_observation_text(
            topic_key=topic_key,
            mastery_score=mastery_score,
            confidence_score=confidence_score,
            strength_notes=strength_notes,
            gap_notes=gap_notes,
        )
        learner_observation = LearnerObservation(
            workspace_id=workspace.id,
            course_id=course.id,
            topic_mastery_id=topic_mastery.id,
            created_by_user_id=tool_execution_context.current_user.id,
            agent_session_id=agent_session_id,
            agent_session_message_id=agent_session_message_id,
            topic_key=topic_key,
            observation_text=final_observation_text,
            evidence_excerpt=evidence_excerpt,
            assessed_mastery_score=mastery_score,
            assessed_confidence_score=confidence_score,
            observation_metadata=topic_update_metadata,
        )
        tool_execution_context.database_session.add(learner_observation)

    await tool_execution_context.database_session.commit()

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "course_id": str(course.id),
            "course_display_name": course.display_name,
            "course_root_entry_path": course.root_entry_path,
            "topic_mastery": {
                "id": str(topic_mastery.id),
                "topic_key": topic_mastery.topic_key,
                "topic_title": topic_mastery.topic_title,
                "mastery_score": topic_mastery.mastery_score,
                "confidence_score": topic_mastery.confidence_score,
                "times_assessed": topic_mastery.times_assessed,
                "last_assessed_at": (
                    topic_mastery.last_assessed_at.isoformat()
                    if topic_mastery.last_assessed_at
                    else None
                ),
            },
            "observation_id": str(learner_observation.id) if learner_observation else None,
            "scoring_rubric": {
                "0": "No evidence of understanding",
                "1": "Recognizes terms only",
                "2": "Partial procedural understanding",
                "3": "Can explain/apply correctly in standard cases",
                "4": "Can transfer understanding to connected or harder cases",
            },
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


def _normalize_topic_key(topic_key_value: Any) -> str:
    if not isinstance(topic_key_value, str) or not topic_key_value.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`topic_key` must be a non-empty string.",
        )
    normalized_topic_key = re.sub(r"[^a-z0-9]+", "-", topic_key_value.lower()).strip("-")
    if not normalized_topic_key:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`topic_key` must contain letters or digits.",
        )
    return normalized_topic_key


def _optional_clean_string(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Expected a string value.",
        )
    cleaned_value = value.strip()
    return cleaned_value if cleaned_value else None


def _validate_integer_range(
    *,
    value: Any,
    field_name: str,
    minimum: int,
    maximum: int,
) -> int:
    if not isinstance(value, int):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{field_name}` must be an integer between {minimum} and {maximum}.",
        )
    if value < minimum or value > maximum:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{field_name}` must be an integer between {minimum} and {maximum}.",
        )
    return value


def _build_default_observation_text(
    *,
    topic_key: str,
    mastery_score: int,
    confidence_score: int,
    strength_notes: str | None,
    gap_notes: str | None,
) -> str:
    summary_parts = [
        f"Topic `{topic_key}` assessed at mastery {mastery_score}/4",
        f"with confidence {confidence_score}/100.",
    ]
    if strength_notes:
        summary_parts.append(f"Strength: {strength_notes}")
    if gap_notes:
        summary_parts.append(f"Gap: {gap_notes}")
    return " ".join(summary_parts)


async def _validate_optional_agent_session_id(
    *,
    value: Any,
    workspace: Workspace,
    tool_execution_context: ToolExecutionContext,
) -> UUID | None:
    if value in {None, ""}:
        return None
    if not isinstance(value, str):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`agent_session_id` must be a UUID string.",
        )
    try:
        agent_session_id = UUID(value)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid agent_session_id `{value}`.",
        ) from error

    agent_session_query = select(AgentSession.id).where(
        and_(
            AgentSession.id == agent_session_id,
            AgentSession.workspace_id == workspace.id,
        )
    )
    existing_agent_session_id = (
        await tool_execution_context.database_session.execute(agent_session_query)
    ).scalar_one_or_none()
    if existing_agent_session_id is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="agent_session_id not found in this workspace.",
        )
    return agent_session_id


async def _validate_optional_agent_session_message_id(
    *,
    value: Any,
    workspace: Workspace,
    tool_execution_context: ToolExecutionContext,
) -> UUID | None:
    if value in {None, ""}:
        return None
    if not isinstance(value, str):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`agent_session_message_id` must be a UUID string.",
        )
    try:
        agent_session_message_id = UUID(value)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid agent_session_message_id `{value}`.",
        ) from error

    agent_session_message_query = select(AgentSessionMessage.id).where(
        and_(
            AgentSessionMessage.id == agent_session_message_id,
            AgentSessionMessage.workspace_id == workspace.id,
        )
    )
    existing_agent_session_message_id = (
        await tool_execution_context.database_session.execute(agent_session_message_query)
    ).scalar_one_or_none()
    if existing_agent_session_message_id is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="agent_session_message_id not found in this workspace.",
        )
    return agent_session_message_id


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
