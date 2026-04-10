import base64
import hashlib
import mimetypes
from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_database_session
from app.models import (
    User,
    WorkspaceContentType,
    WorkspaceEntry,
    WorkspaceEntryType,
    Workspace,
    WorkspaceLaunchState,
    WorkspaceMembership,
    WorkspaceMembershipRole,
)
from app.workspaces_service import create_workspace_for_user

workspaces_router = APIRouter(prefix="/workspaces", tags=["workspaces"])


class CreateWorkspaceRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=255)
    description: str | None = Field(default=None, max_length=5000)
    workspace_metadata: dict = Field(default_factory=dict)


class WorkspaceResponse(BaseModel):
    id: str
    display_name: str
    description: str | None = None
    launch_state: str
    launched_at: datetime | None = None
    last_opened_at: datetime | None = None
    membership_role: str
    workspace_metadata: dict


class WorkspaceEntryResponse(BaseModel):
    id: str
    workspace_id: str
    entry_name: str
    entry_path: str
    entry_type: str
    content_type: str | None = None
    mime_type: str | None = None
    size_bytes: int | None = None
    content_sha256: str | None = None
    entry_metadata: dict


class WorkspaceFileReadResponse(WorkspaceEntryResponse):
    has_binary_content: bool
    text_content: str | None = None
    binary_content_base64: str | None = None


class WorkspaceEntriesListResponse(BaseModel):
    workspace_id: str
    parent_entry_path: str
    entries: list[WorkspaceEntryResponse]


def build_workspace_response(
    workspace: Workspace,
    membership_role: WorkspaceMembershipRole,
) -> WorkspaceResponse:
    return WorkspaceResponse(
        id=str(workspace.id),
        display_name=workspace.display_name,
        description=workspace.description,
        launch_state=workspace.launch_state.value,
        launched_at=workspace.launched_at,
        last_opened_at=workspace.last_opened_at,
        membership_role=membership_role.value,
        workspace_metadata=workspace.workspace_metadata,
    )


def build_workspace_entry_response(
    workspace_entry: WorkspaceEntry,
) -> WorkspaceEntryResponse:
    return WorkspaceEntryResponse(
        id=str(workspace_entry.id),
        workspace_id=str(workspace_entry.workspace_id),
        entry_name=workspace_entry.entry_name,
        entry_path=workspace_entry.entry_path,
        entry_type=workspace_entry.entry_type.value,
        content_type=workspace_entry.content_type.value
        if workspace_entry.content_type
        else None,
        mime_type=workspace_entry.mime_type,
        size_bytes=workspace_entry.size_bytes,
        content_sha256=workspace_entry.content_sha256,
        entry_metadata=workspace_entry.entry_metadata,
    )


def build_workspace_file_read_response(
    workspace_entry: WorkspaceEntry,
) -> WorkspaceFileReadResponse:
    return WorkspaceFileReadResponse(
        **build_workspace_entry_response(workspace_entry).model_dump(),
        has_binary_content=workspace_entry.binary_content is not None,
        text_content=workspace_entry.text_content,
        binary_content_base64=base64.b64encode(workspace_entry.binary_content).decode("ascii")
        if workspace_entry.binary_content is not None
        else None,
    )


async def get_accessible_workspace_membership(
    workspace_id: UUID,
    current_user: User,
    database_session: AsyncSession,
) -> WorkspaceMembership:
    workspace_membership_query = select(WorkspaceMembership).where(
        and_(
            WorkspaceMembership.workspace_id == workspace_id,
            WorkspaceMembership.user_id == current_user.id,
        ),
    )
    workspace_membership = (
        await database_session.execute(workspace_membership_query)
    ).scalar_one_or_none()

    if workspace_membership is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )

    return workspace_membership


def normalize_workspace_entry_path(entry_path: str) -> str:
    if not entry_path.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="`entry_path` must be a non-empty path.",
        )

    normalized_workspace_entry_path = "/" + entry_path.strip().strip("/")
    return "/" if normalized_workspace_entry_path == "/" else normalized_workspace_entry_path


def require_workspace_write_access(
    workspace_membership: WorkspaceMembership,
) -> None:
    if workspace_membership.role == WorkspaceMembershipRole.viewer:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This workspace is read-only for the current user.",
        )


async def get_workspace_entry_by_path(
    workspace_id: UUID,
    entry_path: str,
    database_session: AsyncSession,
) -> WorkspaceEntry | None:
    workspace_entry_query = select(WorkspaceEntry).where(
        and_(
            WorkspaceEntry.workspace_id == workspace_id,
            WorkspaceEntry.entry_path == entry_path,
        ),
    )
    return (await database_session.execute(workspace_entry_query)).scalar_one_or_none()


async def ensure_workspace_directory_exists(
    *,
    workspace_id: UUID,
    directory_path: str,
    current_user: User,
    database_session: AsyncSession,
) -> WorkspaceEntry:
    normalized_directory_path = normalize_workspace_entry_path(directory_path)
    root_workspace_entry = await get_workspace_entry_by_path(
        workspace_id,
        "/",
        database_session,
    )
    if root_workspace_entry is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Workspace root directory is missing.",
        )

    if normalized_directory_path == "/":
        return root_workspace_entry

    current_workspace_entry = root_workspace_entry
    current_workspace_path = ""
    for path_component in normalized_directory_path.strip("/").split("/"):
        current_workspace_path = f"{current_workspace_path}/{path_component}"
        existing_workspace_entry = await get_workspace_entry_by_path(
            workspace_id,
            current_workspace_path,
            database_session,
        )
        if existing_workspace_entry is None:
            existing_workspace_entry = WorkspaceEntry(
                workspace_id=workspace_id,
                parent_entry_id=current_workspace_entry.id,
                created_by_user_id=current_user.id,
                entry_name=path_component,
                entry_path=current_workspace_path,
                entry_type=WorkspaceEntryType.directory,
                entry_metadata={},
            )
            database_session.add(existing_workspace_entry)
            await database_session.flush()
        elif existing_workspace_entry.entry_type != WorkspaceEntryType.directory:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"`{current_workspace_path}` already exists and is not a directory.",
            )

        current_workspace_entry = existing_workspace_entry

    return current_workspace_entry


def infer_workspace_upload_storage(
    *,
    entry_path: str,
    provided_content_type: WorkspaceContentType | None,
    provided_mime_type: str | None,
    file_bytes: bytes,
) -> tuple[WorkspaceContentType, str | None, str | None, bytes | None]:
    inferred_mime_type = provided_mime_type or mimetypes.guess_type(entry_path)[0]

    try:
        text_content = file_bytes.decode("utf-8")
        is_utf8_text = True
    except UnicodeDecodeError:
        text_content = None
        is_utf8_text = False

    if provided_content_type is not None:
        if provided_content_type in {WorkspaceContentType.text, WorkspaceContentType.markdown}:
            if not is_utf8_text:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=(
                        f"`{entry_path}` could not be decoded as UTF-8 for "
                        f"content type `{provided_content_type.value}`."
                    ),
                )
            final_mime_type = inferred_mime_type or (
                "text/markdown"
                if provided_content_type == WorkspaceContentType.markdown
                else "text/plain"
            )
            return provided_content_type, final_mime_type, text_content, None

        return provided_content_type, inferred_mime_type, None, file_bytes

    if is_utf8_text:
        inferred_content_type = (
            WorkspaceContentType.markdown
            if entry_path.endswith(".md") or entry_path.endswith(".markdown")
            else WorkspaceContentType.text
        )
        final_mime_type = inferred_mime_type or (
            "text/markdown"
            if inferred_content_type == WorkspaceContentType.markdown
            else "text/plain"
        )
        return inferred_content_type, final_mime_type, text_content, None

    if inferred_mime_type == "application/pdf" or entry_path.endswith(".pdf"):
        return WorkspaceContentType.pdf, inferred_mime_type or "application/pdf", None, file_bytes
    if inferred_mime_type and inferred_mime_type.startswith("image/"):
        return WorkspaceContentType.image, inferred_mime_type, None, file_bytes

    return WorkspaceContentType.other, inferred_mime_type, None, file_bytes


@workspaces_router.post(
    "/",
    response_model=WorkspaceResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_workspace(
    create_workspace_request: CreateWorkspaceRequest,
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceResponse:
    workspace = await create_workspace_for_user(
        database_session,
        user=current_user,
        display_name=create_workspace_request.display_name,
        description=create_workspace_request.description,
        workspace_metadata=create_workspace_request.workspace_metadata,
    )
    await database_session.commit()
    await database_session.refresh(workspace)

    return build_workspace_response(workspace, WorkspaceMembershipRole.owner)


@workspaces_router.get("/", response_model=list[WorkspaceResponse])
async def list_workspaces(
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> list[WorkspaceResponse]:
    workspace_query = (
        select(Workspace, WorkspaceMembership.role)
        .join(WorkspaceMembership, WorkspaceMembership.workspace_id == Workspace.id)
        .where(WorkspaceMembership.user_id == current_user.id)
        .order_by(Workspace.updated_at.desc())
    )
    workspace_rows = (await database_session.execute(workspace_query)).all()

    return [
        build_workspace_response(workspace, membership_role)
        for workspace, membership_role in workspace_rows
    ]


@workspaces_router.get("/{workspace_id}", response_model=WorkspaceResponse)
async def get_workspace(
    workspace_id: UUID,
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceResponse:
    workspace_membership = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    workspace = await database_session.get(Workspace, workspace_membership.workspace_id)

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )

    return build_workspace_response(workspace, workspace_membership.role)


@workspaces_router.post("/{workspace_id}/launch", response_model=WorkspaceResponse)
async def launch_workspace(
    workspace_id: UUID,
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceResponse:
    workspace_membership = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    workspace = await database_session.get(Workspace, workspace_membership.workspace_id)

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )

    current_datetime = datetime.now(UTC)
    workspace.launch_state = WorkspaceLaunchState.running
    workspace.launched_at = current_datetime
    workspace.last_opened_at = current_datetime
    await database_session.commit()
    await database_session.refresh(workspace)

    return build_workspace_response(workspace, workspace_membership.role)


@workspaces_router.post("/{workspace_id}/stop", response_model=WorkspaceResponse)
async def stop_workspace(
    workspace_id: UUID,
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceResponse:
    workspace_membership = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    workspace = await database_session.get(Workspace, workspace_membership.workspace_id)

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )

    workspace.launch_state = WorkspaceLaunchState.stopped
    await database_session.commit()
    await database_session.refresh(workspace)

    return build_workspace_response(workspace, workspace_membership.role)


@workspaces_router.post(
    "/{workspace_id}/entries/upload",
    response_model=WorkspaceEntryResponse,
    status_code=status.HTTP_201_CREATED,
)
async def upload_workspace_file(
    workspace_id: UUID,
    entry_path: str = Form(...),
    file: UploadFile = File(...),
    content_type: WorkspaceContentType | None = Form(default=None),
    mime_type: str | None = Form(default=None),
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceEntryResponse:
    workspace_membership = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    require_workspace_write_access(workspace_membership)

    normalized_entry_path = normalize_workspace_entry_path(entry_path)
    if normalized_entry_path == "/":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The root path cannot be used for file upload.",
        )

    file_bytes = await file.read()
    parent_directory_path = normalized_entry_path.rsplit("/", 1)[0] or "/"
    parent_workspace_entry = await ensure_workspace_directory_exists(
        workspace_id=workspace_id,
        directory_path=parent_directory_path,
        current_user=current_user,
        database_session=database_session,
    )
    existing_workspace_entry = await get_workspace_entry_by_path(
        workspace_id,
        normalized_entry_path,
        database_session,
    )
    if existing_workspace_entry is not None and existing_workspace_entry.entry_type != WorkspaceEntryType.file:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{normalized_entry_path}` already exists and is not a file.",
        )

    inferred_content_type, final_mime_type, text_content, binary_content = (
        infer_workspace_upload_storage(
            entry_path=normalized_entry_path,
            provided_content_type=content_type,
            provided_mime_type=mime_type or file.content_type,
            file_bytes=file_bytes,
        )
    )
    entry_name = normalized_entry_path.rsplit("/", 1)[-1]
    content_sha256 = hashlib.sha256(file_bytes).hexdigest()

    if existing_workspace_entry is None:
        existing_workspace_entry = WorkspaceEntry(
            workspace_id=workspace_id,
            parent_entry_id=parent_workspace_entry.id,
            created_by_user_id=current_user.id,
            entry_name=entry_name,
            entry_path=normalized_entry_path,
            entry_type=WorkspaceEntryType.file,
            content_type=inferred_content_type,
            mime_type=final_mime_type,
            size_bytes=len(file_bytes),
            content_sha256=content_sha256,
            text_content=text_content,
            binary_content=binary_content,
            entry_metadata={},
        )
        database_session.add(existing_workspace_entry)
    else:
        existing_workspace_entry.parent_entry_id = parent_workspace_entry.id
        existing_workspace_entry.entry_name = entry_name
        existing_workspace_entry.entry_type = WorkspaceEntryType.file
        existing_workspace_entry.content_type = inferred_content_type
        existing_workspace_entry.mime_type = final_mime_type
        existing_workspace_entry.size_bytes = len(file_bytes)
        existing_workspace_entry.content_sha256 = content_sha256
        existing_workspace_entry.text_content = text_content
        existing_workspace_entry.binary_content = binary_content
        existing_workspace_entry.entry_metadata = existing_workspace_entry.entry_metadata or {}

    await database_session.commit()
    await database_session.refresh(existing_workspace_entry)

    return build_workspace_entry_response(existing_workspace_entry)


@workspaces_router.get(
    "/{workspace_id}/entries/read",
    response_model=WorkspaceFileReadResponse,
)
async def read_workspace_file(
    workspace_id: UUID,
    entry_path: str = Query(...),
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceFileReadResponse:
    _ = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    normalized_entry_path = normalize_workspace_entry_path(entry_path)
    workspace_entry = await get_workspace_entry_by_path(
        workspace_id,
        normalized_entry_path,
        database_session,
    )
    if workspace_entry is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace entry not found.",
        )
    if workspace_entry.entry_type != WorkspaceEntryType.file:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{normalized_entry_path}` is not a file.",
        )

    return build_workspace_file_read_response(workspace_entry)


@workspaces_router.get(
    "/{workspace_id}/entries",
    response_model=WorkspaceEntriesListResponse,
)
async def list_workspace_entries(
    workspace_id: UUID,
    parent_entry_path: str = Query(default="/"),
    current_user: User = Depends(get_current_user),
    database_session: AsyncSession = Depends(get_database_session),
) -> WorkspaceEntriesListResponse:
    _ = await get_accessible_workspace_membership(
        workspace_id,
        current_user,
        database_session,
    )
    normalized_parent_entry_path = normalize_workspace_entry_path(parent_entry_path)
    parent_workspace_entry = await get_workspace_entry_by_path(
        workspace_id,
        normalized_parent_entry_path,
        database_session,
    )
    if parent_workspace_entry is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Parent path `{normalized_parent_entry_path}` was not found.",
        )
    if parent_workspace_entry.entry_type != WorkspaceEntryType.directory:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"`{normalized_parent_entry_path}` is not a directory.",
        )

    child_workspace_entries_query = (
        select(WorkspaceEntry)
        .where(
            and_(
                WorkspaceEntry.workspace_id == workspace_id,
                WorkspaceEntry.parent_entry_id == parent_workspace_entry.id,
            )
        )
        .order_by(WorkspaceEntry.entry_type.asc(), WorkspaceEntry.entry_name.asc())
    )
    child_workspace_entries = list(
        (await database_session.execute(child_workspace_entries_query)).scalars().all()
    )

    return WorkspaceEntriesListResponse(
        workspace_id=str(workspace_id),
        parent_entry_path=normalized_parent_entry_path,
        entries=[
            build_workspace_entry_response(workspace_entry)
            for workspace_entry in child_workspace_entries
        ],
    )
