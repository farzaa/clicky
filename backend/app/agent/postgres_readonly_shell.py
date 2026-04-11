import fnmatch
import posixpath
import re
import shlex
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import WorkspaceContentType, WorkspaceEntry, WorkspaceEntryType

READ_ONLY_ALLOWED_COMMAND_NAMES = {"pwd", "ls", "find", "cat", "grep", "rg"}
READ_ONLY_WRITE_COMMAND_NAMES = {
    "touch",
    "mkdir",
    "mktemp",
    "rm",
    "rmdir",
    "mv",
    "cp",
    "install",
    "chmod",
    "chown",
    "ln",
    "truncate",
    "tee",
    "dd",
}


@dataclass
class ReadOnlyShellExecutionResult:
    stdout: str
    stderr: str
    exit_code: int


@dataclass
class ReadOnlyShellRuntimeContext:
    workspace_id: UUID
    database_session: AsyncSession
    working_directory: str
    cached_text_content_by_path: dict[str, str]


async def execute_workspace_read_only_shell_script(
    *,
    workspace_id: UUID,
    database_session: AsyncSession,
    script: str,
    working_directory: str,
) -> ReadOnlyShellExecutionResult:
    stripped_script = script.strip()
    if not stripped_script:
        return ReadOnlyShellExecutionResult(stdout="", stderr="", exit_code=0)

    runtime_context = ReadOnlyShellRuntimeContext(
        workspace_id=workspace_id,
        database_session=database_session,
        working_directory=working_directory,
        cached_text_content_by_path={},
    )

    if any(token in stripped_script for token in ["\n", ";", "||", "<<", "`", "$("]):
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=(
                "read-only shell supports only simple commands joined with `&&`; "
                "complex shell syntax is disabled.\n"
            ),
            exit_code=2,
        )

    if "&" in stripped_script.replace("&&", ""):
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr="background execution is disabled in read-only mode.\n",
            exit_code=2,
        )

    command_parts = [script_part.strip() for script_part in stripped_script.split("&&")]
    if not command_parts or any(not command_part for command_part in command_parts):
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr="invalid command chain.\n",
            exit_code=2,
        )

    combined_stdout_parts: list[str] = []
    combined_stderr_parts: list[str] = []
    last_exit_code = 0

    for command_part in command_parts:
        try:
            command_tokens = shlex.split(command_part)
        except ValueError as error:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr=f"failed to parse command: {error}\n",
                exit_code=2,
            )

        if not command_tokens:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr="empty command is not allowed.\n",
                exit_code=2,
            )
        if "|" in command_tokens:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr="pipe syntax is disabled in read-only mode.\n",
                exit_code=2,
            )

        (
            command_tokens_without_redirection,
            should_suppress_stderr,
            had_write_redirection,
            has_unsupported_redirection,
        ) = _strip_supported_redirection_tokens(command_tokens)
        if has_unsupported_redirection:
            subcommand_result = ReadOnlyShellExecutionResult(
                stdout="",
                stderr="unsupported redirection syntax in read-only mode.\n",
                exit_code=2,
            )
        elif had_write_redirection:
            subcommand_result = _build_ero_fs_result(command_name=command_tokens[0])
        else:
            subcommand_result = await _execute_single_read_only_command(
                command_tokens=command_tokens_without_redirection,
                runtime_context=runtime_context,
            )

        if subcommand_result.stdout:
            combined_stdout_parts.append(subcommand_result.stdout)
        if subcommand_result.stderr and not should_suppress_stderr:
            combined_stderr_parts.append(subcommand_result.stderr)

        last_exit_code = subcommand_result.exit_code
        if last_exit_code != 0:
            break

    return ReadOnlyShellExecutionResult(
        stdout="".join(combined_stdout_parts),
        stderr="".join(combined_stderr_parts),
        exit_code=last_exit_code,
    )


def _strip_supported_redirection_tokens(
    command_tokens: list[str],
) -> tuple[list[str], bool, bool, bool]:
    command_tokens_without_redirection: list[str] = []
    token_index = 0
    should_suppress_stderr = False
    had_write_redirection = False
    has_unsupported_redirection = False

    while token_index < len(command_tokens):
        command_token = command_tokens[token_index]
        if command_token == "2>":
            if token_index + 1 >= len(command_tokens):
                has_unsupported_redirection = True
                break
            if command_tokens[token_index + 1] == "/dev/null":
                should_suppress_stderr = True
                token_index += 2
                continue
            had_write_redirection = True
            token_index += 2
            continue
        if command_token == "2>/dev/null":
            should_suppress_stderr = True
            token_index += 1
            continue
        if command_token in {"<", "<<", "<<<"}:
            has_unsupported_redirection = True
            break
        if command_token in {">", ">>", "1>", "1>>", "2>>", "&>", ">&"}:
            had_write_redirection = True
            if token_index + 1 < len(command_tokens):
                token_index += 2
            else:
                token_index += 1
            continue
        if command_token.startswith(">") or command_token.startswith("1>"):
            had_write_redirection = True
            token_index += 1
            continue
        if command_token.startswith("2>>") or command_token.startswith("&>"):
            had_write_redirection = True
            token_index += 1
            continue

        command_tokens_without_redirection.append(command_token)
        token_index += 1

    return (
        command_tokens_without_redirection,
        should_suppress_stderr,
        had_write_redirection,
        has_unsupported_redirection,
    )


async def _execute_single_read_only_command(
    *,
    command_tokens: list[str],
    runtime_context: ReadOnlyShellRuntimeContext,
) -> ReadOnlyShellExecutionResult:
    if not command_tokens:
        return ReadOnlyShellExecutionResult(stdout="", stderr="empty command.\n", exit_code=2)

    command_name = command_tokens[0]
    if command_name in READ_ONLY_WRITE_COMMAND_NAMES:
        return _build_ero_fs_result(command_name=command_name)

    if command_name not in READ_ONLY_ALLOWED_COMMAND_NAMES:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=(
                f"{command_name}: command is disabled in read-only PostgresFs. "
                "Allowed commands: pwd, ls, find, cat, grep, rg.\n"
            ),
            exit_code=127,
        )

    if command_name == "pwd":
        if len(command_tokens) != 1:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr="pwd: this implementation does not support flags.\n",
                exit_code=2,
            )
        return ReadOnlyShellExecutionResult(
            stdout=f"{runtime_context.working_directory}\n",
            stderr="",
            exit_code=0,
        )

    if command_name == "ls":
        return await _execute_read_only_ls(
            command_tokens=command_tokens,
            runtime_context=runtime_context,
        )

    if command_name == "find":
        return await _execute_read_only_find(
            command_tokens=command_tokens,
            runtime_context=runtime_context,
        )

    if command_name == "cat":
        return await _execute_read_only_cat(
            command_tokens=command_tokens,
            runtime_context=runtime_context,
        )

    if command_name in {"grep", "rg"}:
        return await _execute_read_only_grep_like_command(
            command_tokens=command_tokens,
            runtime_context=runtime_context,
            is_recursive_by_default=(command_name == "rg"),
        )

    return ReadOnlyShellExecutionResult(
        stdout="",
        stderr=f"{command_name}: command is not implemented.\n",
        exit_code=127,
    )


async def _execute_read_only_ls(
    *,
    command_tokens: list[str],
    runtime_context: ReadOnlyShellRuntimeContext,
) -> ReadOnlyShellExecutionResult:
    include_hidden_entries = False
    use_long_format = False
    target_path_argument: str | None = None

    for command_token in command_tokens[1:]:
        if command_token.startswith("-"):
            supported_option_letters = {"a", "A", "l", "h"}
            option_letters = set(command_token.lstrip("-"))
            if not option_letters.issubset(supported_option_letters):
                return ReadOnlyShellExecutionResult(
                    stdout="",
                    stderr=f"ls: unsupported option `{command_token}`.\n",
                    exit_code=2,
                )
            if "a" in option_letters or "A" in option_letters:
                include_hidden_entries = True
            if "l" in option_letters:
                use_long_format = True
            continue

        if target_path_argument is not None:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr="ls: this implementation accepts at most one path argument.\n",
                exit_code=2,
            )
        target_path_argument = command_token

    target_workspace_path = _resolve_workspace_path_argument(
        working_directory=runtime_context.working_directory,
        path_argument=target_path_argument or ".",
    )
    target_workspace_entry = await _get_workspace_entry_by_path(
        workspace_id=runtime_context.workspace_id,
        entry_path=target_workspace_path,
        database_session=runtime_context.database_session,
    )
    if target_workspace_entry is None:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"ls: cannot access '{target_path_argument or '.'}': No such file or directory\n",
            exit_code=1,
        )

    if target_workspace_entry.entry_type == WorkspaceEntryType.file:
        return ReadOnlyShellExecutionResult(
            stdout=_format_ls_entry(
                workspace_entry=target_workspace_entry,
                use_long_format=use_long_format,
            )
            + "\n",
            stderr="",
            exit_code=0,
        )

    child_workspace_entries = await _get_workspace_entry_children(
        workspace_id=runtime_context.workspace_id,
        parent_entry_id=target_workspace_entry.id,
        database_session=runtime_context.database_session,
    )
    visible_workspace_entries = [
        workspace_entry
        for workspace_entry in child_workspace_entries
        if include_hidden_entries or not workspace_entry.entry_name.startswith(".")
    ]
    visible_workspace_entries.sort(
        key=lambda workspace_entry: (
            0 if workspace_entry.entry_type == WorkspaceEntryType.directory else 1,
            workspace_entry.entry_name.lower(),
        )
    )

    stdout_lines: list[str] = []
    if include_hidden_entries:
        synthetic_entries = [
            (".", WorkspaceEntryType.directory, 0),
            ("..", WorkspaceEntryType.directory, 0),
        ]
        for entry_name, entry_type, entry_size in synthetic_entries:
            if use_long_format:
                entry_prefix = "d" if entry_type == WorkspaceEntryType.directory else "-"
                stdout_lines.append(f"{entry_prefix} {entry_size:>8} {entry_name}")
            else:
                stdout_lines.append(entry_name)

    stdout_lines.extend(
        _format_ls_entry(workspace_entry=workspace_entry, use_long_format=use_long_format)
        for workspace_entry in visible_workspace_entries
    )
    return ReadOnlyShellExecutionResult(
        stdout=("\n".join(stdout_lines) + "\n") if stdout_lines else "",
        stderr="",
        exit_code=0,
    )


async def _execute_read_only_find(
    *,
    command_tokens: list[str],
    runtime_context: ReadOnlyShellRuntimeContext,
) -> ReadOnlyShellExecutionResult:
    search_root_argument = "."
    max_depth: int | None = None
    name_glob_pattern: str | None = None
    token_index = 1

    if token_index < len(command_tokens) and not command_tokens[token_index].startswith("-"):
        search_root_argument = command_tokens[token_index]
        token_index += 1

    while token_index < len(command_tokens):
        command_token = command_tokens[token_index]
        if command_token == "-maxdepth" and token_index + 1 < len(command_tokens):
            try:
                max_depth = int(command_tokens[token_index + 1])
            except ValueError:
                return ReadOnlyShellExecutionResult(
                    stdout="",
                    stderr=f"find: invalid max depth `{command_tokens[token_index + 1]}`.\n",
                    exit_code=2,
                )
            token_index += 2
            continue
        if command_token == "-name" and token_index + 1 < len(command_tokens):
            name_glob_pattern = command_tokens[token_index + 1]
            token_index += 2
            continue
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"find: unsupported argument `{command_token}`.\n",
            exit_code=2,
        )

    search_root_path = _resolve_workspace_path_argument(
        working_directory=runtime_context.working_directory,
        path_argument=search_root_argument,
    )
    search_root_entry = await _get_workspace_entry_by_path(
        workspace_id=runtime_context.workspace_id,
        entry_path=search_root_path,
        database_session=runtime_context.database_session,
    )
    if search_root_entry is None:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"find: '{search_root_argument}': No such file or directory\n",
            exit_code=1,
        )

    root_depth = _workspace_path_depth(search_root_path)
    candidate_workspace_entries = await _list_workspace_entries_under_root(
        workspace_id=runtime_context.workspace_id,
        root_workspace_path=search_root_path,
        database_session=runtime_context.database_session,
    )

    matched_workspace_paths: list[str] = []
    for workspace_entry in candidate_workspace_entries:
        relative_depth = _workspace_path_depth(workspace_entry.entry_path) - root_depth
        if max_depth is not None and relative_depth > max_depth:
            continue
        if name_glob_pattern is not None and not fnmatch.fnmatch(
            workspace_entry.entry_name,
            name_glob_pattern,
        ):
            continue
        matched_workspace_paths.append(workspace_entry.entry_path)

    return ReadOnlyShellExecutionResult(
        stdout=("\n".join(matched_workspace_paths) + "\n") if matched_workspace_paths else "",
        stderr="",
        exit_code=0,
    )


async def _execute_read_only_cat(
    *,
    command_tokens: list[str],
    runtime_context: ReadOnlyShellRuntimeContext,
) -> ReadOnlyShellExecutionResult:
    if len(command_tokens) != 2:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr="cat: this implementation accepts exactly one file path.\n",
            exit_code=2,
        )

    target_path_argument = command_tokens[1]
    target_workspace_path = _resolve_workspace_path_argument(
        working_directory=runtime_context.working_directory,
        path_argument=target_path_argument,
    )
    target_workspace_entry = await _get_workspace_entry_by_path(
        workspace_id=runtime_context.workspace_id,
        entry_path=target_workspace_path,
        database_session=runtime_context.database_session,
    )
    if target_workspace_entry is None:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: No such file or directory\n",
            exit_code=1,
        )
    if target_workspace_entry.entry_type != WorkspaceEntryType.file:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: Is a directory\n",
            exit_code=1,
        )

    text_content = await _load_workspace_file_text_content_for_read(
        workspace_entry=target_workspace_entry,
        runtime_context=runtime_context,
    )
    if text_content is None:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"cat: {target_path_argument}: Binary content is not supported in read-only mode\n",
            exit_code=1,
        )

    if text_content and not text_content.endswith("\n"):
        text_content += "\n"
    return ReadOnlyShellExecutionResult(
        stdout=text_content,
        stderr="",
        exit_code=0,
    )


async def _execute_read_only_grep_like_command(
    *,
    command_tokens: list[str],
    runtime_context: ReadOnlyShellRuntimeContext,
    is_recursive_by_default: bool,
) -> ReadOnlyShellExecutionResult:
    should_ignore_case = False
    should_include_line_numbers = False
    should_search_recursively = is_recursive_by_default
    positional_arguments: list[str] = []

    for command_token in command_tokens[1:]:
        if command_token.startswith("-") and command_token != "-":
            if command_token in {"-i", "--ignore-case"}:
                should_ignore_case = True
                continue
            if command_token in {"-n", "--line-number"}:
                should_include_line_numbers = True
                continue
            if command_token in {"-r", "-R"}:
                should_search_recursively = True
                continue
            if command_token in {"-F", "--fixed-strings"}:
                positional_arguments.append(command_token)
                continue

            if command_token.startswith("--"):
                return ReadOnlyShellExecutionResult(
                    stdout="",
                    stderr=f"{command_tokens[0]}: unsupported option `{command_token}`.\n",
                    exit_code=2,
                )

            option_letters = command_token.lstrip("-")
            if not option_letters or not set(option_letters).issubset({"i", "n", "r", "R"}):
                return ReadOnlyShellExecutionResult(
                    stdout="",
                    stderr=f"{command_tokens[0]}: unsupported option `{command_token}`.\n",
                    exit_code=2,
                )
            if "i" in option_letters:
                should_ignore_case = True
            if "n" in option_letters:
                should_include_line_numbers = True
            if "r" in option_letters or "R" in option_letters:
                should_search_recursively = True
            continue

        positional_arguments.append(command_token)

    force_fixed_string_mode = False
    if positional_arguments and positional_arguments[0] in {"-F", "--fixed-strings"}:
        force_fixed_string_mode = True
        positional_arguments = positional_arguments[1:]

    if not positional_arguments or len(positional_arguments) > 2:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=(
                f"{command_tokens[0]}: expected pattern and optional path. "
                "Example: grep -n 'token' /docs\n"
            ),
            exit_code=2,
        )

    raw_pattern = positional_arguments[0]
    search_root_argument = positional_arguments[1] if len(positional_arguments) == 2 else "."
    regex_pattern = re.escape(raw_pattern) if force_fixed_string_mode else raw_pattern
    regex_flags = re.IGNORECASE if should_ignore_case else 0
    try:
        compiled_pattern = re.compile(regex_pattern, regex_flags)
    except re.error as error:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=f"{command_tokens[0]}: invalid regex `{raw_pattern}`: {error}\n",
            exit_code=2,
        )

    search_root_path = _resolve_workspace_path_argument(
        working_directory=runtime_context.working_directory,
        path_argument=search_root_argument,
    )
    search_root_entry = await _get_workspace_entry_by_path(
        workspace_id=runtime_context.workspace_id,
        entry_path=search_root_path,
        database_session=runtime_context.database_session,
    )
    if search_root_entry is None:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr=(
                f"{command_tokens[0]}: {search_root_argument}: "
                "No such file or directory\n"
            ),
            exit_code=2,
        )

    searchable_workspace_entries: list[WorkspaceEntry]
    if search_root_entry.entry_type == WorkspaceEntryType.file:
        searchable_workspace_entries = [search_root_entry]
    else:
        if not should_search_recursively:
            return ReadOnlyShellExecutionResult(
                stdout="",
                stderr=f"{command_tokens[0]}: {search_root_argument}: Is a directory\n",
                exit_code=2,
            )
        searchable_workspace_entries = await _list_candidate_workspace_text_files_for_grep(
            workspace_id=runtime_context.workspace_id,
            root_workspace_path=search_root_path,
            raw_pattern=raw_pattern,
            should_ignore_case=should_ignore_case,
            force_fixed_string_mode=force_fixed_string_mode,
            database_session=runtime_context.database_session,
        )

    should_prefix_with_path = (
        len(searchable_workspace_entries) > 1
        or search_root_entry.entry_type == WorkspaceEntryType.directory
    )
    matched_output_lines: list[str] = []
    for searchable_workspace_entry in searchable_workspace_entries:
        text_content = await _load_workspace_file_text_content_for_read(
            workspace_entry=searchable_workspace_entry,
            runtime_context=runtime_context,
        )
        if text_content is None:
            continue
        matched_output_lines.extend(
            _build_grep_output_lines_for_file(
                entry_path=searchable_workspace_entry.entry_path,
                text_content=text_content,
                compiled_pattern=compiled_pattern,
                should_include_line_numbers=should_include_line_numbers,
                should_prefix_with_path=should_prefix_with_path,
            )
        )

    if not matched_output_lines:
        return ReadOnlyShellExecutionResult(
            stdout="",
            stderr="",
            exit_code=1,
        )

    return ReadOnlyShellExecutionResult(
        stdout="\n".join(matched_output_lines) + "\n",
        stderr="",
        exit_code=0,
    )


def _build_grep_output_lines_for_file(
    *,
    entry_path: str,
    text_content: str,
    compiled_pattern: re.Pattern[str],
    should_include_line_numbers: bool,
    should_prefix_with_path: bool,
) -> list[str]:
    matched_output_lines: list[str] = []
    for line_number, content_line in enumerate(text_content.splitlines(), start=1):
        if compiled_pattern.search(content_line) is None:
            continue

        output_prefix_parts: list[str] = []
        if should_prefix_with_path:
            output_prefix_parts.append(entry_path)
        if should_include_line_numbers:
            output_prefix_parts.append(str(line_number))

        if output_prefix_parts:
            matched_output_lines.append(":".join(output_prefix_parts) + f":{content_line}")
        else:
            matched_output_lines.append(content_line)

    return matched_output_lines


async def _load_workspace_file_text_content_for_read(
    *,
    workspace_entry: WorkspaceEntry,
    runtime_context: ReadOnlyShellRuntimeContext,
) -> str | None:
    cached_text_content = runtime_context.cached_text_content_by_path.get(
        workspace_entry.entry_path
    )
    if cached_text_content is not None:
        return cached_text_content

    if workspace_entry.text_content is not None:
        runtime_context.cached_text_content_by_path[workspace_entry.entry_path] = (
            workspace_entry.text_content
        )
        return workspace_entry.text_content

    chunk_metadata = workspace_entry.entry_metadata or {}
    if not isinstance(chunk_metadata, dict):
        return None

    chunk_entry_paths = chunk_metadata.get("chunk_entry_paths")
    if isinstance(chunk_entry_paths, list):
        reconstructed_content = await _reconstruct_file_from_explicit_chunk_paths(
            workspace_id=runtime_context.workspace_id,
            chunk_entry_paths=chunk_entry_paths,
            database_session=runtime_context.database_session,
        )
        if reconstructed_content is not None:
            runtime_context.cached_text_content_by_path[workspace_entry.entry_path] = (
                reconstructed_content
            )
        return reconstructed_content

    chunk_parent_entry_path = chunk_metadata.get("chunk_parent_entry_path")
    if isinstance(chunk_parent_entry_path, str) and chunk_parent_entry_path.strip():
        reconstructed_content = await _reconstruct_file_from_chunk_directory(
            workspace_id=runtime_context.workspace_id,
            chunk_parent_entry_path=_normalize_workspace_path(chunk_parent_entry_path),
            database_session=runtime_context.database_session,
        )
        if reconstructed_content is not None:
            runtime_context.cached_text_content_by_path[workspace_entry.entry_path] = (
                reconstructed_content
            )
        return reconstructed_content

    return None


async def _reconstruct_file_from_explicit_chunk_paths(
    *,
    workspace_id: UUID,
    chunk_entry_paths: list[Any],
    database_session: AsyncSession,
) -> str | None:
    normalized_chunk_entry_paths = [
        _normalize_workspace_path(chunk_entry_path)
        for chunk_entry_path in chunk_entry_paths
        if isinstance(chunk_entry_path, str) and chunk_entry_path.strip()
    ]
    if not normalized_chunk_entry_paths:
        return None

    chunk_entries_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.file,
            WorkspaceEntry.entry_path.in_(normalized_chunk_entry_paths),
        )
    )
    chunk_entries = list((await database_session.execute(chunk_entries_query)).scalars().all())
    chunk_entries_by_path = {
        chunk_entry.entry_path: chunk_entry for chunk_entry in chunk_entries
    }

    reconstructed_parts: list[str] = []
    for chunk_entry_path in normalized_chunk_entry_paths:
        chunk_entry = chunk_entries_by_path.get(chunk_entry_path)
        if chunk_entry is None or chunk_entry.text_content is None:
            return None
        reconstructed_parts.append(chunk_entry.text_content)
    return "".join(reconstructed_parts)


async def _reconstruct_file_from_chunk_directory(
    *,
    workspace_id: UUID,
    chunk_parent_entry_path: str,
    database_session: AsyncSession,
) -> str | None:
    chunk_entries_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.file,
            WorkspaceEntry.entry_path.like(f"{chunk_parent_entry_path}/%"),
        )
    )
    chunk_entries = list((await database_session.execute(chunk_entries_query)).scalars().all())
    if not chunk_entries:
        return None

    chunk_entries.sort(
        key=lambda chunk_entry: (
            _extract_chunk_index_from_metadata(chunk_entry.entry_metadata),
            chunk_entry.entry_name.lower(),
        )
    )

    reconstructed_parts: list[str] = []
    for chunk_entry in chunk_entries:
        if chunk_entry.text_content is None:
            return None
        reconstructed_parts.append(chunk_entry.text_content)
    return "".join(reconstructed_parts)


def _extract_chunk_index_from_metadata(entry_metadata: Any) -> int:
    if not isinstance(entry_metadata, dict):
        return 10**9
    chunk_index_value = entry_metadata.get("chunk_index")
    if isinstance(chunk_index_value, int):
        return chunk_index_value
    return 10**9


async def _list_candidate_workspace_text_files_for_grep(
    *,
    workspace_id: UUID,
    root_workspace_path: str,
    raw_pattern: str,
    should_ignore_case: bool,
    force_fixed_string_mode: bool,
    database_session: AsyncSession,
) -> list[WorkspaceEntry]:
    root_workspace_path_prefix = (
        "/%" if root_workspace_path == "/" else f"{root_workspace_path}/%"
    )
    candidate_workspace_entries_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_type == WorkspaceEntryType.file,
            or_(
                WorkspaceEntry.entry_path == root_workspace_path,
                WorkspaceEntry.entry_path.like(root_workspace_path_prefix),
            ),
            or_(
                WorkspaceEntry.content_type.in_(
                    [WorkspaceContentType.text, WorkspaceContentType.markdown]
                ),
                WorkspaceEntry.text_content.is_not(None),
            ),
        )
    )

    coarse_literal_hint = _derive_coarse_filter_literal_from_pattern(
        raw_pattern=raw_pattern,
        force_fixed_string_mode=force_fixed_string_mode,
    )
    if coarse_literal_hint:
        escaped_coarse_literal_hint = (
            coarse_literal_hint.replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")
        )
        coarse_sql_like_value = f"%{escaped_coarse_literal_hint}%"
        if should_ignore_case:
            candidate_workspace_entries_query = candidate_workspace_entries_query.where(
                WorkspaceEntry.text_content.ilike(coarse_sql_like_value, escape="\\")
            )
        else:
            candidate_workspace_entries_query = candidate_workspace_entries_query.where(
                WorkspaceEntry.text_content.like(coarse_sql_like_value, escape="\\")
            )

    candidate_workspace_entries = list(
        (await database_session.execute(candidate_workspace_entries_query)).scalars().all()
    )
    candidate_workspace_entries.sort(key=lambda workspace_entry: workspace_entry.entry_path)
    return candidate_workspace_entries


def _derive_coarse_filter_literal_from_pattern(
    *,
    raw_pattern: str,
    force_fixed_string_mode: bool,
) -> str | None:
    if force_fixed_string_mode:
        return raw_pattern

    regex_meta_characters = set(r".^$*+?{}[]\|()")
    return raw_pattern if not any(character in regex_meta_characters for character in raw_pattern) else None


async def _get_workspace_entry_by_path(
    *,
    workspace_id: UUID,
    entry_path: str,
    database_session: AsyncSession,
) -> WorkspaceEntry | None:
    workspace_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_path == entry_path,
        )
    )
    return (await database_session.execute(workspace_entry_query)).scalar_one_or_none()


async def _get_workspace_entry_children(
    *,
    workspace_id: UUID,
    parent_entry_id: UUID,
    database_session: AsyncSession,
) -> list[WorkspaceEntry]:
    workspace_children_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.parent_entry_id == parent_entry_id,
        )
    )
    return list((await database_session.execute(workspace_children_query)).scalars().all())


async def _list_workspace_entries_under_root(
    *,
    workspace_id: UUID,
    root_workspace_path: str,
    database_session: AsyncSession,
) -> list[WorkspaceEntry]:
    root_workspace_path_prefix = (
        "/%" if root_workspace_path == "/" else f"{root_workspace_path}/%"
    )
    workspace_entries_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            or_(
                WorkspaceEntry.entry_path == root_workspace_path,
                WorkspaceEntry.entry_path.like(root_workspace_path_prefix),
            ),
        )
    )
    workspace_entries = list((await database_session.execute(workspace_entries_query)).scalars().all())
    workspace_entries.sort(key=lambda workspace_entry: workspace_entry.entry_path)
    return workspace_entries


def _resolve_workspace_path_argument(
    *,
    working_directory: str,
    path_argument: str,
) -> str:
    if not path_argument.strip():
        return working_directory
    if path_argument.startswith("/"):
        return _normalize_workspace_path(path_argument)
    return _normalize_workspace_path(
        posixpath.normpath(posixpath.join(working_directory, path_argument))
    )


def _normalize_workspace_path(path_value: str) -> str:
    normalized_workspace_path = "/" + path_value.strip().strip("/")
    if normalized_workspace_path in {"", "/"}:
        return "/"
    normalized_workspace_path = posixpath.normpath(normalized_workspace_path)
    return "/" if normalized_workspace_path in {".", "/"} else normalized_workspace_path


def _workspace_path_depth(entry_path: str) -> int:
    if entry_path == "/":
        return 0
    return len([entry_path_part for entry_path_part in entry_path.split("/") if entry_path_part])


def _format_ls_entry(*, workspace_entry: WorkspaceEntry, use_long_format: bool) -> str:
    if not use_long_format:
        return workspace_entry.entry_name

    entry_prefix = "d" if workspace_entry.entry_type == WorkspaceEntryType.directory else "-"
    entry_size = workspace_entry.size_bytes or 0
    return f"{entry_prefix} {entry_size:>8} {workspace_entry.entry_name}"


def _build_ero_fs_result(*, command_name: str) -> ReadOnlyShellExecutionResult:
    return ReadOnlyShellExecutionResult(
        stdout="",
        stderr=(
            f"{command_name}: EROFS: Read-only filesystem. "
            "Write operations are disabled.\n"
        ),
        exit_code=30,
    )
