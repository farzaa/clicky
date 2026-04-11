from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_database_session
from app.models import (
    AuthSession,
    Course,
    LearnerObservation,
    LearnerTopicMastery,
    User,
    Workspace,
    WorkspaceEntry,
    WorkspaceMembership,
)
from app.security import (
    create_password_hash,
    create_session_expiration_datetime,
    create_session_token,
    hash_session_token,
    normalize_email_address,
    verify_password,
)
from app.workspaces_router import upload_workspace_file
from app.workspaces_service import create_workspace_for_user

webui_router = APIRouter(tags=["webui"])
templates = Jinja2Templates(directory=str(Path(__file__).resolve().parent / "templates"))

WEB_SESSION_COOKIE_NAME = "deb_web_session"
WEB_SESSION_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 30


async def _resolve_web_session_user(
    request: Request,
    database_session: AsyncSession,
) -> User | None:
    raw_session_token = request.cookies.get(WEB_SESSION_COOKIE_NAME)
    if not raw_session_token:
        return None

    session_token_hash = hash_session_token(raw_session_token)
    auth_session_query = (
        select(AuthSession)
        .options(selectinload(AuthSession.user))
        .where(AuthSession.session_token_hash == session_token_hash)
    )
    auth_session = (await database_session.execute(auth_session_query)).scalar_one_or_none()
    if auth_session is None:
        return None

    current_datetime = datetime.now(UTC)
    if auth_session.expires_at <= current_datetime:
        await database_session.delete(auth_session)
        await database_session.commit()
        return None

    auth_session.last_used_at = current_datetime
    await database_session.commit()
    return auth_session.user


async def _create_web_session_for_user(
    *,
    user: User,
    database_session: AsyncSession,
) -> str:
    raw_session_token = create_session_token()
    auth_session = AuthSession(
        user_id=user.id,
        session_token_hash=hash_session_token(raw_session_token),
        expires_at=create_session_expiration_datetime(),
        last_used_at=datetime.now(UTC),
    )
    database_session.add(auth_session)
    await database_session.commit()
    return raw_session_token


def _set_web_session_cookie(response: RedirectResponse, raw_session_token: str) -> None:
    response.set_cookie(
        key=WEB_SESSION_COOKIE_NAME,
        value=raw_session_token,
        max_age=WEB_SESSION_COOKIE_MAX_AGE_SECONDS,
        httponly=True,
        samesite="lax",
    )


def _clear_web_session_cookie(response: RedirectResponse) -> None:
    response.delete_cookie(
        key=WEB_SESSION_COOKIE_NAME,
        httponly=True,
        samesite="lax",
    )


@webui_router.get("/web", include_in_schema=False)
async def web_home() -> RedirectResponse:
    return RedirectResponse(url="/", status_code=302)


@webui_router.get("/", response_class=HTMLResponse, include_in_schema=False)
async def web_project_home(
    request: Request,
    database_session: AsyncSession = Depends(get_database_session),
) -> HTMLResponse | RedirectResponse:
    current_user = await _resolve_web_session_user(request, database_session)
    if current_user is not None:
        return RedirectResponse(url="/web/app", status_code=302)

    return templates.TemplateResponse(
        "webui_login.html",
        {
            "request": request,
            "error_message": None,
        },
    )


@webui_router.get("/web/login", response_class=HTMLResponse, include_in_schema=False)
async def web_login_page(
    request: Request,
    database_session: AsyncSession = Depends(get_database_session),
) -> HTMLResponse | RedirectResponse:
    current_user = await _resolve_web_session_user(request, database_session)
    if current_user is not None:
        return RedirectResponse(url="/web/app", status_code=302)

    return RedirectResponse(url="/", status_code=302)


@webui_router.post("/web/login", response_class=HTMLResponse, include_in_schema=False)
async def web_login_submit(
    request: Request,
    email_address: str = Form(...),
    password: str = Form(...),
    database_session: AsyncSession = Depends(get_database_session),
) -> HTMLResponse | RedirectResponse:
    normalized_email_address = normalize_email_address(email_address)
    user_query = select(User).where(User.email_address == normalized_email_address)
    user = (await database_session.execute(user_query)).scalar_one_or_none()

    if user is None or not verify_password(password, user.password_hash):
        return templates.TemplateResponse(
            "webui_login.html",
            {
                "request": request,
                "error_message": "Invalid email or password.",
            },
            status_code=401,
        )

    raw_session_token = await _create_web_session_for_user(
        user=user,
        database_session=database_session,
    )
    response = RedirectResponse(url="/web/app", status_code=302)
    _set_web_session_cookie(response, raw_session_token)
    return response


@webui_router.post("/web/register", response_class=HTMLResponse, include_in_schema=False)
async def web_register_submit(
    request: Request,
    email_address: str = Form(...),
    password: str = Form(...),
    display_name: str = Form(default=""),
    database_session: AsyncSession = Depends(get_database_session),
) -> HTMLResponse | RedirectResponse:
    normalized_email_address = normalize_email_address(email_address)
    existing_user_query = select(User).where(User.email_address == normalized_email_address)
    existing_user = (await database_session.execute(existing_user_query)).scalar_one_or_none()
    if existing_user is not None:
        return templates.TemplateResponse(
            "webui_login.html",
            {
                "request": request,
                "error_message": "A user with that email already exists.",
            },
            status_code=409,
        )
    if len(password) < 8:
        return templates.TemplateResponse(
            "webui_login.html",
            {
                "request": request,
                "error_message": "Password must be at least 8 characters.",
            },
            status_code=400,
        )

    cleaned_display_name = display_name.strip() or None
    if cleaned_display_name and len(cleaned_display_name) > 255:
        return templates.TemplateResponse(
            "webui_login.html",
            {
                "request": request,
                "error_message": "Display name must be 255 characters or fewer.",
            },
            status_code=400,
        )
    user = User(
        email_address=normalized_email_address,
        display_name=cleaned_display_name,
        password_hash=create_password_hash(password),
    )
    database_session.add(user)
    await database_session.flush()

    default_workspace_display_name = (
        f"{cleaned_display_name}'s Workspace"
        if cleaned_display_name
        else "My Workspace"
    )
    await create_workspace_for_user(
        database_session,
        user=user,
        display_name=default_workspace_display_name,
        workspace_metadata={"created_during_registration": True, "created_from_web_ui": True},
    )
    await database_session.commit()
    await database_session.refresh(user)

    raw_session_token = await _create_web_session_for_user(
        user=user,
        database_session=database_session,
    )
    response = RedirectResponse(url="/web/app", status_code=302)
    _set_web_session_cookie(response, raw_session_token)
    return response


@webui_router.post("/web/logout", include_in_schema=False)
async def web_logout(
    request: Request,
    database_session: AsyncSession = Depends(get_database_session),
) -> RedirectResponse:
    raw_session_token = request.cookies.get(WEB_SESSION_COOKIE_NAME)
    if raw_session_token:
        auth_session_query = select(AuthSession).where(
            AuthSession.session_token_hash == hash_session_token(raw_session_token)
        )
        auth_session = (await database_session.execute(auth_session_query)).scalar_one_or_none()
        if auth_session is not None:
            await database_session.delete(auth_session)
            await database_session.commit()

    response = RedirectResponse(url="/", status_code=302)
    _clear_web_session_cookie(response)
    return response


@webui_router.post("/web/workspaces", include_in_schema=False)
async def web_create_workspace(
    request: Request,
    display_name: str = Form(...),
    description: str = Form(default=""),
    database_session: AsyncSession = Depends(get_database_session),
) -> RedirectResponse:
    current_user = await _resolve_web_session_user(request, database_session)
    if current_user is None:
        response = RedirectResponse(url="/", status_code=302)
        _clear_web_session_cookie(response)
        return response

    cleaned_display_name = display_name.strip()
    if not cleaned_display_name:
        return RedirectResponse(url="/web/app?error=workspace_name_required", status_code=302)
    if len(cleaned_display_name) > 255:
        return RedirectResponse(url="/web/app?error=workspace_name_too_long", status_code=302)

    workspace = await create_workspace_for_user(
        database_session,
        user=current_user,
        display_name=cleaned_display_name,
        description=description.strip() or None,
        workspace_metadata={"created_from_web_ui": True},
    )
    await database_session.commit()
    await database_session.refresh(workspace)

    return RedirectResponse(
        url=f"/web/app?workspace_id={workspace.id}",
        status_code=302,
    )


@webui_router.post("/web/upload", include_in_schema=False)
async def web_upload_workspace_file(
    request: Request,
    workspace_id: str = Form(...),
    entry_path: str = Form(...),
    file: UploadFile = File(...),
    database_session: AsyncSession = Depends(get_database_session),
) -> RedirectResponse:
    current_user = await _resolve_web_session_user(request, database_session)
    if current_user is None:
        response = RedirectResponse(url="/", status_code=302)
        _clear_web_session_cookie(response)
        return response

    try:
        workspace_uuid = UUID(workspace_id)
    except ValueError:
        return RedirectResponse(url="/web/app?error=invalid_workspace_id", status_code=302)

    try:
        await upload_workspace_file(
            request=request,
            workspace_id=workspace_uuid,
            entry_path=entry_path,
            file=file,
            content_type=None,
            mime_type=None,
            current_user=current_user,
            database_session=database_session,
        )
        return RedirectResponse(
            url=f"/web/app?workspace_id={workspace_uuid}",
            status_code=302,
        )
    except HTTPException as error:
        error_message = str(error.detail).replace(" ", "_")
        return RedirectResponse(
            url=f"/web/app?workspace_id={workspace_uuid}&error={error_message}",
            status_code=302,
        )


@webui_router.get("/web/app", response_class=HTMLResponse, include_in_schema=False)
async def web_dashboard(
    request: Request,
    workspace_id: str | None = None,
    error: str | None = None,
    database_session: AsyncSession = Depends(get_database_session),
) -> HTMLResponse | RedirectResponse:
    current_user = await _resolve_web_session_user(request, database_session)
    if current_user is None:
        response = RedirectResponse(url="/", status_code=302)
        _clear_web_session_cookie(response)
        return response

    workspace_rows = (
        await database_session.execute(
            select(Workspace, WorkspaceMembership.role)
            .join(WorkspaceMembership, WorkspaceMembership.workspace_id == Workspace.id)
            .where(WorkspaceMembership.user_id == current_user.id)
            .order_by(Workspace.updated_at.desc())
        )
    ).all()

    selected_workspace_id: UUID | None = None
    if workspace_id:
        try:
            selected_workspace_id = UUID(workspace_id)
        except ValueError:
            selected_workspace_id = None
    accessible_workspace_ids = {workspace.id for workspace, _ in workspace_rows}
    if selected_workspace_id is not None and selected_workspace_id not in accessible_workspace_ids:
        selected_workspace_id = None
    if selected_workspace_id is None and workspace_rows:
        selected_workspace_id = workspace_rows[0][0].id

    workspace_entries: list[WorkspaceEntry] = []
    courses: list[Course] = []
    learner_topic_masteries: list[LearnerTopicMastery] = []
    learner_observations: list[LearnerObservation] = []

    if selected_workspace_id is not None:
        workspace_entries = list(
            (
                await database_session.execute(
                    select(WorkspaceEntry)
                    .where(WorkspaceEntry.workspace_id == selected_workspace_id)
                    .order_by(WorkspaceEntry.entry_path.asc())
                )
            )
            .scalars()
            .all()
        )
        courses = list(
            (
                await database_session.execute(
                    select(Course)
                    .where(Course.workspace_id == selected_workspace_id)
                    .order_by(Course.updated_at.desc())
                )
            )
            .scalars()
            .all()
        )
        learner_topic_masteries = list(
            (
                await database_session.execute(
                    select(LearnerTopicMastery)
                    .where(LearnerTopicMastery.workspace_id == selected_workspace_id)
                    .order_by(LearnerTopicMastery.updated_at.desc())
                )
            )
            .scalars()
            .all()
        )
        learner_observations = list(
            (
                await database_session.execute(
                    select(LearnerObservation)
                    .where(LearnerObservation.workspace_id == selected_workspace_id)
                    .order_by(LearnerObservation.created_at.desc())
                    .limit(200)
                )
            )
            .scalars()
            .all()
        )

    return templates.TemplateResponse(
        "webui_dashboard.html",
        {
            "request": request,
            "current_user": current_user,
            "workspace_rows": workspace_rows,
            "selected_workspace_id": str(selected_workspace_id) if selected_workspace_id else None,
            "workspace_entries": workspace_entries,
            "courses": courses,
            "learner_topic_masteries": learner_topic_masteries,
            "learner_observations": learner_observations,
            "error_message": error.replace("_", " ") if error else None,
            "workspace_count": len(workspace_rows),
            "file_count": sum(
                1
                for workspace_entry in workspace_entries
                if workspace_entry.entry_type.value == "file"
            ),
            "directory_count": sum(
                1
                for workspace_entry in workspace_entries
                if workspace_entry.entry_type.value == "directory"
            ),
        },
    )
