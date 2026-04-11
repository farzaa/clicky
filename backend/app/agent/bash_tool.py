import asyncio
import base64
import fnmatch
import hashlib
import json
import mimetypes
import posixpath
import re
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.agent.contracts import AgentToolDefinition
from app.agent.postgres_readonly_shell import execute_workspace_read_only_shell_script
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
class MetadataOnlyWorkspaceCommandResult:
    stdout: str
    stderr: str
    exit_code: int


@dataclass
class FilesystemSnapshotEntry:
    entry_path: str
    entry_type: WorkspaceEntryType
    file_bytes: bytes | None = None


def build_workspace_bash_tool_definition() -> AgentToolDefinition:
    return AgentToolDefinition(
        name="workspace.run_bash",
        description=(
            "Run a read-only shell script against a Postgres-backed workspace "
            "filesystem. Supports only cheap inspection commands: `pwd`, `ls`, "
            "`find`, `cat`, `grep`, and `rg`. Write operations return EROFS."
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
    working_directory_argument = arguments.get("working_directory") or "/"
    working_directory = _normalize_workspace_entry_path(working_directory_argument)
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
    _ = stdin_text
    _ = environment_variables
    _ = timeout_seconds

    working_directory_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_path == working_directory,
        )
    )
    working_directory_entry = (
        await database_session.execute(working_directory_entry_query)
    ).scalar_one_or_none()
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

    read_only_shell_execution_result = await execute_workspace_read_only_shell_script(
        workspace_id=workspace.id,
        database_session=database_session,
        script=script,
        working_directory=working_directory,
    )
    final_directory_count_query = select(func.count()).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.directory,
        )
    )
    final_file_count_query = select(func.count()).where(
        and_(
            WorkspaceEntry.workspace_id == workspace.id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.file,
        )
    )
    final_directory_count = int(
        (await database_session.execute(final_directory_count_query)).scalar_one()
    )
    final_file_count = int(
        (await database_session.execute(final_file_count_query)).scalar_one()
    )

    return json.dumps(
        {
            "workspace_id": str(workspace.id),
            "working_directory": working_directory,
            "exit_code": read_only_shell_execution_result.exit_code,
            "stdout": read_only_shell_execution_result.stdout,
            "stderr": read_only_shell_execution_result.stderr,
            "timeout_seconds": timeout_seconds,
            "read_only": True,
            "sync_summary": {
                "created_entry_count": 0,
                "deleted_entry_count": 0,
                "final_directory_count": final_directory_count,
                "final_file_count": final_file_count,
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

    raw_workspace_path = path_value.strip().replace("\\", "/")
    if raw_workspace_path in {".", "./"}:
        return "/"

    absolute_workspace_path = (
        raw_workspace_path if raw_workspace_path.startswith("/") else f"/{raw_workspace_path}"
    )
    normalized_workspace_entry_path = posixpath.normpath(absolute_workspace_path)
    return "/" if normalized_workspace_entry_path in {".", "/"} else normalized_workspace_entry_path


def _try_execute_metadata_only_workspace_command(
    *,
    script: str,
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> MetadataOnlyWorkspaceCommandResult | None:
    stripped_script = script.strip()
    if not stripped_script:
        return None

    # Keep the fast path limited to simple read-only inspection flows.
    if any(token in stripped_script for token in ["\n", ";", "|", "||", "<<", "`", "$("]):
        return None

    if "&" in stripped_script.replace("&&", ""):
        return None

    chained_script_parts = [script_part.strip() for script_part in stripped_script.split("&&")]
    if not chained_script_parts or any(not script_part for script_part in chained_script_parts):
        return None

    combined_stdout_parts: list[str] = []
    combined_stderr_parts: list[str] = []
    last_exit_code = 0

    for chained_script_part in chained_script_parts:
        try:
            command_tokens = shlex.split(chained_script_part)
        except ValueError:
            return None

        if not command_tokens:
            return None

        command_tokens, should_suppress_stderr = _strip_supported_stderr_redirection(
            command_tokens
        )
        if command_tokens is None or not command_tokens:
            return None

        subcommand_result = _try_execute_single_metadata_only_workspace_command(
            command_tokens=command_tokens,
            working_directory=working_directory,
            workspace_entries_by_path=workspace_entries_by_path,
        )
        if subcommand_result is None:
            return None

        if subcommand_result.stdout:
            combined_stdout_parts.append(subcommand_result.stdout)
        if subcommand_result.stderr and not should_suppress_stderr:
            combined_stderr_parts.append(subcommand_result.stderr)

        last_exit_code = subcommand_result.exit_code
        if last_exit_code != 0:
            break

    return MetadataOnlyWorkspaceCommandResult(
        stdout="".join(combined_stdout_parts),
        stderr="".join(combined_stderr_parts),
        exit_code=last_exit_code,
    )


def _strip_supported_stderr_redirection(
    command_tokens: list[str],
) -> tuple[list[str] | None, bool]:
    stripped_command_tokens: list[str] = []
    token_index = 0
    should_suppress_stderr = False

    while token_index < len(command_tokens):
        current_token = command_tokens[token_index]
        if current_token == "2>":
            if token_index + 1 >= len(command_tokens):
                return None, False
            if command_tokens[token_index + 1] != "/dev/null":
                return None, False
            should_suppress_stderr = True
            token_index += 2
            continue
        if current_token == "2>/dev/null":
            should_suppress_stderr = True
            token_index += 1
            continue
        if current_token.startswith(">") or current_token.startswith("1>") or current_token.startswith("2>>"):
            return None, False
        stripped_command_tokens.append(current_token)
        token_index += 1

    return stripped_command_tokens, should_suppress_stderr


def _try_execute_single_metadata_only_workspace_command(
    *,
    command_tokens: list[str],
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> MetadataOnlyWorkspaceCommandResult | None:
    command_name = command_tokens[0]
    if command_name == "pwd":
        if len(command_tokens) != 1:
            return None
        return MetadataOnlyWorkspaceCommandResult(
            stdout=f"{working_directory}\n",
            stderr="",
            exit_code=0,
        )

    if command_name == "ls":
        return _execute_metadata_only_ls(
            command_tokens=command_tokens,
            working_directory=working_directory,
            workspace_entries_by_path=workspace_entries_by_path,
        )

    if command_name == "find":
        return _execute_metadata_only_find(
            command_tokens=command_tokens,
            working_directory=working_directory,
            workspace_entries_by_path=workspace_entries_by_path,
        )

    if command_name == "cat":
        return _execute_metadata_only_cat(
            command_tokens=command_tokens,
            working_directory=working_directory,
            workspace_entries_by_path=workspace_entries_by_path,
        )

    if command_name in {"grep", "rg"}:
        return _execute_metadata_only_grep_like_search(
            command_tokens=command_tokens,
            working_directory=working_directory,
            workspace_entries_by_path=workspace_entries_by_path,
            is_recursive_by_default=(command_name == "rg"),
        )

    return None


def _execute_metadata_only_ls(
    *,
    command_tokens: list[str],
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> MetadataOnlyWorkspaceCommandResult | None:
    include_hidden_entries = False
    use_long_format = False
    target_path_argument: str | None = None

    for command_token in command_tokens[1:]:
        if command_token.startswith("-"):
            supported_option_letters = {"a", "A", "l", "h"}
            option_letters = set(command_token.lstrip("-"))
            if not option_letters.issubset(supported_option_letters):
                return None
            if "a" in option_letters or "A" in option_letters:
                include_hidden_entries = True
            if "l" in option_letters:
                use_long_format = True
            continue

        if target_path_argument is not None:
            return None
        target_path_argument = command_token

    target_workspace_path = _resolve_workspace_script_path(
        working_directory=working_directory,
        path_argument=target_path_argument or ".",
    )
    target_workspace_entry = workspace_entries_by_path.get(target_workspace_path)
    if target_workspace_entry is None:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"ls: cannot access '{target_path_argument or '.'}': No such file or directory\n",
            exit_code=1,
        )

    if target_workspace_entry.entry_type == WorkspaceEntryType.file:
        stdout_lines = [
            _format_workspace_ls_entry(
                workspace_entry=target_workspace_entry,
                use_long_format=use_long_format,
            )
        ]
        return MetadataOnlyWorkspaceCommandResult(
            stdout="\n".join(stdout_lines) + "\n",
            stderr="",
            exit_code=0,
        )

    child_workspace_entries = sorted(
        (
            workspace_entry
            for workspace_entry in workspace_entries_by_path.values()
            if workspace_entry.entry_path != target_workspace_path
            and _parent_workspace_path(workspace_entry.entry_path) == target_workspace_path
        ),
        key=lambda workspace_entry: (
            0 if workspace_entry.entry_type == WorkspaceEntryType.directory else 1,
            workspace_entry.entry_name.lower(),
        ),
    )
    visible_workspace_entries = [
        workspace_entry
        for workspace_entry in child_workspace_entries
        if include_hidden_entries or not workspace_entry.entry_name.startswith(".")
    ]

    stdout_lines: list[str] = []
    if include_hidden_entries:
        synthetic_entries = [
            ("." , WorkspaceEntryType.directory, 0),
            ("..", WorkspaceEntryType.directory, 0),
        ]
        for entry_name, entry_type, entry_size in synthetic_entries:
            if use_long_format:
                entry_prefix = "d"
                stdout_lines.append(f"{entry_prefix} {entry_size:>8} {entry_name}")
            else:
                stdout_lines.append(entry_name)

    stdout_lines.extend(
        _format_workspace_ls_entry(
            workspace_entry=workspace_entry,
            use_long_format=use_long_format,
        )
        for workspace_entry in visible_workspace_entries
    )
    return MetadataOnlyWorkspaceCommandResult(
        stdout=("\n".join(stdout_lines) + "\n") if stdout_lines else "",
        stderr="",
        exit_code=0,
    )


def _execute_metadata_only_find(
    *,
    command_tokens: list[str],
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> MetadataOnlyWorkspaceCommandResult | None:
    search_root_argument = "."
    max_depth: int | None = None
    name_glob_pattern: str | None = None
    token_index = 1

    if token_index < len(command_tokens) and not command_tokens[token_index].startswith("-"):
        search_root_argument = command_tokens[token_index]
        token_index += 1

    while token_index < len(command_tokens):
        current_token = command_tokens[token_index]
        if current_token == "-maxdepth" and token_index + 1 < len(command_tokens):
            try:
                max_depth = int(command_tokens[token_index + 1])
            except ValueError:
                return None
            token_index += 2
            continue
        if current_token == "-name" and token_index + 1 < len(command_tokens):
            name_glob_pattern = command_tokens[token_index + 1]
            token_index += 2
            continue
        return None

    search_root_path = _resolve_workspace_script_path(
        working_directory=working_directory,
        path_argument=search_root_argument,
    )
    search_root_entry = workspace_entries_by_path.get(search_root_path)
    if search_root_entry is None:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"find: '{search_root_argument}': No such file or directory\n",
            exit_code=1,
        )

    matched_workspace_paths: list[str] = []
    sorted_workspace_paths = sorted(workspace_entries_by_path.keys())
    for candidate_workspace_path in sorted_workspace_paths:
        if not _workspace_path_is_within_root(
            workspace_path=candidate_workspace_path,
            root_workspace_path=search_root_path,
        ):
            continue
        if max_depth is not None:
            relative_depth = _workspace_path_depth(candidate_workspace_path) - _workspace_path_depth(
                search_root_path
            )
            if relative_depth > max_depth:
                continue

        candidate_entry_name = _workspace_entry_name(candidate_workspace_path)
        if name_glob_pattern is not None and not fnmatch.fnmatch(
            candidate_entry_name,
            name_glob_pattern,
        ):
            continue
        matched_workspace_paths.append(candidate_workspace_path)

    return MetadataOnlyWorkspaceCommandResult(
        stdout=("\n".join(matched_workspace_paths) + "\n") if matched_workspace_paths else "",
        stderr="",
        exit_code=0,
    )


def _execute_metadata_only_cat(
    *,
    command_tokens: list[str],
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
) -> MetadataOnlyWorkspaceCommandResult | None:
    if len(command_tokens) != 2:
        return None

    target_path_argument = command_tokens[1]
    target_workspace_path = _resolve_workspace_script_path(
        working_directory=working_directory,
        path_argument=target_path_argument,
    )
    target_workspace_entry = workspace_entries_by_path.get(target_workspace_path)
    if target_workspace_entry is None:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: No such file or directory\n",
            exit_code=1,
        )
    if target_workspace_entry.entry_type != WorkspaceEntryType.file:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: Is a directory\n",
            exit_code=1,
        )
    if target_workspace_entry.text_content is None:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: Binary content is not supported in metadata mode\n",
            exit_code=1,
        )

    stdout = target_workspace_entry.text_content
    if stdout and not stdout.endswith("\n"):
        stdout += "\n"
    return MetadataOnlyWorkspaceCommandResult(
        stdout=stdout,
        stderr="",
        exit_code=0,
    )


def _execute_metadata_only_grep_like_search(
    *,
    command_tokens: list[str],
    working_directory: str,
    workspace_entries_by_path: dict[str, WorkspaceEntry],
    is_recursive_by_default: bool,
) -> MetadataOnlyWorkspaceCommandResult | None:
    should_ignore_case = False
    should_include_line_numbers = False
    should_search_recursively = is_recursive_by_default
    positional_arguments: list[str] = []

    for command_token in command_tokens[1:]:
        if command_token.startswith("-") and command_token != "-":
            if command_token in {"--ignore-case", "-i"}:
                should_ignore_case = True
                continue
            if command_token in {"--line-number", "-n"}:
                should_include_line_numbers = True
                continue
            if command_token in {"-r", "-R"}:
                should_search_recursively = True
                continue
            if command_token.startswith("--"):
                return None

            option_letters = command_token.lstrip("-")
            if not option_letters or not set(option_letters).issubset({"i", "n", "r", "R"}):
                return None
            if "i" in option_letters:
                should_ignore_case = True
            if "n" in option_letters:
                should_include_line_numbers = True
            if "r" in option_letters or "R" in option_letters:
                should_search_recursively = True
            continue

        positional_arguments.append(command_token)

    if not positional_arguments or len(positional_arguments) > 2:
        return None

    regex_pattern = positional_arguments[0]
    search_root_argument = positional_arguments[1] if len(positional_arguments) == 2 else "."

    try:
        compiled_pattern = re.compile(
            regex_pattern,
            re.IGNORECASE if should_ignore_case else 0,
        )
    except re.error as error:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=f"{command_tokens[0]}: invalid regex `{regex_pattern}`: {error}\n",
            exit_code=2,
        )

    search_root_path = _resolve_workspace_script_path(
        working_directory=working_directory,
        path_argument=search_root_argument,
    )
    search_root_entry = workspace_entries_by_path.get(search_root_path)
    if search_root_entry is None:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr=(
                f"{command_tokens[0]}: {search_root_argument}: "
                "No such file or directory\n"
            ),
            exit_code=2,
        )

    searchable_workspace_entries: list[WorkspaceEntry] = []
    if search_root_entry.entry_type == WorkspaceEntryType.file:
        searchable_workspace_entries = [search_root_entry]
    else:
        if not should_search_recursively:
            return MetadataOnlyWorkspaceCommandResult(
                stdout="",
                stderr=f"{command_tokens[0]}: {search_root_argument}: Is a directory\n",
                exit_code=2,
            )
        searchable_workspace_entries = [
            workspace_entry
            for workspace_entry in sorted(
                workspace_entries_by_path.values(),
                key=lambda workspace_entry: workspace_entry.entry_path,
            )
            if workspace_entry.entry_type == WorkspaceEntryType.file
            and workspace_entry.text_content is not None
            and _workspace_path_is_within_root(
                workspace_path=workspace_entry.entry_path,
                root_workspace_path=search_root_path,
            )
        ]

    should_prefix_with_path = (
        len(searchable_workspace_entries) > 1 or search_root_entry.entry_type == WorkspaceEntryType.directory
    )
    matched_output_lines: list[str] = []
    for searchable_workspace_entry in searchable_workspace_entries:
        if searchable_workspace_entry.text_content is None:
            continue
        file_output_lines = _build_grep_like_output_lines(
            workspace_entry=searchable_workspace_entry,
            compiled_pattern=compiled_pattern,
            should_include_line_numbers=should_include_line_numbers,
            should_prefix_with_path=should_prefix_with_path,
        )
        matched_output_lines.extend(file_output_lines)

    if not matched_output_lines:
        return MetadataOnlyWorkspaceCommandResult(
            stdout="",
            stderr="",
            exit_code=1,
        )

    return MetadataOnlyWorkspaceCommandResult(
        stdout="\n".join(matched_output_lines) + "\n",
        stderr="",
        exit_code=0,
    )


def _build_grep_like_output_lines(
    *,
    workspace_entry: WorkspaceEntry,
    compiled_pattern: re.Pattern[str],
    should_include_line_numbers: bool,
    should_prefix_with_path: bool,
) -> list[str]:
    matched_output_lines: list[str] = []
    file_lines = workspace_entry.text_content.splitlines()
    for line_number, file_line in enumerate(file_lines, start=1):
        if compiled_pattern.search(file_line) is None:
            continue

        output_prefix_parts: list[str] = []
        if should_prefix_with_path:
            output_prefix_parts.append(workspace_entry.entry_path)
        if should_include_line_numbers:
            output_prefix_parts.append(str(line_number))

        if output_prefix_parts:
            matched_output_lines.append(":".join(output_prefix_parts) + f":{file_line}")
        else:
            matched_output_lines.append(file_line)

    return matched_output_lines


def _format_workspace_ls_entry(
    *,
    workspace_entry: WorkspaceEntry,
    use_long_format: bool,
) -> str:
    if not use_long_format:
        return workspace_entry.entry_name

    entry_prefix = "d" if workspace_entry.entry_type == WorkspaceEntryType.directory else "-"
    entry_size = workspace_entry.size_bytes or 0
    return f"{entry_prefix} {entry_size:>8} {workspace_entry.entry_name}"


def _resolve_workspace_script_path(
    *,
    working_directory: str,
    path_argument: str,
) -> str:
    if not path_argument.strip():
        return working_directory
    if path_argument.startswith("/"):
        return _normalize_workspace_entry_path(path_argument)

    normalized_relative_path = posixpath.normpath(
        posixpath.join(working_directory, path_argument)
    )
    return _normalize_workspace_entry_path(normalized_relative_path)


def _workspace_path_is_within_root(
    *,
    workspace_path: str,
    root_workspace_path: str,
) -> bool:
    if workspace_path == root_workspace_path:
        return True
    if root_workspace_path == "/":
        return workspace_path.startswith("/")
    return workspace_path.startswith(f"{root_workspace_path}/")


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
