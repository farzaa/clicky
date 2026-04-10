import asyncio
import base64
import hashlib
import json
import mimetypes
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.contracts import AgentToolDefinition
from app.models import (
    User,
    Workspace,
    WorkspaceContentType,
    WorkspaceEntry,
    WorkspaceEntryType,
    WorkspaceMembership,
)

DEFAULT_BASH_TIMEOUT_SECONDS = 10
MAXIMUM_BASH_TIMEOUT_SECONDS = 30
JUST_BASH_RUNNER_PATH = Path(__file__).with_name("just_bash_runner.mjs")


@dataclass
class JustBashExecutionResult:
    stdout: str
    stderr: str
    exit_code: int
    workspace_snapshot_entries: list["FilesystemSnapshotEntry"]


@dataclass
class WorkspaceSyncSummary:
    created_entry_count: int
    deleted_entry_count: int
    final_directory_count: int
    final_file_count: int


@dataclass
class FilesystemSnapshotEntry:
    entry_path: str
    entry_type: WorkspaceEntryType
    file_bytes: bytes | None = None


def build_workspace_bash_tool_definition() -> AgentToolDefinition:
    return AgentToolDefinition(
        name="workspace.run_bash",
        description=(
            "Run a bash script against a workspace filesystem using an isolated "
            "just-bash shell. File changes are written back to the workspace."
        ),
        input_json_schema={
            "type": "object",
            "properties": {
                "workspace_id": {"type": "string"},
                "script": {"type": "string"},
                "working_directory": {"type": "string"},
                "stdin": {"type": "string"},
                "environment_variables": {
                    "type": "object",
                    "additionalProperties": {"type": "string"},
                },
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAXIMUM_BASH_TIMEOUT_SECONDS,
                },
            },
            "required": ["workspace_id", "script"],
            "additionalProperties": False,
        },
    )


async def execute_workspace_bash_tool(
    *,
    arguments: dict[str, Any],
    current_user: User,
    database_session: AsyncSession,
) -> str:
    workspace = await _get_accessible_workspace(
        workspace_id_text=arguments.get("workspace_id"),
        current_user=current_user,
        database_session=database_session,
    )
    script = _require_non_empty_string(
        value=arguments.get("script"),
        field_name="script",
    )
    working_directory = _normalize_workspace_entry_path(
        arguments.get("working_directory", "/")
    )
    stdin_text = _validate_optional_string(
        value=arguments.get("stdin"),
        field_name="stdin",
    )
    environment_variables = _validate_environment_variables(
        environment_variables=arguments.get("environment_variables")
    )
    timeout_seconds = _validate_timeout_seconds(
        timeout_seconds_value=arguments.get("timeout_seconds")
    )

    workspace_entries = await _load_workspace_entries(
        workspace_id=workspace.id,
        database_session=database_session,
    )
    workspace_entries_by_path = {
        workspace_entry.entry_path: workspace_entry
        for workspace_entry in workspace_entries
    }
    working_directory_entry = workspace_entries_by_path.get(working_directory)
    if working_directory_entry is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Working directory `{working_directory}` was not found.",
        )
    if working_directory_entry.entry_type != WorkspaceEntryType.directory:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{working_directory}` is not a directory.",
        )

    bash_execution_result = await _run_just_bash_script(
        workspace_entries=workspace_entries,
        script=script,
        working_directory=working_directory,
        stdin_text=stdin_text,
        environment_variables=environment_variables,
        timeout_seconds=timeout_seconds,
    )

    workspace_sync_summary = await _sync_workspace_snapshot_back_to_workspace(
        filesystem_snapshot_entries=bash_execution_result.workspace_snapshot_entries,
        workspace=workspace,
        current_user=current_user,
        database_session=database_session,
        existing_workspace_entries_by_path=workspace_entries_by_path,
    )

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "working_directory": working_directory,
            "exit_code": bash_execution_result.exit_code,
            "stdout": bash_execution_result.stdout,
            "stderr": bash_execution_result.stderr,
            "timeout_seconds": timeout_seconds,
            "sync_summary": {
                "created_entry_count": workspace_sync_summary.created_entry_count,
                "deleted_entry_count": workspace_sync_summary.deleted_entry_count,
                "final_directory_count": workspace_sync_summary.final_directory_count,
                "final_file_count": workspace_sync_summary.final_file_count,
            },
        }
    )


async def _run_just_bash_script(
    *,
    workspace_entries: list[WorkspaceEntry],
    script: str,
    working_directory: str,
    stdin_text: str | None,
    environment_variables: dict[str, str],
    timeout_seconds: int,
) -> JustBashExecutionResult:
    if not JUST_BASH_RUNNER_PATH.exists():
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=(
                f"Missing just-bash runner at `{JUST_BASH_RUNNER_PATH.name}`. "
                "Install backend/app/agent dependencies before using workspace.run_bash."
            ),
        )

    execution_request = {
        "workspaceEntries": _serialize_workspace_entries_for_runner(workspace_entries),
        "script": script,
        "workingDirectory": working_directory,
        "stdin": stdin_text or "",
        "environmentVariables": environment_variables,
        "timeoutMs": timeout_seconds * 1000,
    }

    just_bash_process = await asyncio.create_subprocess_exec(
        "node",
        str(JUST_BASH_RUNNER_PATH),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    request_bytes = json.dumps(execution_request).encode("utf-8")
    stdout_bytes, stderr_bytes = await just_bash_process.communicate(input=request_bytes)

    if just_bash_process.returncode != 0:
        stderr_text = stderr_bytes.decode("utf-8", errors="replace").strip()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=stderr_text or "just-bash runner process failed.",
        )

    try:
        execution_response = json.loads(stdout_bytes.decode("utf-8"))
    except json.JSONDecodeError as error:
        stderr_text = stderr_bytes.decode("utf-8", errors="replace").strip()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=(
                "just-bash runner returned invalid JSON. "
                f"stderr: {stderr_text or 'none'}"
            ),
        ) from error

    return JustBashExecutionResult(
        stdout=str(execution_response.get("stdout", "")),
        stderr=str(execution_response.get("stderr", "")),
        exit_code=int(execution_response.get("exitCode", 1)),
        workspace_snapshot_entries=_deserialize_workspace_snapshot_entries_from_runner(
            execution_response.get("workspaceEntries")
        ),
    )


async def _sync_workspace_snapshot_back_to_workspace(
    *,
    filesystem_snapshot_entries: list[FilesystemSnapshotEntry],
    workspace: Workspace,
    current_user: User,
    database_session: AsyncSession,
    existing_workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> WorkspaceSyncSummary:
    filesystem_snapshot_entries_by_path = {
        filesystem_snapshot_entry.entry_path: filesystem_snapshot_entry
        for filesystem_snapshot_entry in filesystem_snapshot_entries
    }

    deleted_entry_paths = sorted(
        (
            existing_entry_path
            for existing_entry_path in existing_workspace_entries_by_path
            if existing_entry_path != "/" and existing_entry_path not in filesystem_snapshot_entries_by_path
        ),
        key=_workspace_path_depth,
        reverse=True,
    )
    for deleted_entry_path in deleted_entry_paths:
        await database_session.delete(existing_workspace_entries_by_path[deleted_entry_path])
        existing_workspace_entries_by_path.pop(deleted_entry_path, None)

    await database_session.flush()

    created_entry_count = 0

    directory_snapshot_entries = sorted(
        (
            filesystem_snapshot_entry
            for filesystem_snapshot_entry in filesystem_snapshot_entries
            if filesystem_snapshot_entry.entry_type == WorkspaceEntryType.directory
            and filesystem_snapshot_entry.entry_path != "/"
        ),
        key=lambda filesystem_snapshot_entry: _workspace_path_depth(
            filesystem_snapshot_entry.entry_path
        ),
    )
    for directory_snapshot_entry in directory_snapshot_entries:
        parent_entry_path = _parent_workspace_path(directory_snapshot_entry.entry_path)
        parent_workspace_entry = existing_workspace_entries_by_path[parent_entry_path]
        existing_workspace_entry = existing_workspace_entries_by_path.get(
            directory_snapshot_entry.entry_path
        )
        if existing_workspace_entry is None:
            created_entry_count += 1
            existing_workspace_entry = WorkspaceEntry(
                workspace_id=workspace.id,
                parent_entry_id=parent_workspace_entry.id,
                created_by_user_id=current_user.id,
                entry_name=_workspace_entry_name(directory_snapshot_entry.entry_path),
                entry_path=directory_snapshot_entry.entry_path,
                entry_type=WorkspaceEntryType.directory,
                entry_metadata={},
            )
            database_session.add(existing_workspace_entry)
            existing_workspace_entries_by_path[directory_snapshot_entry.entry_path] = (
                existing_workspace_entry
            )
        else:
            existing_workspace_entry.parent_entry_id = parent_workspace_entry.id
            existing_workspace_entry.entry_name = _workspace_entry_name(
                directory_snapshot_entry.entry_path
            )
            existing_workspace_entry.entry_type = WorkspaceEntryType.directory
            existing_workspace_entry.content_type = None
            existing_workspace_entry.mime_type = None
            existing_workspace_entry.size_bytes = None
            existing_workspace_entry.content_sha256 = None
            existing_workspace_entry.text_content = None
            existing_workspace_entry.binary_content = None
            existing_workspace_entry.storage_object_key = None

    await database_session.flush()

    file_snapshot_entries = sorted(
        (
            filesystem_snapshot_entry
            for filesystem_snapshot_entry in filesystem_snapshot_entries
            if filesystem_snapshot_entry.entry_type == WorkspaceEntryType.file
        ),
        key=lambda filesystem_snapshot_entry: filesystem_snapshot_entry.entry_path,
    )
    for file_snapshot_entry in file_snapshot_entries:
        parent_entry_path = _parent_workspace_path(file_snapshot_entry.entry_path)
        parent_workspace_entry = existing_workspace_entries_by_path[parent_entry_path]
        existing_workspace_entry = existing_workspace_entries_by_path.get(
            file_snapshot_entry.entry_path
        )
        file_bytes = file_snapshot_entry.file_bytes or b""
        inferred_content_type, inferred_mime_type, text_content, binary_content = (
            _infer_workspace_file_storage(
                entry_path=file_snapshot_entry.entry_path,
                file_bytes=file_bytes,
                existing_workspace_entry=existing_workspace_entry,
            )
        )
        content_sha256 = hashlib.sha256(file_bytes).hexdigest()

        if existing_workspace_entry is None:
            created_entry_count += 1
            existing_workspace_entry = WorkspaceEntry(
                workspace_id=workspace.id,
                parent_entry_id=parent_workspace_entry.id,
                created_by_user_id=current_user.id,
                entry_name=_workspace_entry_name(file_snapshot_entry.entry_path),
                entry_path=file_snapshot_entry.entry_path,
                entry_type=WorkspaceEntryType.file,
                content_type=inferred_content_type,
                mime_type=inferred_mime_type,
                size_bytes=len(file_bytes),
                content_sha256=content_sha256,
                text_content=text_content,
                binary_content=binary_content,
                entry_metadata={},
            )
            database_session.add(existing_workspace_entry)
            existing_workspace_entries_by_path[file_snapshot_entry.entry_path] = (
                existing_workspace_entry
            )
            continue

        existing_workspace_entry.parent_entry_id = parent_workspace_entry.id
        existing_workspace_entry.entry_name = _workspace_entry_name(
            file_snapshot_entry.entry_path
        )
        existing_workspace_entry.entry_type = WorkspaceEntryType.file
        existing_workspace_entry.content_type = inferred_content_type
        existing_workspace_entry.mime_type = inferred_mime_type
        existing_workspace_entry.size_bytes = len(file_bytes)
        existing_workspace_entry.content_sha256 = content_sha256
        existing_workspace_entry.text_content = text_content
        existing_workspace_entry.binary_content = binary_content
        existing_workspace_entry.storage_object_key = None

    await database_session.commit()

    final_directory_count = sum(
        1
        for filesystem_snapshot_entry in filesystem_snapshot_entries
        if filesystem_snapshot_entry.entry_type == WorkspaceEntryType.directory
    )
    final_file_count = sum(
        1
        for filesystem_snapshot_entry in filesystem_snapshot_entries
        if filesystem_snapshot_entry.entry_type == WorkspaceEntryType.file
    )

    return WorkspaceSyncSummary(
        created_entry_count=created_entry_count,
        deleted_entry_count=len(deleted_entry_paths),
        final_directory_count=final_directory_count,
        final_file_count=final_file_count,
    )


async def _load_workspace_entries(
    *,
    workspace_id: UUID,
    database_session: AsyncSession,
) -> list[WorkspaceEntry]:
    workspace_entries_query = (
        select(WorkspaceEntry)
        .where(WorkspaceEntry.workspace_id == workspace_id)
        .order_by(WorkspaceEntry.entry_path.asc())
    )
    return list((await database_session.execute(workspace_entries_query)).scalars().all())


async def _get_accessible_workspace(
    *,
    workspace_id_text: str | None,
    current_user: User,
    database_session: AsyncSession,
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
                WorkspaceMembership.user_id == current_user.id,
            )
        )
    )
    workspace = (await database_session.execute(accessible_workspace_query)).scalar_one_or_none()

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found or not accessible.",
        )

    return workspace


def _require_non_empty_string(*, value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{field_name}` must be a non-empty string.",
        )
    return value


def _validate_optional_string(*, value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{field_name}` must be a string when provided.",
        )
    return value


def _validate_environment_variables(
    *,
    environment_variables: Any,
) -> dict[str, str]:
    if environment_variables is None:
        return {}
    if not isinstance(environment_variables, dict):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`environment_variables` must be an object of string values.",
        )

    validated_environment_variables: dict[str, str] = {}
    for environment_variable_name, environment_variable_value in environment_variables.items():
        if not isinstance(environment_variable_name, str) or not isinstance(
            environment_variable_value, str
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="`environment_variables` must contain only string keys and values.",
            )
        validated_environment_variables[environment_variable_name] = (
            environment_variable_value
        )

    return validated_environment_variables


def _validate_timeout_seconds(*, timeout_seconds_value: Any) -> int:
    if timeout_seconds_value is None:
        return DEFAULT_BASH_TIMEOUT_SECONDS
    if not isinstance(timeout_seconds_value, int):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`timeout_seconds` must be an integer.",
        )
    if timeout_seconds_value < 1 or timeout_seconds_value > MAXIMUM_BASH_TIMEOUT_SECONDS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "`timeout_seconds` must be between 1 and "
                f"{MAXIMUM_BASH_TIMEOUT_SECONDS}."
            ),
        )
    return timeout_seconds_value


def _normalize_workspace_entry_path(path_value: Any) -> str:
    if not isinstance(path_value, str) or not path_value.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="A non-empty path string is required.",
        )

    normalized_workspace_entry_path = "/" + path_value.strip().strip("/")
    return "/" if normalized_workspace_entry_path == "/" else normalized_workspace_entry_path


def _serialize_workspace_entries_for_runner(
    workspace_entries: list[WorkspaceEntry],
) -> list[dict[str, Any]]:
    serialized_workspace_entries: list[dict[str, Any]] = []

    for workspace_entry in workspace_entries:
        serialized_workspace_entry: dict[str, Any] = {
            "entryPath": workspace_entry.entry_path,
            "entryType": workspace_entry.entry_type.value,
        }

        if workspace_entry.entry_type == WorkspaceEntryType.file:
            if workspace_entry.binary_content is not None:
                serialized_workspace_entry["fileEncoding"] = "base64"
                serialized_workspace_entry["fileContent"] = base64.b64encode(
                    workspace_entry.binary_content
                ).decode("ascii")
            else:
                serialized_workspace_entry["fileEncoding"] = "utf-8"
                serialized_workspace_entry["fileContent"] = workspace_entry.text_content or ""

        serialized_workspace_entries.append(serialized_workspace_entry)

    return serialized_workspace_entries


def _deserialize_workspace_snapshot_entries_from_runner(
    serialized_workspace_entries: Any,
) -> list[FilesystemSnapshotEntry]:
    if not isinstance(serialized_workspace_entries, list):
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="just-bash runner did not return a valid workspace snapshot.",
        )

    filesystem_snapshot_entries: list[FilesystemSnapshotEntry] = []
    for serialized_workspace_entry in serialized_workspace_entries:
        if not isinstance(serialized_workspace_entry, dict):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="just-bash runner returned a malformed workspace entry.",
            )

        entry_path = _normalize_workspace_entry_path(
            serialized_workspace_entry.get("entryPath")
        )
        entry_type_text = serialized_workspace_entry.get("entryType")
        try:
            entry_type = WorkspaceEntryType(entry_type_text)
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"just-bash runner returned unsupported entry type `{entry_type_text}`.",
            ) from error

        if entry_type == WorkspaceEntryType.directory:
            filesystem_snapshot_entries.append(
                FilesystemSnapshotEntry(
                    entry_path=entry_path,
                    entry_type=WorkspaceEntryType.directory,
                )
            )
            continue

        file_encoding = serialized_workspace_entry.get("fileEncoding")
        file_content = serialized_workspace_entry.get("fileContent")
        if not isinstance(file_content, str):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"File `{entry_path}` is missing string content from the just-bash runner.",
            )

        if file_encoding == "base64":
            try:
                file_bytes = base64.b64decode(file_content.encode("ascii"), validate=True)
            except ValueError as error:
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"File `{entry_path}` has invalid base64 content from the just-bash runner.",
                ) from error
        elif file_encoding == "utf-8":
            file_bytes = file_content.encode("utf-8")
        else:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"File `{entry_path}` has unsupported encoding `{file_encoding}`.",
            )

        filesystem_snapshot_entries.append(
            FilesystemSnapshotEntry(
                entry_path=entry_path,
                entry_type=WorkspaceEntryType.file,
                file_bytes=file_bytes,
            )
        )

    if not any(
        filesystem_snapshot_entry.entry_path == "/"
        and filesystem_snapshot_entry.entry_type == WorkspaceEntryType.directory
        for filesystem_snapshot_entry in filesystem_snapshot_entries
    ):
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="just-bash runner returned a snapshot without the root directory.",
        )

    return sorted(
        filesystem_snapshot_entries,
        key=lambda filesystem_snapshot_entry: (
            0
            if filesystem_snapshot_entry.entry_type == WorkspaceEntryType.directory
            else 1,
            _workspace_path_depth(filesystem_snapshot_entry.entry_path),
            filesystem_snapshot_entry.entry_path,
        ),
    )


def _workspace_path_depth(workspace_path: str) -> int:
    return 0 if workspace_path == "/" else workspace_path.count("/")


def _workspace_entry_name(workspace_path: str) -> str:
    return "/" if workspace_path == "/" else workspace_path.rsplit("/", 1)[-1]


def _parent_workspace_path(workspace_path: str) -> str:
    if workspace_path == "/":
        return "/"
    parent_workspace_path = workspace_path.rsplit("/", 1)[0]
    return parent_workspace_path or "/"


def _infer_workspace_file_storage(
    *,
    entry_path: str,
    file_bytes: bytes,
    existing_workspace_entry: WorkspaceEntry | None,
) -> tuple[WorkspaceContentType, str | None, str | None, bytes | None]:
    inferred_mime_type = mimetypes.guess_type(entry_path)[0]

    try:
        text_content = file_bytes.decode("utf-8")
    except UnicodeDecodeError:
        existing_content_type = (
            existing_workspace_entry.content_type if existing_workspace_entry else None
        )
        return (
            existing_content_type
            if existing_content_type in {WorkspaceContentType.image, WorkspaceContentType.pdf}
            else WorkspaceContentType.other,
            inferred_mime_type,
            None,
            file_bytes,
        )

    if existing_workspace_entry and existing_workspace_entry.content_type == WorkspaceContentType.markdown:
        inferred_content_type = WorkspaceContentType.markdown
    elif entry_path.endswith(".md") or entry_path.endswith(".markdown"):
        inferred_content_type = WorkspaceContentType.markdown
    else:
        inferred_content_type = WorkspaceContentType.text

    if inferred_mime_type is None:
        inferred_mime_type = "text/markdown" if inferred_content_type == WorkspaceContentType.markdown else "text/plain"

    return inferred_content_type, inferred_mime_type, text_content, None
