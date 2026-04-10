from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_database_session
from app.models import (
    User,
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
